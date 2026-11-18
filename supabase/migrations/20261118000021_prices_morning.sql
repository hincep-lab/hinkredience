-- Ranní obnovení akcí: databáze každé ráno sama zavolá serverovou funkci
-- prices (pg_cron + pg_net). Funkce ji pustí jen s tajným klíčem, který
-- vznikne tady v databázi a nikdy ji neopustí (tabulka bez přístupu pro
-- přihlášené i anonymní uživatele; čte ji jen server servisním klíčem).
-- Opakovatelné: klíč se vytvoří jen jednou, plán se jen přepíše.

create table if not exists public.price_cron_key (
  id         integer primary key check (id = 1),
  key        text not null check (length(key) >= 32),
  created_at timestamptz not null default now()
);
alter table public.price_cron_key enable row level security;
revoke all on public.price_cron_key from anon, authenticated;

insert into public.price_cron_key (id, key)
values (1, replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

-- Plán jen tam, kde pg_cron a pg_net jsou (na Supabase ano, v testech ne).
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'pg_cron / pg_net nejsou k dispozici – ranní obnovení se nenaplánuje.';
    return;
  end if;
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
  -- 4:23, 4:26 a 4:29 UTC (5:23–5:29 v zimě): tři dávky po 20 položkách.
  perform cron.schedule(
    'prices-morning-' || o,
    (23 + o / 20 * 3)::text || ' 4 * * *',
    format(
      $job$select net.http_post(
        url := 'https://wjqpzoeheonjwdyyezhb.supabase.co/functions/v1/prices',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-key', (select key from public.price_cron_key where id = 1)
        ),
        body := jsonb_build_object('action', 'scheduled', 'offset', %s),
        timeout_milliseconds := 150000
      )$job$,
      o
    )
  )
  from unnest(array[0, 20, 40]) as o;
end;
$$;
