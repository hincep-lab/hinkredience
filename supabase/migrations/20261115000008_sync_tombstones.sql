-- HINKredience° – spolehlivá synchronizace mezi zařízeními
--
-- 1) Záznamy o natrvalo smazaných receptech („náhrobky“). Když jedno
--    zařízení vysype koš, ostatní se to dozvědí a recept smažou také. Recept
--    se tak nemůže z jiného telefonu samovolně vrátit.
-- 2) Recept se stejným id, jako má natrvalo smazaný recept, už nejde znovu
--    založit (ochrana proti „oživení“ ze starého telefonu).
-- 3) Upozornění v reálném čase (Supabase Realtime) na změny receptů, aby se
--    úpravy z ChatGPT nebo z druhého telefonu projevily hned.
--
-- Migrace nic nemaže ani nepřepisuje a lze ji bezpečně spustit opakovaně.

create table if not exists public.recipe_tombstones (
  recipe_id    uuid primary key,
  owner_id     uuid not null references auth.users (id) on delete cascade,
  household_id uuid references public.households (id) on delete set null,
  purged_at    timestamptz not null default now()
);

create index if not exists recipe_tombstones_purged_idx
  on public.recipe_tombstones (purged_at);

alter table public.recipe_tombstones enable row level security;

grant select on public.recipe_tombstones to authenticated;

-- Číst smí vlastník a členové domácnosti, se kterou byl recept sdílený.
-- Zapisuje jen databázový trigger níže, uživatelé přímo nic.
drop policy if exists recipe_tombstones_select on public.recipe_tombstones;
create policy recipe_tombstones_select on public.recipe_tombstones
  for select to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );

create or replace function public.record_recipe_tombstone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.recipe_tombstones (recipe_id, owner_id, household_id)
  values (old.id, old.owner_id, old.household_id)
  on conflict (recipe_id) do update set purged_at = now();
  return old;
end;
$$;

drop trigger if exists recipes_record_tombstone on public.recipes;
create trigger recipes_record_tombstone
  after delete on public.recipes
  for each row execute function public.record_recipe_tombstone();

create or replace function public.reject_purged_recipe()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.recipe_tombstones t where t.recipe_id = new.id) then
    raise exception 'Recept byl natrvalo smazán a nelze ho obnovit.'
      using errcode = 'P0001', hint = 'hink_recipe_purged';
  end if;
  return new;
end;
$$;

drop trigger if exists recipes_reject_purged on public.recipes;
create trigger recipes_reject_purged
  before insert on public.recipes
  for each row execute function public.reject_purged_recipe();

-- Realtime: posílat změny receptů a náhrobků přihlášeným klientům.
-- Realtime dodržuje RLS – každý dostane jen události svých receptů.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'recipes'
    ) then
      alter publication supabase_realtime add table public.recipes;
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'recipe_tombstones'
    ) then
      alter publication supabase_realtime add table public.recipe_tombstones;
    end if;
  end if;
end;
$$;
