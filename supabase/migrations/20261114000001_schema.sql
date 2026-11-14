-- HINKredience° – základní schéma databáze
-- Všechny tabulky ze zadání (kap. 19). Klíče jsou UUID generované klientem i serverem,
-- aby šlo záznamy vytvářet offline a později synchronizovat.

-- ---------------------------------------------------------------------------
-- Pomocné funkce
-- ---------------------------------------------------------------------------

-- synced_at = serverový čas poslední změny řádku. Slouží jako kurzor pro stahování
-- změn do telefonu. updated_at naproti tomu posílá klient (čas skutečné úpravy).
create or replace function public.touch_synced_at()
returns trigger
language plpgsql
as $$
begin
  new.synced_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Profily a domácnosti
-- ---------------------------------------------------------------------------

create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text,
  greeting_name text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.households (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(trim(name)) > 0),
  created_by uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  role         text not null default 'member' check (role in ('owner', 'member')),
  joined_at    timestamptz not null default now(),
  primary key (household_id, user_id)
);

create index household_members_user_idx on public.household_members (user_id);

-- ---------------------------------------------------------------------------
-- Recepty
-- ---------------------------------------------------------------------------

create table public.recipes (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id    uuid references public.households (id) on delete set null,
  visibility      text not null default 'private' check (visibility in ('private', 'household')),
  title           text not null check (length(trim(title)) > 0),
  description     text not null default '',
  category        text not null default '',
  servings        numeric not null default 4 check (servings > 0),
  prep_minutes    integer not null default 0 check (prep_minutes >= 0),
  cook_minutes    integer not null default 0 check (cook_minutes >= 0),
  total_minutes   integer not null default 0 check (total_minutes >= 0),
  temperatures    jsonb not null default '[]'::jsonb,
  equipment       jsonb not null default '[]'::jsonb,
  notes           text not null default '',
  rating          numeric(2, 1) check (rating is null or (rating >= 0 and rating <= 5)),
  is_favorite     boolean not null default false,
  photos          jsonb not null default '[]'::jsonb,
  source_url      text,
  current_version integer not null default 1,
  last_cooked_at  timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  synced_at       timestamptz not null default now(),
  constraint recipes_household_visibility
    check (visibility = 'private' or household_id is not null)
);

create index recipes_owner_idx on public.recipes (owner_id);
create index recipes_household_idx on public.recipes (household_id);
create index recipes_synced_idx on public.recipes (synced_at);

create trigger recipes_touch_synced
  before insert or update on public.recipes
  for each row execute function public.touch_synced_at();

create table public.recipe_ingredients (
  id        uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references public.recipes (id) on delete cascade,
  position  integer not null default 0,
  name      text not null,
  quantity  numeric,
  unit      text not null default '',
  note      text not null default ''
);

create index recipe_ingredients_recipe_idx on public.recipe_ingredients (recipe_id, position);

create table public.recipe_steps (
  id               uuid primary key default gen_random_uuid(),
  recipe_id        uuid not null references public.recipes (id) on delete cascade,
  position         integer not null default 0,
  instruction      text not null,
  duration_minutes integer check (duration_minutes is null or duration_minutes >= 0),
  temperature_c    numeric
);

create index recipe_steps_recipe_idx on public.recipe_steps (recipe_id, position);

create table public.recipe_versions (
  id             uuid primary key default gen_random_uuid(),
  recipe_id      uuid not null references public.recipes (id) on delete cascade,
  version_number integer not null check (version_number > 0),
  snapshot       jsonb not null,
  change_summary text not null default '',
  change_reason  text not null default '',
  result_note    text not null default '',
  rating         numeric(2, 1) check (rating is null or (rating >= 0 and rating <= 5)),
  created_by     uuid default auth.uid() references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),
  unique (recipe_id, version_number)
);

-- ---------------------------------------------------------------------------
-- Kuchařský deník
-- ---------------------------------------------------------------------------

