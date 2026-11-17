-- Chytré filtry: štítky způsobu přípravy a příležitostí.
--
-- 1. api_save_recipe (ukládání z ChatGPT) nově přijímá volitelné pole
--    „tags“. Když ho klient nepošle, stávající štítky zůstanou beze změny.
-- 2. Jednorázové doplnění štítků podle postupu, vybavení, surovin a časů.
--    Štítky se jen PŘIDÁVAJÍ – nic se nemaže a ručně zadané štítky zůstanou.
--    Migrace je idempotentní (opakované spuštění nic nezdvojí).

create or replace function public.api_save_recipe(
  p_recipe jsonb,
  p_recipe_id uuid default null,
  p_meta jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  uid uuid := auth.uid();
  rid uuid;
  ver integer;
  v_title text := trim(coalesce(p_recipe->>'title', ''));
  v_servings numeric := coalesce(nullif(p_recipe->>'servings', '')::numeric, 4);
  v_yield text := case when lower(coalesce(p_recipe->>'yield_unit', '')) in ('ks', 'kus', 'kusy', 'kusů')
    then 'ks' else 'porce' end;
  v_prep integer := greatest(coalesce(nullif(p_recipe->>'prep_minutes', '')::numeric, 0), 0)::integer;
  v_cook integer := greatest(coalesce(nullif(p_recipe->>'cook_minutes', '')::numeric, 0), 0)::integer;
  v_rest integer := greatest(coalesce(nullif(p_recipe->>'rest_minutes', '')::numeric, 0), 0)::integer;
  v_temperatures jsonb := case when jsonb_typeof(p_recipe->'temperatures') = 'array'
    then p_recipe->'temperatures' else '[]'::jsonb end;
  v_equipment jsonb := case when jsonb_typeof(p_recipe->'equipment') = 'array'
    then p_recipe->'equipment' else '[]'::jsonb end;
  -- Štítky: jen neprázdné texty, bez duplicit, nejvýš 30 po 40 znacích.
  v_tags jsonb := coalesce((
    select jsonb_agg(t.tag order by t.ord)
    from (
      select distinct on (lower(trim(e.value))) left(trim(e.value), 40) as tag, e.ord
      from jsonb_array_elements_text(
        case when jsonb_typeof(p_recipe->'tags') = 'array' then p_recipe->'tags' else '[]'::jsonb end
      ) with ordinality as e(value, ord)
      where trim(e.value) <> ''
      order by lower(trim(e.value)), e.ord
      limit 30
    ) t
  ), '[]'::jsonb);
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
      owner_id, title, description, category, servings, yield_unit, prep_minutes,
      cook_minutes, rest_minutes, total_minutes, temperatures, equipment, tags, notes,
      source_url, current_version
    ) values (
      uid, v_title, coalesce(p_recipe->>'description', ''),
      coalesce(p_recipe->>'category', ''), v_servings, v_yield, v_prep, v_cook,
      v_rest, 0, v_temperatures, v_equipment, v_tags, coalesce(p_recipe->>'notes', ''),
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
      yield_unit = case when p_recipe ? 'yield_unit' then v_yield else yield_unit end,
      prep_minutes = v_prep,
      cook_minutes = v_cook,
      rest_minutes = case when p_recipe ? 'rest_minutes' then v_rest else rest_minutes end,
      total_minutes = 0,
      temperatures = v_temperatures,
      equipment = v_equipment,
      tags = case when p_recipe ? 'tags' then v_tags else tags end,
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

  insert into public.recipe_steps (
    recipe_id, position, instruction, duration_minutes, temperature_c, kind, parallel
  )
  select rid, (t.ord - 1)::integer, trim(t.item->>'instruction'),
         case when nullif(t.item->>'duration_minutes', '')::numeric > 0
           then round(nullif(t.item->>'duration_minutes', '')::numeric)::integer end,
         nullif(t.item->>'temperature_c', '')::numeric,
         case when t.item->>'kind' in ('active', 'cook', 'passive')
           then t.item->>'kind' else '' end,
         coalesce(t.item->>'parallel', 'false') = 'true'
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
$function$;

-- ------------------------------------------------- doplnění štítků receptům

with source as (
  select
    r.id,
    r.tags,
    r.category,
    r.servings,
    coalesce(r.prep_minutes, 0) + coalesce(r.cook_minutes, 0) + coalesce(r.rest_minutes, 0) as total,
    coalesce(r.cook_minutes, 0) as cook,
    translate(lower(r.title), 'áčďéěíňóřšťúůýž', 'acdeeinorstuuyz') as title_f,
    translate(lower(concat_ws(' | ',
      r.title, r.description, r.equipment::text, r.temperatures::text,
      (select string_agg(s.instruction, ' | ') from public.recipe_steps s where s.recipe_id = r.id),
      (select string_agg(i.name, ' | ') from public.recipe_ingredients i where i.recipe_id = r.id)
    )), 'áčďéěíňóřšťúůýž', 'acdeeinorstuuyz') as t
  from public.recipes r
  where r.deleted_at is null
),
derived as (
  select
    id,
    tags,
    array_remove(array[
      -- Trouba: pečení v troubě, pekáč, plech, zapékání. Vafle ve
      -- vaflovači se do trouby nepočítají.
      case when (t ~ '(troub|\mpekac|\mplech(\M|u\M|y\M)|zapec|zapek|\mpredehrej)'
                 or (t ~ '\mpec(te|e|eni|ena|eny|eme)?\M' and t !~ 'vaflovac'))
           and not (t ~ 'vaflovac' and t !~ 'troub')
        then 'Trouba' end,
      -- Pánev: pánev, smažení, prudké opečení plátků z obou stran.
      case when t ~ '(panev|panv|\msmaz|\mosmaz|\mwok\M|\mzprudka|z obou stran)'
        then 'Pánev' end,
      case when t ~ '(sous-vide|sous vide|sousvide|vodni lazn)'
        then 'Sous-vide' end,
      case when t ~ '\mgril' then 'Gril' end,
      -- Pomalé vaření: výslovně pomalé, nebo vaření/pečení aspoň 3 hodiny.
      case when title_f ~ 'pomal' or cook >= 180
        then 'Pomalé vaření' end,
      -- Příležitosti podle jasných pravidel (lze kdykoli upravit v aplikaci):
      case when title_f ~ '(livanc|palacink|vafl|krupicna kase)'
        then 'Sladká snídaně' end,
      case when total > 0 and total <= 40
           and category not in ('Sladká jídla a dezerty', 'Pečivo a těsta', 'Přílohy', 'Polévky')
        then 'Rychlá večeře' end,
      case when servings >= 6
           and category not in ('Sladká jídla a dezerty', 'Pečivo a těsta', 'Přílohy')
        then 'Na více dní' end,
      case when t ~ '(detem|pro deti)'
        then 'Pro děti' end
    ], null) as add_tags
  from source
),
merged as (
  select
    d.id,
    d.tags || coalesce((
      select jsonb_agg(a.tag order by a.ord)
      from unnest(d.add_tags) with ordinality as a(tag, ord)
      where not exists (
        select 1 from jsonb_array_elements_text(d.tags) e(value)
        where lower(trim(e.value)) = lower(a.tag)
      )
    ), '[]'::jsonb) as new_tags
  from derived d
  where cardinality(d.add_tags) > 0
)
update public.recipes r
set tags = m.new_tags,
    -- Nové updated_at: telefon s neodeslanou místní úpravou dostane
    -- konflikt k rozhodnutí místo tichého přepsání štítků.
    updated_at = now()
from merged m
where r.id = m.id
  and m.new_tags is distinct from r.tags;
