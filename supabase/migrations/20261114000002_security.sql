-- HINKredience° – zabezpečení: Row Level Security, oprávnění, spouštěče
--
-- Zásady:
--  * Každý vidí a mění jen svá data.
--  * Co je sdílené s domácností (household_id), vidí a upravují její členové.
--  * Smazat sdílený recept smí jen jeho vlastník.

-- ---------------------------------------------------------------------------
-- Pomocné funkce pro RLS (SECURITY DEFINER, aby se zásady necyklily)
-- ---------------------------------------------------------------------------

create or replace function public.is_household_member(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_household_owner(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = auth.uid() and m.role = 'owner'
  );
$$;

create or replace function public.shares_household_with(other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.household_members mine
    join public.household_members theirs on theirs.household_id = mine.household_id
    where mine.user_id = auth.uid() and theirs.user_id = other
  );
$$;

create or replace function public.can_access_recipe(rid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.recipes r
    where r.id = rid
      and (
        r.owner_id = auth.uid()
        or (r.visibility = 'household' and r.household_id is not null
            and public.is_household_member(r.household_id))
      )
  );
$$;

-- Bezpečný převod textu na UUID (pro cesty v úložišti fotografií).
create or replace function public.try_uuid(value text)
returns uuid
language plpgsql
immutable
as $$
begin
  return value::uuid;
exception when others then
  return null;
end;
$$;

revoke all on function public.is_household_member(uuid) from public;
revoke all on function public.is_household_owner(uuid) from public;
revoke all on function public.shares_household_with(uuid) from public;
revoke all on function public.can_access_recipe(uuid) from public;
grant execute on function public.is_household_member(uuid) to authenticated;
grant execute on function public.is_household_owner(uuid) to authenticated;
grant execute on function public.shares_household_with(uuid) to authenticated;
grant execute on function public.can_access_recipe(uuid) to authenticated;
grant execute on function public.try_uuid(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Spouštěče
-- ---------------------------------------------------------------------------

-- Po registraci založí profil.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, greeting_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(coalesce(new.email, ''), '@', 1)),
    new.raw_user_meta_data ->> 'greeting_name'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Zakladatel domácnosti se stane jejím vlastníkem.
create or replace function public.handle_new_household()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.household_members (household_id, user_id, role)
  values (new.id, new.created_by, 'owner')
  on conflict do nothing;
  return new;
end;
$$;

create trigger on_household_created
  after insert on public.households
  for each row execute function public.handle_new_household();

-- Vlastníka receptu nelze změnit; kdo recept upravuje, není důležité.
create or replace function public.protect_recipe_owner()
returns trigger
language plpgsql
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'Vlastníka receptu nelze změnit.' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger recipes_protect_owner
  before update on public.recipes
  for each row execute function public.protect_recipe_owner();

-- ---------------------------------------------------------------------------
-- Zapnutí RLS
-- ---------------------------------------------------------------------------

alter table public.profiles           enable row level security;
alter table public.households         enable row level security;
alter table public.household_members  enable row level security;
alter table public.recipes            enable row level security;
alter table public.recipe_ingredients enable row level security;
alter table public.recipe_steps       enable row level security;
alter table public.recipe_versions    enable row level security;
alter table public.cooking_sessions   enable row level security;
alter table public.cooking_notes      enable row level security;
alter table public.kitchen_equipment  enable row level security;
alter table public.user_preferences   enable row level security;
alter table public.ai_conversations   enable row level security;
alter table public.ai_messages        enable row level security;
alter table public.meal_plans         enable row level security;
alter table public.shopping_lists     enable row level security;
alter table public.shopping_items     enable row level security;

-- Přístup jen pro přihlášené uživatele; anonymní role nedostane nic.
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- ---------------------------------------------------------------------------
-- Zásady: profily a domácnosti
-- ---------------------------------------------------------------------------

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_household_with(id));
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy households_select on public.households for select to authenticated
  using (created_by = auth.uid() or public.is_household_member(id));
create policy households_insert on public.households for insert to authenticated
  with check (created_by = auth.uid());
create policy households_update on public.households for update to authenticated
  using (public.is_household_owner(id)) with check (public.is_household_owner(id));
create policy households_delete on public.households for delete to authenticated
  using (public.is_household_owner(id));

create policy household_members_select on public.household_members for select to authenticated
  using (user_id = auth.uid() or public.is_household_member(household_id));
create policy household_members_insert on public.household_members for insert to authenticated
  with check (public.is_household_owner(household_id));
create policy household_members_update on public.household_members for update to authenticated
  using (public.is_household_owner(household_id))
  with check (public.is_household_owner(household_id));
create policy household_members_delete on public.household_members for delete to authenticated
  using (user_id = auth.uid() or public.is_household_owner(household_id));

