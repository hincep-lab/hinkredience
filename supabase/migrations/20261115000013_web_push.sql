-- HINKredience° – oznámení i do zavřené aplikace (web push)
--
-- push_subscriptions: zařízení (prohlížeč / aplikace na ploše iPhonu), která
--   chtějí oznámení. Každý vidí a mění jen svoje. Zápis přes funkci
--   push_subscribe, aby šlo zařízení převzít i po odhlášení jiného účtu.
-- push_server_keys: klíč serveru pro podepisování oznámení (VAPID). Zapnuté
--   RLS bez jediné zásady = přihlášení uživatelé ani anonymní role k němu
--   nemají přístup; čte ho jen serverová funkce push.
-- shopping_items.added_by: kdo položku přidal (výchozí = přihlášený), aby
--   telefon neohlašoval vlastní položky z jiného zařízení.
--
-- Nic nemaže ani nepřepisuje a lze ji bezpečně spustit opakovaně.

create table if not exists public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  endpoint   text not null unique check (endpoint like 'https://%'),
  p256dh     text not null,
  auth       text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);

create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon;
grant select, delete on public.push_subscriptions to authenticated;

drop policy if exists push_subscriptions_select on public.push_subscriptions;
create policy push_subscriptions_select on public.push_subscriptions for select to authenticated
  using (user_id = auth.uid());

drop policy if exists push_subscriptions_delete on public.push_subscriptions;
create policy push_subscriptions_delete on public.push_subscriptions for delete to authenticated
  using (user_id = auth.uid());

-- Přihlášení zařízení k oznámením (zařízení dřív patřící jinému účtu převezme).
create or replace function public.push_subscribe(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;
  if coalesce(p_endpoint, '') not like 'https://%' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Neplatné přihlášení k oznámením.' using errcode = '22023';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent, ''), 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        created_at = now();
end;
$$;

revoke all on function public.push_subscribe(text, text, text, text) from public;
grant execute on function public.push_subscribe(text, text, text, text) to authenticated;

create table if not exists public.push_server_keys (
  id          integer primary key check (id = 1),
  public_key  text not null,
  private_jwk jsonb not null,
  created_at  timestamptz not null default now()
);

alter table public.push_server_keys enable row level security;
revoke all on public.push_server_keys from anon, authenticated;

alter table public.shopping_items
  add column if not exists added_by uuid default auth.uid() references auth.users (id) on delete set null;
