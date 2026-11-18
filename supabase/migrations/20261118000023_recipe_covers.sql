-- Automatické hlavní fotografie receptů (AI obrázek hotového jídla).
--
-- Bezpečnost:
--  * Vše je ve výchozím stavu VYPNUTÉ (recipe_cover_settings.enabled = false).
--  * Fotku jde přidat jen receptu, který žádnou nemá (podmínka přímo v
--    UPDATE – existující fotku nic nepřepíše ani nesmaže).
--  * Rozpočet a denní limit hlídá databáze v jedné transakci se zámkem, takže
--    ani dva souběžné běhy limit nepřekročí.
--  * Každý recept má nejvýš 2 pokusy; rozpracovaná úloha se při opakování
--    dokončí (znovu se nahraje / přiřadí), ne vygeneruje a nezaplatí znovu.
--  * Tabulky ani funkce nejsou přístupné přihlášeným ani anonymním
--    uživatelům – volá je jen serverová funkce recipe-covers.
-- Opakovatelné.

create table if not exists public.recipe_cover_settings (
  id                   integer primary key check (id = 1),
  enabled              boolean not null default false,
  daily_limit          integer not null default 5 check (daily_limit between 0 and 5),
  monthly_budget_usd   numeric(8, 2) not null default 2.00
                         check (monthly_budget_usd >= 0 and monthly_budget_usd <= 20),
  price_per_image_usd  numeric(8, 4) not null default 0.041 check (price_per_image_usd > 0),
  model                text not null default 'gpt-image-2',
  quality              text not null default 'medium' check (quality in ('low', 'medium')),
  size                 text not null default '1536x1024'
                         check (size in ('1024x1024', '1536x1024', '1024x1536')),
  updated_at           timestamptz not null default now()
);
alter table public.recipe_cover_settings enable row level security;
revoke all on public.recipe_cover_settings from anon, authenticated;
insert into public.recipe_cover_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.recipe_cover_jobs (
  id          uuid primary key default gen_random_uuid(),
  recipe_id   uuid not null references public.recipes (id) on delete cascade,
  owner_id    uuid not null,
  status      text not null default 'reserved'
                check (status in ('reserved', 'generated', 'uploaded', 'attached', 'skipped', 'failed')),
  photo_id    uuid not null default gen_random_uuid(),
  path        text not null default '',
  -- Odhad útraty: počítá se od chvíle, kdy byl obrázek objednán (i když
  -- odpověď nedorazila – OpenAI ho mohlo vyúčtovat).
  cost_usd    numeric(8, 4) not null default 0,
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

-- Přehled útraty (pro kontrolu a pro rozhodnutí o rozpočtu).
create or replace function public.cover_usage()
returns table (today_count integer, month_usd numeric, enabled boolean,
               daily_limit integer, monthly_budget_usd numeric)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::integer from recipe_cover_jobs
      where (created_at at time zone 'Europe/Prague')::date = (now() at time zone 'Europe/Prague')::date
        and cost_usd > 0),
    (select coalesce(sum(cost_usd), 0) from recipe_cover_jobs
      where date_trunc('month', created_at at time zone 'Europe/Prague')
          = date_trunc('month', now() at time zone 'Europe/Prague')),
    s.enabled, s.daily_limit, s.monthly_budget_usd
  from recipe_cover_settings s where s.id = 1
$$;

-- Vybere recepty bez fotky a zarezervuje je (nejvýš p_limit, denní limit
-- a měsíční rozpočet). Nejdřív vrátí rozpracované úlohy (nahraný, ale
-- nepřiřazený obrázek), které se dokončí bez nového generování.
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
  spent numeric;
  room integer;
