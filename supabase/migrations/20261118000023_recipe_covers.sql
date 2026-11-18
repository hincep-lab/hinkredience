-- Automatické hlavní fotografie receptů (AI obrázek hotového jídla) přes
-- Cloudflare Workers AI na bezplatném tarifu (Workers Free): po vyčerpání
-- denního přídělu požadavky jen selžou, nic se neúčtuje.
--
-- Bezpečnost:
--  * Vše je ve výchozím stavu VYPNUTÉ (recipe_cover_settings.enabled = false).
--  * Fotku jde přidat jen receptu, který žádnou nemá (podmínka přímo v
--    UPDATE – existující fotku nic nepřepíše ani nesmaže).
--  * Denní limit hlídá databáze v jedné transakci se zámkem, takže ani dva
--    souběžné běhy limit nepřekročí.
--  * Každý recept má nejvýš 2 nepovedené pokusy; vyčerpaný denní příděl
--    se za pokus nepočítá (recept přijde na řadu další den). Rozpracovaná
--    úloha se při opakování dokončí, ne vygeneruje znovu.
--  * Tabulky ani funkce nejsou přístupné přihlášeným ani anonymním
--    uživatelům – volá je jen serverová funkce recipe-covers.
-- Opakovatelné.

create table if not exists public.recipe_cover_settings (
  id           integer primary key check (id = 1),
  enabled      boolean not null default false,
  daily_limit  integer not null default 5 check (daily_limit between 0 and 5),
  model        text not null default '@cf/black-forest-labs/flux-1-schnell'
                 check (model like '@cf/%'),
  steps        integer not null default 8 check (steps between 1 and 8),
  updated_at   timestamptz not null default now()
);
alter table public.recipe_cover_settings enable row level security;
revoke all on public.recipe_cover_settings from anon, authenticated;
insert into public.recipe_cover_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.recipe_cover_jobs (
  id          uuid primary key default gen_random_uuid(),
  recipe_id   uuid not null references public.recipes (id) on delete cascade,
  owner_id    uuid not null,
  status      text not null default 'reserved'
                check (status in ('reserved', 'generated', 'uploaded', 'attached',
                                  'skipped', 'failed', 'postponed')),
  photo_id    uuid not null default gen_random_uuid(),
  path        text not null default '',
  model       text not null default '',
  error       text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists recipe_cover_jobs_recipe_idx on public.recipe_cover_jobs (recipe_id);
create index if not exists recipe_cover_jobs_created_idx on public.recipe_cover_jobs (created_at);
-- Jeden recept = nejvýš jedna rozpracovaná nebo hotová úloha.
create unique index if not exists recipe_cover_jobs_active_uidx
  on public.recipe_cover_jobs (recipe_id)
  where status in ('reserved', 'generated', 'uploaded', 'attached');
alter table public.recipe_cover_jobs enable row level security;
revoke all on public.recipe_cover_jobs from anon, authenticated;

-- Přehled: kolik obrázků se dnes objednalo a kolik receptů je hotových.
create or replace function public.cover_usage()
returns table (today_count integer, attached_total integer, waiting integer,
               enabled boolean, daily_limit integer)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::integer from recipe_cover_jobs
      where (created_at at time zone 'Europe/Prague')::date = (now() at time zone 'Europe/Prague')::date
        and status <> 'postponed'),
    (select count(*)::integer from recipe_cover_jobs where status = 'attached'),
    (select count(*)::integer from recipes
      where deleted_at is null and coalesce(jsonb_array_length(photos), 0) = 0),
    s.enabled, s.daily_limit
  from recipe_cover_settings s where s.id = 1
$$;

-- Vybere recepty bez fotky a zarezervuje je (nejvýš p_limit a denní limit).
-- Nejdřív vrátí rozpracované úlohy (vygenerovaný / nahraný, ale nepřiřazený
-- obrázek), které se dokončí bez nového generování.
-- p_dry_run = true: jen ukáže, co by se vybralo, nic nezapíše.
create or replace function public.cover_reserve(p_limit integer, p_dry_run boolean default false)
returns table (job_id uuid, recipe_id uuid, owner_id uuid, photo_id uuid, path text,
               status text, title text, description text, category text,
               tags jsonb, ingredients jsonb, steps jsonb, reason text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  s recipe_cover_settings;
  used_today integer;
  room integer;
begin
  select * into s from recipe_cover_settings where id = 1;
  if not found then
    return;
  end if;
  -- Jeden běh naráz (zámek drží do konce transakce).
  if not p_dry_run then
    perform pg_advisory_xact_lock(hashtext('recipe_cover_reserve'));
    -- Rezervace starší než 30 minut, u nichž se nic nedokončilo, selžou.
    update recipe_cover_jobs j
       set status = 'failed', error = 'Přerušeno', updated_at = now()
     where j.status = 'reserved' and j.updated_at < now() - interval '30 minutes';
  end if;

  select u.today_count into used_today from cover_usage() u;
  room := least(greatest(p_limit, 0), 5, greatest(s.daily_limit - used_today, 0));

  -- 1) Dokončení: obrázek je už v úložišti, jen nepřiřazený.
  if not p_dry_run then
    return query
      select j.id, j.recipe_id, j.owner_id, j.photo_id, j.path, j.status,
             r.title, r.description, r.category, r.tags,
             '[]'::jsonb, '[]'::jsonb, 'dokončení'::text
        from recipe_cover_jobs j
        join recipes r on r.id = j.recipe_id
       where j.status in ('generated', 'uploaded') and j.path <> ''
       order by j.created_at
       limit 5;
  end if;

  if (not s.enabled and not p_dry_run) or room <= 0 then
    return;
  end if;

  return query
    with picked as (
      select r.id, r.owner_id, r.title, r.description, r.category, r.tags, r.created_at
        from recipes r
       where r.deleted_at is null
         and coalesce(jsonb_array_length(r.photos), 0) = 0
         and length(trim(r.title)) > 0
         and not exists (
           select 1 from recipe_cover_jobs j
            where j.recipe_id = r.id
              and j.status in ('reserved', 'generated', 'uploaded', 'attached'))
         and (select count(*) from recipe_cover_jobs j
               where j.recipe_id = r.id and j.status = 'failed') < 2
       order by r.created_at
       limit room
    ),
    ins as (
      insert into recipe_cover_jobs (recipe_id, owner_id, model)
      select p.id, p.owner_id, s.model
        from picked p
       where not p_dry_run
      returning id, recipe_id, photo_id
    )
    select i.id, p.id, p.owner_id, i.photo_id,
           coalesce(p.owner_id::text || '/' || p.id::text || '/' || i.photo_id::text || '.jpg', ''),
           case when p_dry_run then 'dry-run' else 'reserved' end,
           p.title, p.description, p.category, p.tags,
           coalesce((select jsonb_agg(jsonb_build_object('name', i2.name) order by i2.position)
                       from recipe_ingredients i2 where i2.recipe_id = p.id), '[]'::jsonb),
           coalesce((select jsonb_agg(s2.instruction order by s2.position)
                       from recipe_steps s2 where s2.recipe_id = p.id), '[]'::jsonb),
           'nový'::text
      from picked p
      left join ins i on i.recipe_id = p.id
     order by p.created_at;
