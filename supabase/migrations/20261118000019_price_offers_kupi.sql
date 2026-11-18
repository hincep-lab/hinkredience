-- Akce převzaté z přehledu letáků na kupi.cz mají zdroj „kupi“ (přesná cena
-- ze stránky, bez AI). Mění se jen povolené hodnoty sloupce provider.
alter table public.price_offers drop constraint if exists price_offers_provider_check;
alter table public.price_offers add constraint price_offers_provider_check
  check (provider in ('gemini', 'openai', 'chatgpt', 'manual', 'web', 'kupi'));
