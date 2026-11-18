-- Fotka zboží u akce (zatím z kupi.cz). Jen nový sloupec, nic se nemaže.
alter table public.price_offers
  add column if not exists image_url text not null default '';
alter table public.price_offers drop constraint if exists price_offers_image_url_check;
alter table public.price_offers add constraint price_offers_image_url_check
  check (image_url = '' or image_url like 'https://%');