end;
$$;

-- Zapíše průběh úlohy. Cesta jen ve tvaru <vlastník>/<recept>/<fotka>.jpg
-- (nebo .png, podle toho, co model vrátí).
create or replace function public.cover_progress(p_job uuid, p_status text,
                                                 p_path text default null,
                                                 p_error text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  j recipe_cover_jobs;
  base text;
begin
  select * into j from recipe_cover_jobs where id = p_job for update;
  if not found then
    raise exception 'Úloha nenalezena.';
  end if;
  if p_status not in ('generated', 'uploaded', 'skipped', 'failed', 'postponed') then
    raise exception 'Neplatný stav úlohy.';
  end if;
  if j.status in ('attached', 'skipped', 'failed', 'postponed') then
    return; -- uzavřené úlohy se už nemění
  end if;
  base := j.owner_id::text || '/' || j.recipe_id::text || '/' || j.photo_id::text;
  if p_path is not null and p_path <> '' and p_path not in (base || '.jpg', base || '.png') then
    raise exception 'Neplatná cesta fotky.';
  end if;
  update recipe_cover_jobs set
    status = p_status,
    path = case when p_path is not null and p_path <> '' then p_path else path end,
    error = left(coalesce(p_error, error), 500),
    updated_at = now()
  where id = p_job;
end;
$$;

-- Přiřadí nahraný obrázek jako hlavní fotku – JEN když recept žádnou fotku
-- nemá. Vrátí true, když se fotka opravdu uložila. Nic jiného na receptu
-- nemění (suroviny, postup, verze zůstávají).
create or replace function public.cover_attach_if_empty(p_job uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  j recipe_cover_jobs;
  n integer;
begin
  select * into j from recipe_cover_jobs where id = p_job for update;
  if not found or j.status <> 'uploaded' or j.path = '' then
    return false;
  end if;
  update recipes
     set photos = jsonb_build_array(jsonb_build_object('id', j.photo_id, 'remote_path', j.path)),
         updated_at = now()
   where id = j.recipe_id
     and deleted_at is null
     and coalesce(jsonb_array_length(photos), 0) = 0;
  get diagnostics n = row_count;
  update recipe_cover_jobs
     set status = case when n = 1 then 'attached' else 'skipped' end,
         error = case when n = 1 then '' else 'Recept mezitím dostal fotku nebo byl smazán.' end,
         updated_at = now()
   where id = p_job;
  return n = 1;
end;
$$;

revoke all on function public.cover_usage() from public, anon, authenticated;
revoke all on function public.cover_reserve(integer, boolean) from public, anon, authenticated;
revoke all on function public.cover_progress(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.cover_attach_if_empty(uuid) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.cover_usage() to service_role;
    grant execute on function public.cover_reserve(integer, boolean) to service_role;
    grant execute on function public.cover_progress(uuid, text, text, text) to service_role;
    grant execute on function public.cover_attach_if_empty(uuid) to service_role;
  end if;
end;
$$;

-- Denní spuštění (jen naplánování – dokud je enabled = false, funkce nic
-- negeneruje). 11:13 UTC (12:13 v zimě). Klíč plánované úlohy je společný
-- s ranním obnovením akcí a nikdy neopustí databázi.
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice 'pg_cron / pg_net nejsou k dispozici – fotky se nenaplánují.';
    return;
  end if;
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
  perform cron.schedule(
    'recipe-covers-daily',
    '13 11 * * *',
    $job$select net.http_post(
      url := 'https://wjqpzoeheonjwdyyezhb.supabase.co/functions/v1/recipe-covers',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-key', (select key from public.price_cron_key where id = 1)
      ),
      body := jsonb_build_object('action', 'run', 'limit', 5),
      timeout_milliseconds := 300000
    )$job$
  );
end;
$$;
