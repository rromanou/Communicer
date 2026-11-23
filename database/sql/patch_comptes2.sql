-- ============================================================================
-- Communicer! — Patch « comptes 2 » (additif, relançable)
-- Historique des noms (réservés), connexion par ancien ou nouveau nom, noms forcés « user1 »,
-- profil d'un ancien nom, courriel/téléphone de récupération, compteur d'envois.
-- À exécuter après patch_compte.sql et patch_sanctions.sql.
-- ============================================================================
create table if not exists public.username_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  hidden boolean not null default false,
  changed_at timestamptz not null default now()
);
create unique index if not exists username_history_name_uq on public.username_history ((lower(name)));
create index if not exists username_history_user on public.username_history (user_id, changed_at desc);
alter table public.username_history enable row level security;
revoke all on public.username_history from anon, authenticated;

create sequence if not exists public.user_num_seq;

-- noms d'origine déjà renommés : le courriel de connexion garde le premier nom
insert into public.username_history(user_id, name, hidden)
select p.id, split_part(u.email, '@', 1), false from public.profiles p join auth.users u on u.id = p.id
where u.email like '%@communicer.app' and split_part(u.email, '@', 1) <> p.username
on conflict ((lower(name))) do nothing;

create or replace function public.trg_name_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare sysn boolean := coalesce(current_setting('app.sys_name', true), '') = '1'; owner uuid;
begin
  if tg_op = 'INSERT' or new.username is distinct from old.username then
    if new.id in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002') then return new; end if;
    if not sysn then
      if new.username ~ '^user[0-9]+$' then raise exception 'Ce nom d’utilisateur n’est pas autorisé'; end if;
      if public.name_forbidden(new.username) then raise exception 'Ce nom d’utilisateur n’est pas autorisé'; end if;
    end if;
    select user_id into owner from public.username_history where lower(name) = lower(new.username);
    if owner is not null and owner <> new.id then raise exception 'Ce nom est réservé à un autre utilisateur'; end if;
    if tg_op = 'UPDATE' and old.username is not null then
      insert into public.username_history(user_id, name, hidden)
      values (old.id, old.username, coalesce(current_setting('app.hide_old', true), '') = '1' or old.username ~ '^(user[0-9]+|user\[[0-9]+\]|del\[[0-9]+\])$')
      on conflict ((lower(name))) do update set changed_at = now(), hidden = public.username_history.hidden or excluded.hidden;
    end if;
    delete from public.username_history where user_id = new.id and lower(name) = lower(new.username);
  end if;
  return new;
end $$;

drop trigger if exists name_guard on public.profiles;
create trigger name_guard before insert or update of username on public.profiles for each row execute function public.trg_name_guard();

-- anciens noms générés user[12] : remplacés par user12
do $$ declare r record; nm text; begin
  perform set_config('app.sys_name', '1', true);
  for r in select id, username from public.profiles where username ~ '^user\[[0-9]+\]$' loop
    nm := 'user' || substring(r.username from '[0-9]+');
    while exists(select 1 from public.profiles where username = nm) or exists(select 1 from public.username_history where lower(name) = nm) loop nm := 'user' || nextval('public.user_num_seq'); end loop;
    update public.profiles set username = nm where id = r.id;
  end loop;
end $$;

create or replace function public.name_available(p_name text) returns text language plpgsql security definer stable set search_path = public as $$
declare n text := lower(trim(coalesce(p_name, '')));
begin
  if n !~ '^[a-z0-9_]{3,20}$' then return 'format'; end if;
  if n ~ '^user[0-9]+$' or public.name_forbidden(n) then return 'forbidden'; end if;
  if exists(select 1 from public.profiles where lower(username) = n and id is distinct from auth.uid())
     or exists(select 1 from public.bots where lower(username) = n and status <> 'deleted')
     or exists(select 1 from public.username_history where lower(name) = n and user_id is distinct from auth.uid())
     or exists(select 1 from auth.users where lower(email) = n || '@communicer.app' and id is distinct from auth.uid()) then return 'taken'; end if;
  return 'ok';
end $$;
create or replace function public.name_check(p_name text) returns boolean language sql security definer stable set search_path = public as $$ select public.name_available(p_name) in ('ok','taken') $$;
grant execute on function public.name_available(text), public.name_check(text) to anon, authenticated;

-- connexion : le courriel interne dépend du nom d'origine ; le nom actuel ou un ancien nom fonctionnent
create or replace function public.login_email(p_username text) returns text language plpgsql security definer stable set search_path = public as $$
declare n text := lower(regexp_replace(trim(coalesce(p_username, '')), '^@', '')); v uuid; e text;
begin
  select id into v from public.profiles where lower(username) = n;
  if v is null then select user_id into v from public.username_history where lower(name) = n; end if;
  if v is not null then select email into e from auth.users where id = v; end if;
  if e is not null and e like '%@communicer.app' then return e; end if;
  return n || '@communicer.app';
end $$;
revoke all on function public.login_email(text) from public;
grant execute on function public.login_email(text) to anon, authenticated;

-- profil d'un ancien nom : renvoie le nom actuel
create or replace function public.name_resolve(p_name text) returns text language sql security definer stable set search_path = public as $$
  select coalesce((select username from public.profiles where lower(username) = lower(regexp_replace(trim(coalesce(p_name,'')), '^@', ''))),
    (select p.username from public.username_history h join public.profiles p on p.id = h.user_id where lower(h.name) = lower(regexp_replace(trim(coalesce(p_name,'')), '^@', ''))))
