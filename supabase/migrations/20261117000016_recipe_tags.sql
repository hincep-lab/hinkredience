-- Štítky receptů (např. „Pro děti“, „Rychlá večeře“, „Slavnostní“).
-- Jen přidání sloupce s výchozí prázdnou hodnotou: žádná existující data
-- se nemění ani nemažou. Snímek verze receptu štítky nově zahrnuje.
alter table public.recipes
  add column if not exists tags jsonb not null default '[]'::jsonb;

alter table public.recipes
  drop constraint if exists recipes_tags_array_check,
  add constraint recipes_tags_array_check check (jsonb_typeof(tags) = 'array');

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
    'yield_unit', r.yield_unit,
    'prep_minutes', r.prep_minutes,
    'cook_minutes', r.cook_minutes,
    'rest_minutes', r.rest_minutes,
    'total_minutes', r.total_minutes,
    'temperatures', r.temperatures,
    'equipment', r.equipment,
    'tags', r.tags,
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
        'duration_minutes', s.duration_minutes, 'temperature_c', s.temperature_c,
        'kind', s.kind, 'parallel', s.parallel
      ) order by s.position)
      from public.recipe_steps s where s.recipe_id = r.id
    ), '[]'::jsonb)
  )
  from public.recipes r
  where r.id = p_recipe_id;
$$;
