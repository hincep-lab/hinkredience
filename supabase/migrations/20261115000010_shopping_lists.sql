-- HINKredience° – nákupní seznamy (více seznamů, kategorie, ChatGPT)
--
-- Tabulky shopping_lists a shopping_items existují od první migrace i se
-- zásadami Row Level Security (vlastník, případně jeho rodina). Tato migrace
-- jen PŘIDÁVÁ:
--   - měkké mazání a kurzor změn u seznamů (synchronizace s telefony),
--   - poznámku k položce („podle chuti“),
--   - kontroly vstupů (délky, rozsah množství, povolené kategorie),
--   - ochranu vlastníka seznamu (nikdo jiný si seznam „nepřivlastní“),
--   - upozornění v reálném čase i pro seznamy.
--
-- Nic nemaže ani nepřepisuje. Kontroly jsou NOT VALID, takže se nevztahují
-- na už uložené řádky (žádné nemusí splňovat nic nového), jen na nové zápisy.
-- Lze ji bezpečně spustit opakovaně. Předpokládá migraci 09.

alter table public.shopping_lists
  add column if not exists deleted_at timestamptz,
  add column if not exists synced_at timestamptz not null default now();

alter table public.shopping_items
  add column if not exists note text not null default '';

drop trigger if exists shopping_lists_touch_synced on public.shopping_lists;
create trigger shopping_lists_touch_synced
  before insert or update on public.shopping_lists
  for each row execute function public.touch_synced_at();

create index if not exists shopping_lists_synced_idx on public.shopping_lists (synced_at);

-- Kontroly vstupů (pro aplikaci i pro ChatGPT).
alter table public.shopping_lists
  drop constraint if exists shopping_lists_name_check,
  add constraint shopping_lists_name_check
    check (length(trim(name)) between 1 and 120) not valid;

alter table public.shopping_items
  drop constraint if exists shopping_items_name_length,
  add constraint shopping_items_name_length
    check (length(trim(name)) between 1 and 200) not valid,
  drop constraint if exists shopping_items_quantity_range,
  add constraint shopping_items_quantity_range
    check (quantity is null or (quantity >= 0 and quantity <= 1000000)) not valid,
  drop constraint if exists shopping_items_unit_length,
  add constraint shopping_items_unit_length
    check (length(unit) <= 40) not valid,
  drop constraint if exists shopping_items_note_length,
  add constraint shopping_items_note_length
    check (length(note) <= 500) not valid,
  drop constraint if exists shopping_items_category_check,
  add constraint shopping_items_category_check
    check (category in ('', 'maso', 'zelenina', 'mlecne', 'koreni', 'ostatni')) not valid;

-- Vlastníka seznamu nelze změnit (ani členem rodiny, který smí seznam
-- upravovat). Bez toho by si člen rodiny mohl cizí seznam přivlastnit.
create or replace function public.protect_shopping_list_owner()
returns trigger
language plpgsql
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'Vlastníka nákupního seznamu nelze změnit.' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists shopping_lists_protect_owner on public.shopping_lists;
create trigger shopping_lists_protect_owner
  before update on public.shopping_lists
  for each row execute function public.protect_shopping_list_owner();

-- Položku nelze přesunout do cizího seznamu: zásada shopping_items_all
-- kontroluje i nový list_id (WITH CHECK přes can_access_shopping_list).

-- Realtime: změny seznamů se hned projeví v telefonu.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'shopping_lists'
     ) then
    alter publication supabase_realtime add table public.shopping_lists;
  end if;
end;
$$;