-- ---------------------------------------------------------------------------
-- Zásady: recepty a jejich části
-- ---------------------------------------------------------------------------

create policy recipes_select on public.recipes for select to authenticated
  using (
    owner_id = auth.uid()
    or (visibility = 'household' and household_id is not null
        and public.is_household_member(household_id))
  );
create policy recipes_insert on public.recipes for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy recipes_update on public.recipes for update to authenticated
  using (
    owner_id = auth.uid()
    or (visibility = 'household' and household_id is not null
        and public.is_household_member(household_id))
  )
  with check (
    (owner_id = auth.uid()
      and (household_id is null or public.is_household_member(household_id)))
    or (visibility = 'household' and household_id is not null
        and public.is_household_member(household_id))
  );
create policy recipes_delete on public.recipes for delete to authenticated
  using (owner_id = auth.uid());

create policy recipe_ingredients_all on public.recipe_ingredients for all to authenticated
  using (public.can_access_recipe(recipe_id))
  with check (public.can_access_recipe(recipe_id));

create policy recipe_steps_all on public.recipe_steps for all to authenticated
  using (public.can_access_recipe(recipe_id))
  with check (public.can_access_recipe(recipe_id));

-- Verze jsou neměnná historie: číst a přidávat ano, přepisovat ne.
create policy recipe_versions_select on public.recipe_versions for select to authenticated
  using (public.can_access_recipe(recipe_id));
create policy recipe_versions_insert on public.recipe_versions for insert to authenticated
  with check (public.can_access_recipe(recipe_id));

-- ---------------------------------------------------------------------------
-- Zásady: deník, vybavení, preference, AI
-- ---------------------------------------------------------------------------

create policy cooking_sessions_select on public.cooking_sessions for select to authenticated
  using (
    user_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );
create policy cooking_sessions_insert on public.cooking_sessions for insert to authenticated
  with check (
    user_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy cooking_sessions_update on public.cooking_sessions for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy cooking_sessions_delete on public.cooking_sessions for delete to authenticated
  using (user_id = auth.uid());

create policy cooking_notes_select on public.cooking_notes for select to authenticated
  using (
    user_id = auth.uid()
    or (recipe_id is not null and public.can_access_recipe(recipe_id))
  );
create policy cooking_notes_insert on public.cooking_notes for insert to authenticated
  with check (
    user_id = auth.uid()
    and (recipe_id is null or public.can_access_recipe(recipe_id))
  );
create policy cooking_notes_update on public.cooking_notes for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy cooking_notes_delete on public.cooking_notes for delete to authenticated
  using (user_id = auth.uid());

create policy kitchen_equipment_select on public.kitchen_equipment for select to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );
create policy kitchen_equipment_insert on public.kitchen_equipment for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy kitchen_equipment_update on public.kitchen_equipment for update to authenticated
  using (owner_id = auth.uid())
  with check (
    owner_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy kitchen_equipment_delete on public.kitchen_equipment for delete to authenticated
  using (owner_id = auth.uid());

-- Osobní preference jsou vždy oddělené, i v rámci domácnosti.
create policy user_preferences_all on public.user_preferences for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ai_conversations_all on public.ai_conversations for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ai_messages_all on public.ai_messages for all to authenticated
  using (exists (
    select 1 from public.ai_conversations c
    where c.id = conversation_id and c.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.ai_conversations c
    where c.id = conversation_id and c.user_id = auth.uid()
  ));

-- ---------------------------------------------------------------------------
-- Zásady: plán vaření a nákupní seznam (sdílené v domácnosti)
-- ---------------------------------------------------------------------------

create policy meal_plans_select on public.meal_plans for select to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );
create policy meal_plans_insert on public.meal_plans for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy meal_plans_update on public.meal_plans for update to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  )
  with check (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );
create policy meal_plans_delete on public.meal_plans for delete to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );

create policy shopping_lists_select on public.shopping_lists for select to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );
create policy shopping_lists_insert on public.shopping_lists for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (household_id is null or public.is_household_member(household_id))
  );
create policy shopping_lists_update on public.shopping_lists for update to authenticated
  using (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  )
  with check (
    owner_id = auth.uid()
    or (household_id is not null and public.is_household_member(household_id))
  );
create policy shopping_lists_delete on public.shopping_lists for delete to authenticated
  using (owner_id = auth.uid());

create or replace function public.can_access_shopping_list(lid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.shopping_lists l
    where l.id = lid
      and (
        l.owner_id = auth.uid()
        or (l.household_id is not null and public.is_household_member(l.household_id))
      )
  );
$$;

revoke all on function public.can_access_shopping_list(uuid) from public;
grant execute on function public.can_access_shopping_list(uuid) to authenticated;

create policy shopping_items_all on public.shopping_items for all to authenticated
  using (public.can_access_shopping_list(list_id))
  with check (public.can_access_shopping_list(list_id));
