-- HINKredience° – Nejvýhodnější nákup: ceny v obchodech v Sušici
--
-- price_offers   – akční nabídky z letáků (veřejná data). Číst je smí každý
--                  přihlášený; zapisuje JEN serverová funkce `prices` po
--                  kontrole zdroje (uživatelé ani AI v aplikaci zapisovat
--                  nemohou). Neověřené nabídky se ukládají s verified=false
--                  a do přesného porovnání se nepočítají.
-- price_receipts – ceny z vlastních účtenek (soukromé, sdílené s rodinou),
--                  synchronizace jako u plánu vaření.
-- price_scans    – mezipaměť: co a kdy se už hledalo, aby se stejná nabídka
--                  neanalyzovala znovu (šetří bezplatné limity AI).
-- price_ai_usage – denní počet dotazů na poskytovatele AI (hlídání limitů).
--
-- Nic nemaže ani nepřepisuje a lze ji bezpečně spustit opakovaně.

-- Obchody v Sušici (každá prodejna zvlášť). Řetězec určuje oficiální web.
create or replace function public.price_store_ok(p_store text)
returns boolean
language sql
immutable
as $$
  select p_store in (
    'tesco-hradecka', 'penny-nadrazni', 'lidl-hradecka',
    'albert-hradecka', 'albert-tgm', 'jip-hradecka',
    'coop-namesti', 'coop-nadrazni', 'coop-lerchova', 'coop-smetanova'
  );
$$;

create table if not exists public.price_offers (
  id            uuid primary key default gen_random_uuid(),
  chain         text not null check (chain in ('tesco', 'penny', 'lidl', 'albert', 'jip', 'coop')),
  -- null = platí ve všech sušických prodejnách řetězce (leták řetězce)
  store_id      text check (store_id is null or public.price_store_ok(store_id)),
  product       text not null check (length(trim(product)) > 0),
  product_key   text not null default '',
  label         text not null default '',
  price         numeric not null check (price > 0 and price < 100000),
  pack_qty      numeric check (pack_qty is null or pack_qty > 0),
  pack_unit     text not null default '',
  regular_price numeric check (regular_price is null or regular_price > 0),
  conditions    text not null default '',
  valid_from    date,
  valid_to      date not null,
  source_url    text not null check (source_url like 'https://%'),
  source_title  text not null default '',
  provider      text not null check (provider in ('gemini', 'openai', 'chatgpt', 'manual')),
  verified      boolean not null default false,
  verify_method text not null default '',
  verified_at   timestamptz,
  created_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  check (valid_from is null or valid_from <= valid_to)
);

create unique index if not exists price_offers_dedupe_idx
  on public.price_offers (chain, coalesce(store_id, ''), product_key, price, valid_to);
create index if not exists price_offers_valid_idx on public.price_offers (valid_to);

alter table public.price_offers enable row level security;
revoke all on public.price_offers from anon;
revoke insert, update, delete on public.price_offers from authenticated;
grant select on public.price_offers to authenticated;

drop policy if exists price_offers_select on public.price_offers;
create policy price_offers_select on public.price_offers for select to authenticated
  using (true);

create table if not exists public.price_receipts (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  household_id uuid references public.households (id) on delete set null,
  store_id     text not null check (public.price_store_ok(store_id)),
  product      text not null check (length(trim(product)) > 0),
  label        text not null default '',
  price        numeric not null check (price > 0 and price < 100000),
  pack_qty     numeric check (pack_qty is null or pack_qty > 0),
  pack_unit    text not null default '',
  bought_on    date not null default current_date,
  note         text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  synced_at    timestamptz not null default now()
);

create index if not exists price_receipts_owner_idx on public.price_receipts (owner_id);
create index if not exists price_receipts_household_idx on public.price_receipts (household_id);
create index if not exists price_receipts_synced_idx on public.price_receipts (synced_at);

alter table public.price_receipts enable row level security;
revoke all on public.price_receipts from anon;
grant select, insert, update, delete on public.price_receipts to authenticated;

drop policy if exists price_receipts_select on public.price_receipts;
create policy price_receipts_select on public.price_receipts for select to authenticated
  using (owner_id = auth.uid() or (household_id is not null and public.is_household_member(household_id)));
drop policy if exists price_receipts_insert on public.price_receipts;
create policy price_receipts_insert on public.price_receipts for insert to authenticated
  with check (owner_id = auth.uid() and (household_id is null or public.is_household_member(household_id)));
drop policy if exists price_receipts_update on public.price_receipts;
create policy price_receipts_update on public.price_receipts for update to authenticated
  using (owner_id = auth.uid() or (household_id is not null and public.is_household_member(household_id)))
  with check (owner_id = auth.uid() or (household_id is not null and public.is_household_member(household_id)));
drop policy if exists price_receipts_delete on public.price_receipts;
create policy price_receipts_delete on public.price_receipts for delete to authenticated
  using (owner_id = auth.uid() or (household_id is not null and public.is_household_member(household_id)));

drop trigger if exists price_receipts_touch_synced on public.price_receipts;
create trigger price_receipts_touch_synced before insert or update on public.price_receipts
  for each row execute function public.touch_synced_at();

create table if not exists public.price_scans (
  id          uuid primary key default gen_random_uuid(),
  chain       text not null,
  product_key text not null,
  scanned_on  date not null default current_date,
  provider    text not null default '',
  status      text not null default '',
  found       integer not null default 0,
  created_at  timestamptz not null default now(),
  unique (chain, product_key, scanned_on)
);

alter table public.price_scans enable row level security;
revoke all on public.price_scans from anon, authenticated;
grant select on public.price_scans to authenticated;
drop policy if exists price_scans_select on public.price_scans;
create policy price_scans_select on public.price_scans for select to authenticated
  using (true);

create table if not exists public.price_ai_usage (
  provider text not null,
  day      date not null default current_date,
  requests integer not null default 0,
  primary key (provider, day)
);

alter table public.price_ai_usage enable row level security;
revoke all on public.price_ai_usage from anon, authenticated;

-- Realtime: nové ceny z účtenek se hned objeví i u ostatních v rodině.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public'
         and tablename = 'price_receipts'
     ) then
    alter publication supabase_realtime add table public.price_receipts;
  end if;
end;
$$;
