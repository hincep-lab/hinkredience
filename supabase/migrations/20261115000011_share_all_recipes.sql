-- HINKredience° – „Sdílet všechny moje recepty s rodinou“ (trvalé nastavení)
--
-- Když má uživatel volbu zapnutou, každý jeho recept se automaticky sdílí
-- s jeho rodinou – stávající hned po zapnutí, nové a upravené při uložení
-- (z aplikace, z webu i z ChatGPT). Volba se ukládá na serveru, takže platí
-- na všech zařízeních. Vypnutí nic neruší: už sdílené recepty zůstanou
-- sdílené, jen nové se přestanou sdílet automaticky.
--
-- Migrace jen přidává (sloupec s výchozí hodnotou „vypnuto“, funkce, trigger).
-- Nic nemaže a lze ji bezpečně spustit opakovaně.

alter table public.profiles
  add column if not exists share_recipes_with_family boolean not null default false;

-- Při uložení receptu: vlastník má volbu zapnutou a je v rodině → sdílet.
create or replace function public.auto_share_recipe()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  hid uuid;
begin
  if new.deleted_at is not null or new.visibility = 'household' then
    return new;
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = new.owner_id and p.share_recipes_with_family
  ) then
    return new;
  end if;
  select m.household_id into hid
  from public.household_members m
  where m.user_id = new.owner_id
  order by m.joined_at
  limit 1;
  if hid is not null then
    new.household_id := hid;
    new.visibility := 'household';
  end if;
  return new;
end;
$$;

drop trigger if exists recipes_auto_share on public.recipes;
create trigger recipes_auto_share
  before insert or update on public.recipes
  for each row execute function public.auto_share_recipe();

-- Jednorázově nasdílí všechny recepty přihlášeného uživatele jeho rodině
-- (tlačítko „Sdílet všechny“). Vrací počet nově sdílených receptů.
create or replace function public.share_all_my_recipes()
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  hid uuid := public.my_household();
  shared integer := 0;
begin
  if uid is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;
  if hid is null then
    return 0;
  end if;
  update public.recipes
  set household_id = hid, visibility = 'household', updated_at = now()
  where owner_id = uid
    and deleted_at is null
    and visibility <> 'household';
  get diagnostics shared = row_count;
  return shared;
end;
$$;

-- Zapne nebo vypne volbu přihlášeného uživatele. Při zapnutí rovnou nasdílí
-- všechny jeho recepty (jen jeho vlastní). Vrací počet nově sdílených.
create or replace function public.set_share_recipes_with_family(p_enabled boolean)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  shared integer := 0;
begin
  if uid is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;
  insert into public.profiles (id, share_recipes_with_family)
  values (uid, coalesce(p_enabled, false))
  on conflict (id) do update
    set share_recipes_with_family = excluded.share_recipes_with_family,
        updated_at = now();
  if coalesce(p_enabled, false) then
    shared := public.share_all_my_recipes();
  end if;
  return shared;
end;
$$;

revoke all on function public.share_all_my_recipes() from public;
grant execute on function public.share_all_my_recipes() to authenticated;
revoke all on function public.set_share_recipes_with_family(boolean) from public;
grant execute on function public.set_share_recipes_with_family(boolean) to authenticated;
