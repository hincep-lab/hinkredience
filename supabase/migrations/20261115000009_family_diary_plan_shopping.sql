-- HINKredience° – Etapa 4: kuchařský deník, plán vaření, nákupní seznam, rodina
--
-- Tabulky cooking_sessions, meal_plans, shopping_lists a shopping_items
-- existují od první migrace i s oprávněními (RLS). Tato migrace jen přidává
-- sloupce pro synchronizaci s telefony (měkké mazání a kurzor změn), pár
-- údajů navíc a funkce pro rodinu a společný nákupní seznam.
--
-- Nic nemaže ani nepřepisuje a lze ji bezpečně spustit opakovaně.

-- ------------------------------------------------------------ deník vaření
alter table public.cooking_sessions
  add column if not exists notes text not null default '',
  add column if not exists servings numeric,
  add column if not exists version_number integer,
  add column if not exists deleted_at timestamptz,
  add column if not exists synced_at timestamptz not null default now();

-- ------------------------------------------------------------- plán vaření
alter table public.meal_plans
  add column if not exists servings numeric,
  add column if not exists deleted_at timestamptz,
  add column if not exists synced_at timestamptz not null default now();

-- ---------------------------------------------------------- nákupní seznam
alter table public.shopping_items
  add column if not exists sources jsonb not null default '[]'::jsonb,
  add column if not exists deleted_at timestamptz,
  add column if not exists synced_at timestamptz not null default now();

-- Kurzor změn (synced_at) nastavuje server při každém zápisu.
do $$
declare
  t text;
begin
  foreach t in array array['cooking_sessions', 'meal_plans', 'shopping_items'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_touch_synced', t);
    execute format(
      'create trigger %I before insert or update on public.%I
         for each row execute function public.touch_synced_at()',
      t || '_touch_synced', t
    );
    execute format('create index if not exists %I on public.%I (synced_at)', t || '_synced_idx', t);
  end loop;
end;
$$;

-- -------------------------------------------------------------- rodina

-- Domácnost přihlášeného uživatele (první, do které patří), nebo null.
create or replace function public.my_household()
returns uuid
language sql
stable
security invoker
set search_path = public
as $$
  select m.household_id from public.household_members m
  where m.user_id = auth.uid()
  order by m.joined_at
  limit 1;
$$;

-- Nákupní seznam přihlášeného uživatele: v rodině společný, jinak vlastní.
-- Když ještě neexistuje, založí ho.
create or replace function public.my_shopping_list()
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  hid uuid := public.my_household();
  lid uuid;
begin
  if auth.uid() is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;
  if hid is not null then
    select id into lid from public.shopping_lists
    where household_id = hid order by created_at limit 1;
    if lid is null then
      insert into public.shopping_lists (owner_id, household_id)
      values (auth.uid(), hid) returning id into lid;
    end if;
  else
    select id into lid from public.shopping_lists
    where owner_id = auth.uid() and household_id is null order by created_at limit 1;
    if lid is null then
      insert into public.shopping_lists (owner_id) values (auth.uid()) returning id into lid;
    end if;
  end if;
  return lid;
end;
$$;

-- Přidání člena do domácnosti podle e-mailu. Smí jen zakladatel domácnosti
-- a jen uživatele, který už má účet v HINKredience. E-maily ostatních
-- uživatelů se nikomu nevracejí.
create or replace function public.household_add_member(p_household uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid;
  name text;
begin
  if not public.is_household_owner(p_household) then
    raise exception 'Členy může přidávat jen zakladatel domácnosti.' using errcode = '42501';
  end if;
  select u.id into target from auth.users u
  where lower(u.email) = lower(trim(coalesce(p_email, '')))
  limit 1;
  if target is null then
    raise exception 'Uživatel s tímto e-mailem v HINKredience zatím není. Ať se nejdřív zaregistruje.'
      using errcode = 'P0002';
  end if;
  insert into public.household_members (household_id, user_id, role)
  values (p_household, target, 'member')
  on conflict do nothing;
  select coalesce(p.display_name, '') into name from public.profiles p where p.id = target;
  return jsonb_build_object('user_id', target, 'display_name', coalesce(name, ''));
end;
$$;

revoke all on function public.household_add_member(uuid, text) from public;
grant execute on function public.household_add_member(uuid, text) to authenticated;
grant execute on function public.my_household() to authenticated;
grant execute on function public.my_shopping_list() to authenticated;

-- Realtime: změny plánu, nákupu a deníku se hned projeví na druhém telefonu.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['cooking_sessions', 'meal_plans', 'shopping_items'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;