create table public.cooking_sessions (
  id                  uuid primary key default gen_random_uuid(),
  recipe_id           uuid references public.recipes (id) on delete set null,
  recipe_version_id   uuid references public.recipe_versions (id) on delete set null,
  user_id             uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id        uuid references public.households (id) on delete set null,
  recipe_title        text not null default '',
  status              text not null default 'finished' check (status in ('in_progress', 'paused', 'finished', 'cancelled')),
  cooked_at           timestamptz not null default now(),
  actual_minutes      integer check (actual_minutes is null or actual_minutes >= 0),
  actual_temperatures jsonb not null default '[]'::jsonb,
  photos              jsonb not null default '[]'::jsonb,
  rating              numeric(2, 1) check (rating is null or (rating >= 0 and rating <= 5)),
  went_well           text not null default '',
  to_improve          text not null default '',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index cooking_sessions_user_idx on public.cooking_sessions (user_id, cooked_at desc);
create index cooking_sessions_recipe_idx on public.cooking_sessions (recipe_id, cooked_at desc);

create table public.cooking_notes (
  id         uuid primary key default gen_random_uuid(),
  recipe_id  uuid references public.recipes (id) on delete cascade,
  session_id uuid references public.cooking_sessions (id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  note       text not null check (length(trim(note)) > 0),
  created_at timestamptz not null default now(),
  constraint cooking_notes_target check (recipe_id is not null or session_id is not null)
);

create index cooking_notes_recipe_idx on public.cooking_notes (recipe_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Vybavení a preference
-- ---------------------------------------------------------------------------

create table public.kitchen_equipment (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id uuid references public.households (id) on delete set null,
  name         text not null check (length(trim(name)) > 0),
  kind         text not null default '',
  capabilities jsonb not null default '[]'::jsonb,
  notes        text not null default '',
  position     integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index kitchen_equipment_owner_idx on public.kitchen_equipment (owner_id, position);

create table public.user_preferences (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind       text not null default 'taste',
  label      text not null check (length(trim(label)) > 0),
  enabled    boolean not null default true,
  position   integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index user_preferences_user_idx on public.user_preferences (user_id, position);

-- ---------------------------------------------------------------------------
-- AI konverzace
-- ---------------------------------------------------------------------------

create table public.ai_conversations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  recipe_id  uuid references public.recipes (id) on delete set null,
  title      text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index ai_conversations_user_idx on public.ai_conversations (user_id, updated_at desc);

create table public.ai_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations (id) on delete cascade,
  role            text not null check (role in ('user', 'assistant', 'system', 'tool')),
  content         text not null default '',
  attachments     jsonb not null default '[]'::jsonb,
  created_at      timestamptz not null default now()
);

create index ai_messages_conversation_idx on public.ai_messages (conversation_id, created_at);

-- ---------------------------------------------------------------------------
-- Plán vaření a nákupní seznam
-- ---------------------------------------------------------------------------

create table public.meal_plans (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id uuid references public.households (id) on delete set null,
  plan_date    date not null,
  meal_type    text not null check (meal_type in ('breakfast', 'lunch', 'dinner')),
  recipe_id    uuid references public.recipes (id) on delete set null,
  title        text not null default '',
  note         text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index meal_plans_owner_idx on public.meal_plans (owner_id, plan_date);
create index meal_plans_household_idx on public.meal_plans (household_id, plan_date);

create table public.shopping_lists (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id uuid references public.households (id) on delete set null,
  name         text not null default 'Nákupní seznam',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index shopping_lists_owner_idx on public.shopping_lists (owner_id);

create table public.shopping_items (
  id         uuid primary key default gen_random_uuid(),
  list_id    uuid not null references public.shopping_lists (id) on delete cascade,
  recipe_id  uuid references public.recipes (id) on delete set null,
  name       text not null check (length(trim(name)) > 0),
  quantity   numeric,
  unit       text not null default '',
  category   text not null default '',
  is_checked boolean not null default false,
  position   integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index shopping_items_list_idx on public.shopping_items (list_id, position);
