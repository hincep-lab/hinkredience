-- HINKredience° – kontrola nákladů na AI (Etapa 2)
--
-- Počítadlo požadavků na AI za den a uživatele. Zapisuje do něj jen funkce
-- ai_register_usage(); uživatel si své počty může přečíst, ale ne přepsat.
-- Denní limity hlídá serverová funkce „ai“.

create table public.ai_usage (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  day        date not null default (now() at time zone 'Europe/Prague')::date,
  kind       text not null check (kind in ('request', 'search')),
  count      integer not null default 0 check (count >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, day, kind)
);

alter table public.ai_usage enable row level security;

create policy ai_usage_select on public.ai_usage for select to authenticated
  using (user_id = auth.uid());

revoke all on public.ai_usage from anon, authenticated;
grant select on public.ai_usage to authenticated;

create or replace function public.ai_register_usage(p_kind text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  today date := (now() at time zone 'Europe/Prague')::date;
  result integer;
begin
  if uid is null then
    raise exception 'Nepřihlášený uživatel.' using errcode = '42501';
  end if;
  if p_kind not in ('request', 'search') then
    raise exception 'Neznámý druh požadavku.' using errcode = '22023';
  end if;
  insert into public.ai_usage as u (user_id, day, kind, count)
  values (uid, today, p_kind, 1)
  on conflict (user_id, day, kind)
  do update set count = u.count + 1, updated_at = now()
  returning u.count into result;
  return result;
end;
$$;

revoke all on function public.ai_register_usage(text) from public;
grant execute on function public.ai_register_usage(text) to authenticated;