begin
  select * into s from recipe_cover_settings where id = 1;
  if not found then
    return;
  end if;
  -- Jeden běh naráz (zámek drží do konce transakce).
  if not p_dry_run then
    perform pg_advisory_xact_lock(hashtext('recipe_cover_reserve'));
  end if;

  -- Rozpracované úlohy starší než 30 minut: obrázek mohl být vyúčtován,
  -- ale výsledek neznáme – úloha selže (útrata zůstane započtená).
  if not p_dry_run then
    update recipe_cover_jobs j
       set status = 'failed', error = 'Přerušeno – výsledek neznámý', updated_at = now()
     where j.status = 'reserved' and j.updated_at < now() - interval '30 minutes';
  end if;

  select u.today_count, u.month_usd into used_today, spent from cover_usage() u;
  room := least(
    greatest(p_limit, 0),
    5,
    greatest(s.daily_limit - used_today, 0),
    floor(greatest(s.monthly_budget_usd - spent, 0) / s.price_per_image_usd)::integer
  );

  -- 1) Dokončení: obrázek je nahraný / vygenerovaný, jen nepřiřazený.
  return query
    select j.id, j.recipe_id, j.owner_id, j.photo_id, j.path, j.status,
           r.title, r.description, r.category, r.tags,
           '[]'::jsonb, '[]'::jsonb, 'dokončení'::text
      from recipe_cover_jobs j
      join recipes r on r.id = j.recipe_id
     where j.status in ('generated', 'uploaded') and j.path <> ''
     order by j.created_at
     limit 5;

  if not s.enabled and not p_dry_run then
    return;
  end if;
  if room <= 0 then
    return;
  end if;

  return query
    with picked as (
      select r.id, r.owner_id, r.title, r.description, r.category, r.tags
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
      insert into recipe_cover_jobs (recipe_id, owner_id, path, cost_usd, model)
      select p.id, p.owner_id, '', s.price_per_image_usd, s.model
        from picked p
       where not p_dry_run
      returning id, recipe_id, owner_id, photo_id
    )
    select coalesce(i.id, null), p.id, p.owner_id, coalesce(i.photo_id, null),
           coalesce(p.owner_id::text || '/' || p.id::text || '/' || i.photo_id::text || '.jpg', ''),
           case when p_dry_run then 'dry-run' else 'reserved' end,
           p.title, p.description, p.category, p.tags,
           coalesce((select jsonb_agg(jsonb_build_object('name', i2.name) order by i2.position)
                       from recipe_ingredients i2 where i2.recipe_id = p.id), '[]'::jsonb),
           coalesce((select jsonb_agg(s2.instruction order by s2.position)
                       from recipe_steps s2 where s2.recipe_id = p.id), '[]'::jsonb),
           'nový'::text
      from picked p
      left join ins i on i.recipe_id = p.id;
end;
$$;

-- Zapíše průběh úlohy (vygenerováno, nahráno, chyba…). Cesta se nastaví
-- jen jednou a jen ve tvaru <vlastník>/<recept>/<fotka>.jpg.
create or replace function public.cover_progress(p_job uuid, p_status text,
                                                 p_path text default null,
                                                 p_error text default null,
                                                 p_cost numeric default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  j recipe_cover_jobs;
begin
  select * into j from recipe_cover_jobs where id = p_job for update;
  if not found then
    raise exception 'Úloha nenalezena.';
  end if;
  if p_status not in ('generated', 'uploaded', 'skipped', 'failed') then
    raise exception 'Neplatný stav úlohy.';
  end if;
  if j.status in ('attached', 'skipped') then
    return; -- hotové úlohy se už nemění
  end if;
  if p_path is not null and p_path <> ''
     and p_path <> j.owner_id::text || '/' || j.recipe_id::text || '/' || j.photo_id::text || '.jpg' then
    raise exception 'Neplatná cesta fotky.';
  end if;
  update recipe_cover_jobs set
    status = p_status,
    path = case when p_path is not null and p_path <> '' then p_path else path end,
    error = left(coalesce(p_error, error), 500),
    cost_usd = case when p_cost is not null and p_cost >= 0 then p_cost else cost_usd end,
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
revoke all on function public.cover_progress(uuid, text, text, text, numeric) from public, anon, authenticated;
revoke all on function public.cover_attach_if_empty(uuid) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.cover_usage() to service_role;
    grant execute on function public.cover_reserve(integer, boolean) to service_role;
    grant execute on function public.cover_progress(uuid, text, text, text, numeric) to service_role;
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
