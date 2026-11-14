-- HINKredience° – ukládání receptů přes API a MCP server (Etapa 3)
--
-- Recept, jeho suroviny, kroky a záznam v historii verzí se ukládají v jedné
-- transakci, aby si telefon při synchronizaci nikdy nestáhl napůl uložený
-- recept. Funkce běží s právy volajícího (security invoker), takže pro ně
-- platí stejná Row Level Security jako pro mobilní aplikaci.

-- Úplná podoba receptu ve tvaru, který aplikace ukládá do historie verzí.
create or replace function public.recipe_snapshot(p_recipe_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id,
    'owner_id', r.owner_id,
    'household_id', r.household_id,
    'visibility', r.visibility,
    'title', r.title,
    'description', r.description,
    'category', r.category,
    'servings', r.servings,
    'prep_minutes', r.prep_minutes,
    'cook_minutes', r.cook_minutes,
    'total_minutes', r.total_minutes,
    'temperatures', r.temperatures,
    'equipment', r.equipment,
    'notes', r.notes,
    'rating', r.rating,
    'is_favorite', r.is_favorite,
    'photos', r.photos,
    'source_url', r.source_url,
    'current_version', r.current_version,
    'last_cooked_at', r.last_cooked_at,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'deleted_at', r.deleted_at,
    'ingredients', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'quantity', i.quantity,
        'unit', i.unit, 'note', i.note
      ) order by i.position)
      from public.recipe_ingredients i where i.recipe_id = r.id
    ), '[]'::jsonb),
    'steps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'instruction', s.instruction,
        'duration_minutes', s.duration_minutes, 'temperature_c', s.temperature_c
      ) order by s.position)
      from public.recipe_steps s where s.recipe_id = r.id
    ), '[]'::jsonb)
  )
  from public.recipes r
  where r.id = p_recipe_id;
$$;

-- Vytvoří recept (p_recipe_id je null), nebo uloží novou verzi existujícího.
-- Předchozí podoba zůstává v historii verzí. p_meta může obsahovat
-- change_summary, change_reason, result_note a rating (pro záznam verze).
create or replace function public.api_save_recipe(
  p_recipe jsonb,
  p_recipe_id uuid default null,
  p_meta jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  rid uuid;
  ver integer;
  v_title text := trim(coalesce(p_recipe->>'title', ''));
  v_servings numeric := coalesce(nullif(p_recipe->>'servings', '')::numeric, 4);
  v_prep integer := greatest(coalesce(nullif(p_recipe->>'prep_minutes', '')::numeric, 0), 0)::integer;
  v_cook integer := greatest(coalesce(nullif(p_recipe->>'cook_minutes', '')::numeric, 0), 0)::integer;
  v_temperatures jsonb := case when jsonb_typeof(p_recipe->'temperatures') = 'array'
    then p_recipe->'temperatures' else '[]'::jsonb end;
  v_equipment jsonb := case when jsonb_typeof(p_recipe->'equipment') = 'array'
    then p_recipe->'equipment' else '[]'::jsonb end;
  v_rating numeric := nullif(p_meta->>'rating', '')::numeric;
  existing public.recipes;
begin
  if uid is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;
  if v_title = '' then
    raise exception 'Recept musí mít název.' using errcode = '22023';
  end if;
  if v_servings <= 0 then
    v_servings := 4;
  end if;
  if v_rating is not null and (v_rating < 0 or v_rating > 5) then
    v_rating := null;
  end if;

  if p_recipe_id is null then
    insert into public.recipes (
      owner_id, title, description, category, servings, prep_minutes,
      cook_minutes, total_minutes, temperatures, equipment, notes,
      source_url, current_version
    ) values (
      uid, v_title, coalesce(p_recipe->>'description', ''),
      coalesce(p_recipe->>'category', ''), v_servings, v_prep, v_cook, 0,
      v_temperatures, v_equipment, coalesce(p_recipe->>'notes', ''),
      nullif(p_recipe->>'source_url', ''), 1
    )
    returning id into rid;
    ver := 1;
  else
    select * into existing from public.recipes
    where id = p_recipe_id and deleted_at is null
    for update;
    if not found then
      raise exception 'Recept nenalezen.' using errcode = 'P0002';
    end if;
    rid := existing.id;
    ver := existing.current_version + 1;
    update public.recipes set
      title = v_title,
      description = coalesce(p_recipe->>'description', ''),
      category = coalesce(p_recipe->>'category', ''),
      servings = v_servings,
      prep_minutes = v_prep,
      cook_minutes = v_cook,
      total_minutes = 0,
      temperatures = v_temperatures,
      equipment = v_equipment,
      notes = coalesce(p_recipe->>'notes', ''),
      source_url = case when p_recipe ? 'source_url'
        then nullif(p_recipe->>'source_url', '') else source_url end,
      current_version = ver,
      updated_at = now()
    where id = rid;
    delete from public.recipe_ingredients where recipe_id = rid;
    delete from public.recipe_steps where recipe_id = rid;
  end if;

  insert into public.recipe_ingredients (recipe_id, position, name, quantity, unit, note)
  select rid, (t.ord - 1)::integer, trim(t.item->>'name'),
         case when nullif(t.item->>'quantity', '')::numeric > 0
           then nullif(t.item->>'quantity', '')::numeric end,
         coalesce(t.item->>'unit', ''), coalesce(t.item->>'note', '')
  from jsonb_array_elements(
    case when jsonb_typeof(p_recipe->'ingredients') = 'array'
      then p_recipe->'ingredients' else '[]'::jsonb end
  ) with ordinality as t(item, ord)
  where trim(coalesce(t.item->>'name', '')) <> '';

  insert into public.recipe_steps (recipe_id, position, instruction, duration_minutes, temperature_c)
  select rid, (t.ord - 1)::integer, trim(t.item->>'instruction'),
         case when nullif(t.item->>'duration_minutes', '')::numeric > 0
           then round(nullif(t.item->>'duration_minutes', '')::numeric)::integer end,
         nullif(t.item->>'temperature_c', '')::numeric
  from jsonb_array_elements(
    case when jsonb_typeof(p_recipe->'steps') = 'array'
      then p_recipe->'steps' else '[]'::jsonb end
  ) with ordinality as t(item, ord)
  where trim(coalesce(t.item->>'instruction', '')) <> '';

  insert into public.recipe_versions (
    recipe_id, version_number, snapshot, change_summary, change_reason,
    result_note, rating
  ) values (
    rid, ver, public.recipe_snapshot(rid),
    coalesce(nullif(trim(p_meta->>'change_summary'), ''),
             case when ver = 1 then 'Původní postup' else 'Úprava přes ChatGPT' end),
    coalesce(p_meta->>'change_reason', ''),
    coalesce(p_meta->>'result_note', ''),
    v_rating
  );

  return jsonb_build_object('id', rid, 'version', ver);
end;
$$;

revoke all on function public.recipe_snapshot(uuid) from public;
revoke all on function public.api_save_recipe(jsonb, uuid, jsonb) from public;
grant execute on function public.recipe_snapshot(uuid) to authenticated;
grant execute on function public.api_save_recipe(jsonb, uuid, jsonb) to authenticated;
