-- Aktuální ověřené akce pro upozornění na pozadí (Android bez otevřené
-- aplikace). Vrací jen veřejné akční ceny obchodů – název zboží, cenu,
-- balení, platnost, zdroj a fotku – nic osobního (ne kdo akci uložil).
-- Telefon na pozadí tak nemusí používat přihlášení (obnova přihlašovacího
-- tokenu zároveň s otevřenou aplikací by uživatele mohla odhlásit).
-- Tabulka price_offers zůstává jen pro přihlášené.

create or replace function public.current_sale_offers()
returns table (
  id uuid, chain text, store_id text, product text, label text, price numeric,
  pack_qty numeric, pack_unit text, regular_price numeric, conditions text,
  kind text, loyalty text, valid_from date, valid_to date, source_url text,
  image_url text, verified boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.chain, o.store_id, o.product, o.label, o.price, o.pack_qty, o.pack_unit,
         o.regular_price, o.conditions, o.kind, o.loyalty, o.valid_from, o.valid_to,
         o.source_url, o.image_url, o.verified
    from public.price_offers o
   where o.verified
     and o.kind <> 'regular'
     and o.valid_to >= (now() at time zone 'Europe/Prague')::date
   order by o.price
   limit 3000;
$$;

revoke all on function public.current_sale_offers() from public;
grant execute on function public.current_sale_offers() to anon, authenticated;
