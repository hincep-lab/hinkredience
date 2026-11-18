-- Akce převzaté přímo z dat oficiálního webu obchodu (např. Penny) mají
-- zdroj „web“. Bez něj databáze uložení odmítla a celé hledání skončilo
-- chybou. Mění se jen povolené hodnoty sloupce provider, nic jiného.
alter table public.price_offers drop constraint if exists price_offers_provider_check;
alter table public.price_offers add constraint price_offers_provider_check
  check (provider in ('gemini', 'openai', 'chatgpt', 'manual', 'web'));
