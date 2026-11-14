-- HINKredience° – výchozí profil Pavla Hinka (kap. 9 a 10 zadání)
--
-- Funkce doplní přihlášenému uživateli kuchyňské vybavení a chuťové preference,
-- pokud ještě žádné nemá. Volá se jednou po prvním přihlášení:
--   select public.seed_hink_defaults();
-- Vše, co vloží, je dál normálně editovatelné.

create or replace function public.seed_hink_defaults()
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.kitchen_equipment where owner_id = uid) then
    insert into public.kitchen_equipment (owner_id, name, kind, capabilities, position) values
      (uid, 'Gorenje BPSAX6747A08BGWI', 'Trouba',
        '["Maximální teplota 300 °C", "SteamAssist", "Teplotní sonda", "Horkovzdušné pečení", "Pizza program"]'::jsonb, 0),
      (uid, 'Tesla EliteCook K70', '', '[]'::jsonb, 1),
      (uid, 'Fabini Mattia 26 cm / 5,5 l', '', '[]'::jsonb, 2),
      (uid, 'Fabini nerezová pánev 26 cm', '', '[]'::jsonb, 3),
      (uid, 'ETA Gratussino III Maxo', '', '[]'::jsonb, 4),
      (uid, 'Rohnson R-2844', '', '[]'::jsonb, 5),
      (uid, 'Electrolux Pizza Expert Kit E9OOPE01', '', '[]'::jsonb, 6),
      (uid, 'LG MH6565DPR', '', '[]'::jsonb, 7),
      (uid, 'Philips 2200 LatteGo', '', '[]'::jsonb, 8);
  end if;

  if not exists (select 1 from public.user_preferences where user_id = uid) then
    insert into public.user_preferences (user_id, kind, label, position) values
      (uid, 'taste', 'Výraznější chuť', 0),
      (uid, 'taste', 'Dobře ochucené maso', 1),
      (uid, 'taste', 'Obliba pomalého vaření', 2),
      (uid, 'taste', 'Obliba sous-vide', 3),
      (uid, 'taste', 'Zájem o přesné teploty', 4),
      (uid, 'taste', 'Experimentování', 5),
      (uid, 'taste', 'Recepty vhodné pro rodinu', 6),
      (uid, 'taste', 'Možnost přípravy bez chilli', 7),
      (uid, 'taste', 'Přesné gramáže', 8);
  end if;
end;
$$;

revoke all on function public.seed_hink_defaults() from public;
grant execute on function public.seed_hink_defaults() to authenticated;