$$;
create or replace function public.username_history_of(p_username text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid; cur text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  cur := public.name_resolve(p_username);
  select id into v from public.profiles where username = cur;
  if v is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', n, 'at', at, 'current', cu) order by cu desc, at desc) from (
      select cur as n, null::timestamptz as at, true as cu
      union all select h.name, h.changed_at, false from public.username_history h where h.user_id = v and not h.hidden) q), '[]'::jsonb);
end $$;
revoke all on function public.name_resolve(text), public.username_history_of(text) from public, anon;
grant execute on function public.name_resolve(text), public.username_history_of(text) to authenticated;

create or replace function public.rename_me(p_new text)
returns text language plpgsql security definer set search_path = public as $$
declare n text := lower(trim(coalesce(p_new,''))); old text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if n !~ '^[a-z0-9_]{3,20}$' then raise exception 'Nom invalide (3 à 20 caractères : lettres, chiffres, _)'; end if;
  if n = (select username from public.profiles where id = auth.uid()) then raise exception 'C’est déjà votre nom'; end if;
  case public.name_available(n) when 'taken' then raise exception 'Ce nom est déjà pris ou réservé'; when 'forbidden' then raise exception 'Ce nom d’utilisateur n’est pas autorisé'; when 'ok' then null; else raise exception 'Nom invalide'; end case;
  update public.profile_ext set rename_credits = rename_credits - 1 where user_id = auth.uid() and rename_credits > 0;
  if not found then raise exception 'Achetez d’abord un changement de nom'; end if;
  select username into old from public.profiles where id = auth.uid();
  update public.profiles set username = n where id = auth.uid();
  insert into public.token_log(user_id, delta, reason) values (auth.uid(), 0, 'nom changé : ' || old || ' vers ' || n);
  return n;
end $$;
create or replace function public.profile_mod(p_username text, p_action text, p_reason text, p_credit boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare t record; nm text;
begin
  select * into t from public._target(p_username);
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  if p_action = 'photo' then update public.profiles set avatar_url = null where id = t.uid;
  elsif p_action = 'nickname' then update public.profiles set nickname = null where id = t.uid;
  elsif p_action = 'bio' then update public.profiles set bio = null where id = t.uid;
  elsif p_action = 'bg' then update public.profile_ext set profile_bg = null where user_id = t.uid;
  elsif p_action = 'username' then
    loop
      nm := 'user' || nextval('public.user_num_seq')::text;
      exit when not exists(select 1 from public.profiles where username = nm) and not exists(select 1 from public.username_history where lower(name) = nm);
    end loop;
    perform set_config('app.sys_name', '1', true); perform set_config('app.hide_old', '1', true);
    update public.profiles set username = nm where id = t.uid;
    perform set_config('app.sys_name', '', true); perform set_config('app.hide_old', '', true);
    if p_credit then insert into public.profile_ext(user_id, rename_credits) values (t.uid, 1) on conflict (user_id) do update set rename_credits = public.profile_ext.rename_credits + 1; end if;
  else raise exception 'Action inconnue'; end if;
  insert into public.casier(user_id, kind, reason, message, by_id, by_name) values (t.uid, 'profile', left(p_reason, 300),
    case p_action when 'photo' then 'Photo de profil retirée' when 'nickname' then 'Surnom retiré' when 'bio' then 'Description retirée' when 'bg' then 'Fond de profil retiré'
      else 'Nom d’utilisateur remplacé' || case when p_credit then ' (un renommage gratuit vous est accordé)' else '' end end,
    auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('profil_modere', t.uname, jsonb_build_object('action', p_action, 'reason', p_reason, 'credit', p_credit));
end $$;

-- ---------- téléphone de récupération, compteur d'envois ----------
create table if not exists public.contact_phones (
  user_id uuid primary key references public.profiles(id) on delete cascade, phone text not null,
  verified_at timestamptz, created_at timestamptz not null default now()
);
create unique index if not exists contact_phones_uq on public.contact_phones (phone) where verified_at is not null;
alter table public.contact_phones enable row level security; revoke all on public.contact_phones from anon, authenticated;
create table if not exists public.mail_log (
  id bigint generated always as identity primary key, channel text not null check (channel in ('email','sms')), kind text not null,
  user_id uuid, created_at timestamptz not null default now()
);
create index if not exists mail_log_at on public.mail_log (created_at desc);
alter table public.mail_log enable row level security; revoke all on public.mail_log from anon, authenticated;

create or replace function public.phone_get() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce((select jsonb_build_object('phone', regexp_replace(phone, '^(\+[0-9]{1,3}).*([0-9]{2})$', '\1 *** ** \2'), 'verified', verified_at is not null) from public.contact_phones where user_id = auth.uid()), jsonb_build_object('phone', null, 'verified', false))
$$;
create or replace function public.phone_remove() returns void language sql security definer set search_path = public as $$
  delete from public.contact_phones where user_id = auth.uid()
$$;
create or replace function public.mail_stats() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs et au commandant'; end if;
  return jsonb_build_object(
    'last_hour_email', (select count(*) from public.mail_log where channel = 'email' and created_at > now() - interval '1 hour'),
    'last_hour_sms', (select count(*) from public.mail_log where channel = 'sms' and created_at > now() - interval '1 hour'),
    'today', (select count(*) from public.mail_log where created_at > date_trunc('day', now())),
    'by_hour', coalesce((select jsonb_agg(jsonb_build_object('h', h, 'n', n) order by h) from (select date_trunc('hour', created_at) h, count(*) n from public.mail_log where created_at > now() - interval '24 hours' group by 1) q), '[]'::jsonb));
end $$;
revoke all on function public.phone_get(), public.phone_remove(), public.mail_stats() from public, anon;
grant execute on function public.phone_get(), public.phone_remove(), public.mail_stats() to authenticated;
