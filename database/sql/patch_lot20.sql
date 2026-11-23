-- Lot 20 (additif) : messages de bots, IP unique par compte, drapeaux de compte, liste des anciens noms
-- 1) Les messages de bots (corps encodé BOTSENT + JSON) ne sont plus rejetés (>100 car.) ni dédoublonnés
create or replace function public.trg_msg_limits() returns trigger language plpgsql security definer set search_path = public as $$
declare cv record; b text; n int;
begin
  if new.kind is distinct from 'text' or new.body is null then return new; end if;
  if new.sender_id is distinct from auth.uid() or public._is_official(new.sender_id) then return new; end if;
  select kind, mode, hub into cv from public.conversations where id = new.conversation_id;
  if cv.hub = 'system' and new.sender_id is distinct from 'aaaaaaaa-0000-4000-8000-000000000001' then raise exception 'Vous ne pouvez pas répondre à @system : utilisez @staff pour écrire à l’équipe'; end if;
  if cv.hub = 'ticket' and exists(select 1 from public.support_tickets t where t.conv = new.conversation_id and t.status = 'closed') then raise exception 'Cette demande est fermée'; end if;
  if cv.hub in ('system','ticket') or cv.kind = 'self' or cv.mode = 'e2e' then return new; end if;
  if left(new.body, 6) = (chr(8291) || chr(8292) || 'bot' || chr(8292)) then
    if char_length(new.body) > 8000 then raise exception 'Message de bot trop long'; end if;
    return new;
  end if;
  if char_length(new.body) > 100 then raise exception 'Message trop long (100 caractères maximum)'; end if;
  b := lower(btrim(regexp_replace(new.body, '\s+', ' ', 'g')));
  select count(*) into n from public.messages m where m.sender_id = new.sender_id and m.kind = 'text' and m.created_at > now() - interval '5 minutes'
     and lower(btrim(regexp_replace(coalesce(m.body, ''), '\s+', ' ', 'g'))) = b;
  if n >= 2 then
    perform public.sys_notify(new.sender_id, 'Avertissement : vous avez envoyé trois fois le même message en moins de 5 minutes. Le dernier message n’a pas été envoyé. Évitez de répéter vos messages.');
    return null;
  end if;
  return new;
end $$;

-- 2) IP : notée une seule fois par compte (jamais réécrite si identique)
create or replace function public.register_ip()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_ip text := public.req_ip(); v_first boolean;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if v_ip is not null then
    select not exists(select 1 from public.user_ips where user_id = v_me) into v_first;
    insert into public.user_ips(user_id, ip, is_signup) values (v_me, v_ip, v_first)
      on conflict (user_id, ip) do nothing;
  end if;
  return public.ban_state(v_me) || jsonb_build_object('dev', public.dev_check(v_me));
end $$;

-- 3) Drapeaux de compte (administrateurs). Le compte visé ne voit jamais son propre drapeau.
create table if not exists public.account_flags (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  flag text not null check (flag in ('suspect','dangereux','faux','avert1','avert2','avert3')),
  set_by uuid, set_at timestamptz not null default now()
);
alter table public.account_flags enable row level security;
revoke all on public.account_flags from anon, authenticated;

create or replace function public.flag_set(p_username text, p_flag text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id into v from public.profiles where username = public.name_resolve(p_username);
  if v is null then raise exception 'Compte introuvable'; end if;
  if v = auth.uid() then raise exception 'Vous ne pouvez pas vous flagger vous-même'; end if;
  if p_flag is null or p_flag = '' then
    delete from public.account_flags where user_id = v;
  else
    if p_flag not in ('suspect','dangereux','faux','avert1','avert2','avert3') then raise exception 'Drapeau inconnu'; end if;
    insert into public.account_flags(user_id, flag, set_by) values (v, p_flag, auth.uid())
      on conflict (user_id) do update set flag = excluded.flag, set_by = excluded.set_by, set_at = now();
  end if;
end $$;

create or replace function public.flag_of(p_username text) returns text language plpgsql security definer stable set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then return null; end if;
  select id into v from public.profiles where username = public.name_resolve(p_username);
  if v is null or v = auth.uid() then return null; end if;
  return (select flag from public.account_flags where user_id = v);
end $$;
revoke all on function public.flag_set(text, text), public.flag_of(text) from public, anon;
grant execute on function public.flag_set(text, text), public.flag_of(text) to authenticated;

-- 4) Afficher / masquer sa liste d'anciens noms
create table if not exists public.name_prefs (user_id uuid primary key references public.profiles(id) on delete cascade, show_old boolean not null default true);
alter table public.name_prefs enable row level security;
revoke all on public.name_prefs from anon, authenticated;
create or replace function public.old_names_pref(p_set boolean default null) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_set is not null then
    insert into public.name_prefs(user_id, show_old) values (auth.uid(), p_set) on conflict (user_id) do update set show_old = excluded.show_old;
  end if;
  return coalesce((select show_old from public.name_prefs where user_id = auth.uid()), true);
end $$;
revoke all on function public.old_names_pref(boolean) from public, anon;
grant execute on function public.old_names_pref(boolean) to authenticated;

create or replace function public.username_history_of(p_username text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid; cur text; sh boolean;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  cur := public.name_resolve(p_username);
  select id into v from public.profiles where username = cur;
  if v is null then return '[]'::jsonb; end if;
  sh := coalesce((select show_old from public.name_prefs where user_id = v), true);
  if not sh and v <> auth.uid() then
    return jsonb_build_array(jsonb_build_object('name', cur, 'at', null, 'current', true));
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', n, 'at', at, 'current', cu) order by cu desc, at desc) from (
      select cur as n, null::timestamptz as at, true as cu
      union all select h.name, h.changed_at, false from public.username_history h where h.user_id = v and not h.hidden) q), '[]'::jsonb);
end $$;

-- 5) SEC-002 : le droit edit_profile est réellement vérifié (current_user vaut le propriétaire dans une fonction SECURITY DEFINER)
create or replace function public.trg_rt_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() = new.id and (new.nickname is distinct from old.nickname or new.avatar_url is distinct from old.avatar_url or new.bio is distinct from old.bio) then
    perform public._need_right(new.id, 'edit_profile');
  end if;
  return new;
end $$;
