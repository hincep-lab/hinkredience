-- Akce: druh ceny (akční / věrnostní / běžná), věrnostní program a záznam
-- o každém stažení letáků. Nic se nemaže – běžné ceny se jen skryjí a
-- nabídky ověřené jen čtením AI nebo bez gramáže se označí jako neověřené.

alter table public.price_offers
  add column if not exists kind text not null default 'promo',
  add column if not exists loyalty text not null default '';

alter table public.price_offers drop constraint if exists price_offers_kind_check;
alter table public.price_offers add constraint price_offers_kind_check
  check (kind in ('promo', 'loyalty', 'regular'));

-- Záznam o stažení zdrojů řetězce (naposledy aktualizováno, varování).
create table if not exists public.price_runs (
  id      bigint generated always as identity primary key,
  chain   text not null,
  ran_at  timestamptz not null default now(),
  ok      boolean not null,
  error   text not null default '',
  offers  integer not null default 0
);
create index if not exists price_runs_chain_idx on public.price_runs (chain, ran_at desc);

alter table public.price_runs enable row level security;
revoke all on public.price_runs from anon;
revoke insert, update, delete on public.price_runs from authenticated;
grant select on public.price_runs to authenticated;
drop policy if exists price_runs_select on public.price_runs;
create policy price_runs_select on public.price_runs for select to authenticated
  using (true);

-- Roztřídění uložených nabídek. Funkci smí spustit jen server (není
-- povolená pro přihlášené ani anonymní uživatele) a je opakovatelná.
create or replace function public.price_offers_classify()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Běžná (neakční) cena není akce.
  update price_offers set kind = 'regular'
   where kind <> 'regular'
     and lower(conditions) ~ '(běžná cena|bezna cena|původní cena|puvodni cena)';

  -- Věrnostní ceny (karta, aplikace, kupon); „bez karty/aplikace“ není věrnostní.
  update price_offers o set kind = 'loyalty',
         loyalty = case o.chain
           when 'tesco' then 'Clubcard'
           when 'albert' then 'Můj Albert'
           when 'penny' then 'PENNY karta'
           when 'lidl' then 'Lidl Plus'
           when 'jip' then 'věrnostní karta JIP'
           when 'coop' then 'věrnostní karta COOP'
           else 'věrnostní karta' end
   where o.kind = 'promo'
     and lower(o.conditions) ~ '(clubcard|aplikac|penny kart|lidl plus|můj albert|kupon|s kartou)'
     and lower(o.conditions) !~ 'bez\s+\S*\s*(aplikac|kart|clubcard)';

  -- Původní cena akce z řádku „běžná cena“ téhož zboží a balení.
  update price_offers p set regular_price = r.price
    from price_offers r
   where r.kind = 'regular' and p.kind <> 'regular'
     and p.regular_price is null
     and r.chain = p.chain and coalesce(r.store_id, '') = coalesce(p.store_id, '')
     and r.product_key = p.product_key
     and r.pack_qty is not distinct from p.pack_qty and r.pack_unit = p.pack_unit
     and r.valid_to = p.valid_to
     and r.price > p.price;

  -- Prohozené ceny s kartou a bez karty: věrnostní cena je vždy ta nižší.
  -- (Albert, Česká chuť máslo 82 % 250 g, 18.–24. 11. 2026: 27,90 Kč
  -- s aplikací Můj Albert, 32,90 Kč bez aplikace – v databázi obráceně.)
  with pairs as (
    select l.id as loyal_id, w.id as plain_id, l.conditions as lc, w.conditions as wc
      from price_offers l
      join price_offers w
        on w.chain = l.chain and coalesce(w.store_id, '') = coalesce(l.store_id, '')
       and w.product_key = l.product_key
       and w.pack_qty is not distinct from l.pack_qty and w.pack_unit = l.pack_unit
       and w.valid_to = l.valid_to
     where l.kind = 'loyalty' and w.kind = 'promo'
       and lower(w.conditions) ~ '^bez\s'
       and l.price > w.price
  )
  update price_offers o set
         conditions = case when o.id = pairs.loyal_id then pairs.wc else pairs.lc end,
         kind = case when o.id = pairs.loyal_id then 'promo' else 'loyalty' end,
         loyalty = case when o.id = pairs.loyal_id then ''
           else (select loyalty from price_offers where id = pairs.loyal_id) end
    from pairs
   where o.id in (pairs.loyal_id, pairs.plain_id);

  -- Ověřená = cena, zboží, gramáž a platnost potvrzené z oficiálního zdroje.
  -- Samotné čtení AI (i dvakrát) ani citace nestačí; dřívější ověření
  -- textem letáku nekontrolovalo gramáž, proto se ověří znovu.
  update price_offers set
         verified = false,
         verified_at = null,
         source_title = case verify_method
           when 'leták-2×' then 'jen čtení AI – cena v textu letáku není, neověřeno'
           when 'citace' then 'jen citace z odpovědi AI – neověřeno'
           else 'čeká na nové ověření (cena i gramáž v textu letáku)' end
   where verified and verify_method in ('leták-2×', 'leták-text', 'citace');
end;
$$;

revoke all on function public.price_offers_classify() from public, anon, authenticated;

select public.price_offers_classify();
