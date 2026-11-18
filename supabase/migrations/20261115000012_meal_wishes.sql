-- HINKredience° – „Mám chuť na…“: přání rodiny do jídelníčku
--
-- Nová tabulka meal_wishes: člen rodiny napíše, na co má chuť (recept
-- z kuchařky nebo jen název), ostatní to uvidí a můžou jídlo naplánovat.
-- Oprávnění (RLS) stejná jako u plánu vaření: vlastní přání a přání
-- členů vlastní domácnosti. Anonymní role nedostane nic.
--
-- Nic nemaže ani nepřepisuje a lze ji bezpečně spustit opakovaně.

create table if not exists public.meal_wishes (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id uuid references public.households (id) on delete set null,
  recipe_id    uuid references public.recipes (id) on delete set null,
  title        text not null check (length(trim(title)) > 0),
  note         text not null default '',
  author_name  text not null default '',
  planned_day  date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  synced_at    timestamptz not null default now()
);

create index if not exists meal_wishes_owner_idx on public.meal_wishes (owner_id);
create index if not exists meal_wishes_household_idx on public.meal_wishes (household_id);
create index if not exists meal_wishes_synced_idx on public.meal_wishes (synced_at);

alter table public.meal_wishes enable row level security;
revoke all on public.meal_wishes from anon;
grant select, insert, update, delete on public.meal_wishes to authenticated;

drop policy if exists meal_wishes_select on public.meal_wishes;
create policy meal_wishes_select on public.meal_wishes for select to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );

drop policy if exists meal_wishes_insert on public.meal_wishes;
create policy meal_wishes_insert on public.meal_wishes for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );

drop policy if exists meal_wishes_update on public.meal_wishes;
create policy meal_wishes_update on public.meal_wishes for update to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  )
  with check (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );

drop policy if exists meal_wishes_delete on public.meal_wishes;
create policy meal_wishes_delete on public.meal_wishes for delete to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );

drop trigger if exists meal_wishes_touch_synced on public.meal_wishes;
create trigger meal_wishes_touch_synced before insert or update on public.meal_wishes
  for each row execute function public.touch_synced_at();

-- Realtime: přání se hned objeví i na telefonu ostatních.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public'
         and tablename = 'meal_wishes'
     ) then
    alter publication supabase_realtime add table public.meal_wishes;
  end if;
end;
$$;
