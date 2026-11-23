-- Communicer! — patch droits retirables + signalements (additif). Dépend de patch_bans.sql.
alter table public.conversations add column if not exists num bigint generated always as identity;
create table if not exists public.user_rights_off (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  right_key text not null, conversation_id uuid references public.conversations(id) on delete cascade,
  reason text not null, by_id uuid references public.profiles(id) on delete set null, by_name text,
  until timestamptz, at timestamptz not null default now()
);
create unique index if not exists rights_off_uq on public.user_rights_off (user_id, right_key, coalesce(conversation_id, '00000000-0000-0000-0000-000000000000'::uuid));
alter table public.user_rights_off enable row level security;
revoke all on public.user_rights_off from anon, authenticated;

create or replace function public.right_keys() returns text[] language sql immutable as $$
  select array['play','call','edit_conv','upload_files','become_admin','bot_cmds','create_bot','create_groups','friend_requests','edit_profile','quests','shop_buy','referral','rmn_import','buy_tokens','send_messages','start_game','import_game','customize_group','add_members','transfer','promo_codes','mention','export','tournaments','esport','anon_suggest','vote']
$$;

create or replace function public.right_ok(p_user uuid, p_right text, p_conv uuid default null) returns boolean language sql security definer stable set search_path = public as $$
  select public.staff_rank_of(p_user) >= 3 or not exists(
    select 1 from public.user_rights_off o where o.user_id = p_user and o.right_key = p_right
      and (o.conversation_id is null or o.conversation_id = p_conv) and (o.until is null or o.until > now()))
$$;
create or replace function public._need_right(p_user uuid, p_right text, p_conv uuid default null) returns void language plpgsql security definer stable set search_path = public as $$
begin if p_user is not null and not public.right_ok(p_user, p_right, p_conv) then raise exception 'Ce droit vous a été retiré (%)', p_right; end if; end $$;
revoke all on function public._need_right(uuid, text, uuid) from public, anon, authenticated;

-- ---------- application côté serveur, quel que soit le client ----------
create or replace function public.trg_rt_messages() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sender_id is null or new.sender_id is distinct from auth.uid() or new.kind = 'system' then return new; end if;
  perform public._need_right(new.sender_id, 'send_messages', new.conversation_id);
  if new.kind in ('image','voice','drawing') or new.media_path is not null then perform public._need_right(new.sender_id, 'upload_files', new.conversation_id); end if;
  if new.kind = 'text' and new.body ~ '(^|[^A-Za-z0-9_])@[a-z0-9_]{3,20}' then perform public._need_right(new.sender_id, 'mention', new.conversation_id); end if;
  return new;
end $$;
drop trigger if exists rt_messages on public.messages;
create trigger rt_messages before insert on public.messages for each row execute function public.trg_rt_messages();

create or replace function public.trg_rt_conv() returns trigger language plpgsql security definer set search_path = public as $$
begin if new.kind = 'group' then perform public._need_right(auth.uid(), 'create_groups'); end if; return new; end $$;
drop trigger if exists rt_conv on public.conversations;
create trigger rt_conv before insert on public.conversations for each row execute function public.trg_rt_conv();

create or replace function public.trg_rt_friend() returns trigger language plpgsql security definer set search_path = public as $$
begin if new.requester = auth.uid() then perform public._need_right(new.requester, 'friend_requests'); end if; return new; end $$;
drop trigger if exists rt_friend on public.friendships;
create trigger rt_friend before insert on public.friendships for each row execute function public.trg_rt_friend();

create or replace function public.trg_rt_member() returns trigger language plpgsql security definer set search_path = public as $$
begin if auth.uid() is not null and new.user_id <> auth.uid() then perform public._need_right(auth.uid(), 'add_members', new.conversation_id); end if; return new; end $$;
drop trigger if exists rt_member on public.conversation_members;
create trigger rt_member before insert on public.conversation_members for each row execute function public.trg_rt_member();

create or replace function public.trg_rt_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_user in ('authenticated') and auth.uid() = new.id and (new.nickname is distinct from old.nickname or new.avatar_url is distinct from old.avatar_url or new.bio is distinct from old.bio) then
    perform public._need_right(new.id, 'edit_profile');
  end if;
  return new;
end $$;
drop trigger if exists rt_profile on public.profiles;
create trigger rt_profile before update on public.profiles for each row execute function public.trg_rt_profile();

create or replace function public.trg_rt_live() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.host = auth.uid() then perform public._need_right(new.host, case when new.kind = 'call' then 'call' else 'start_game' end, new.conversation_id); end if;
  return new;
end $$;
drop trigger if exists rt_live on public.live_sessions;
create trigger rt_live before insert on public.live_sessions for each row execute function public.trg_rt_live();

do $$ begin
  if to_regclass('public.bots') is not null then
    create or replace function public.trg_rt_bot() returns trigger language plpgsql security definer set search_path = public as $f$
    begin if new.owner_id = auth.uid() and not coalesce(new.official, false) then perform public._need_right(new.owner_id, 'create_bot'); end if; return new; end $f$;
    drop trigger if exists rt_bot on public.bots;
    create trigger rt_bot before insert on public.bots for each row execute function public.trg_rt_bot();
  end if;
  if to_regclass('public.inventory') is not null then
    create or replace function public.trg_rt_buy() returns trigger language plpgsql security definer set search_path = public as $f$
    begin if new.user_id = auth.uid() then perform public._need_right(new.user_id, 'shop_buy'); end if; return new; end $f$;
    drop trigger if exists rt_buy on public.inventory; create trigger rt_buy before insert on public.inventory for each row execute function public.trg_rt_buy();
  end if;
  if to_regclass('public.user_badges') is not null then
    drop trigger if exists rt_buy on public.user_badges; create trigger rt_buy before insert on public.user_badges for each row execute function public.trg_rt_buy();
  end if;
  if to_regclass('public.orders') is not null then
    create or replace function public.trg_rt_order() returns trigger language plpgsql security definer set search_path = public as $f$
    begin if new.user_id = auth.uid() then perform public._need_right(new.user_id, 'buy_tokens'); end if; return new; end $f$;
    drop trigger if exists rt_order on public.orders; create trigger rt_order before insert on public.orders for each row execute function public.trg_rt_order();
  end if;
end $$;

-- ---------- retrait / rétablissement ----------
create or replace function public.right_set(p_username text, p_right text, p_conv_num bigint, p_allowed boolean, p_reason text, p_secs numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid; nm text; c uuid; me int := public.staff_rank_me(); adm boolean := false; tr int; mn text := (select username from public.profiles where id = auth.uid());
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not (p_right = any(public.right_keys())) then raise exception 'Droit inconnu'; end if;
  select id, username into v, nm from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  if v = auth.uid() then raise exception 'Action impossible sur soi-même'; end if;
  tr := public.staff_rank_of(v);
  if p_conv_num is not null then
    select id into c from public.conversations where num = p_conv_num;
    if c is null then raise exception 'Conversation introuvable'; end if;
    adm := exists(select 1 from public.conversation_members where conversation_id = c and user_id = auth.uid() and role = 'admin');
  end if;
  if not (me >= 3 or (adm and p_conv_num is not null)) then raise exception 'Réservé au chef des administrateurs (ou à l’administrateur du groupe, dans son groupe)'; end if;
  if me >= 3 and tr >= me then raise exception 'Vous ne pouvez pas agir sur un rang égal ou supérieur au vôtre'; end if;
  if me < 3 and (tr >= 2 or exists(select 1 from public.conversation_members where conversation_id = c and user_id = v and role = 'admin')) then raise exception 'Cette personne ne peut pas être restreinte par vous'; end if;
  if p_allowed then
    delete from public.user_rights_off where user_id = v and right_key = p_right and conversation_id is not distinct from c;
  else
    if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
    insert into public.user_rights_off(user_id, right_key, conversation_id, reason, by_id, by_name, until)
      values (v, p_right, c, left(p_reason, 300), auth.uid(), mn, case when p_secs is not null and p_secs > 0 then now() + make_interval(secs => p_secs::double precision) end)
      on conflict (user_id, right_key, coalesce(conversation_id, '00000000-0000-0000-0000-000000000000'::uuid))
      do update set reason = excluded.reason, by_id = excluded.by_id, by_name = excluded.by_name, until = excluded.until, at = now();
    insert into public.casier(user_id, kind, reason, message, by_id, by_name) values (v, 'rights', left(p_reason, 300), 'Droit retiré : ' || p_right || case when c is not null then ' (une conversation)' else ' (tout le site)' end, auth.uid(), mn);
  end if;
  perform public.log_admin(case when p_allowed then 'droit_retabli' else 'droit_retire' end, nm, jsonb_build_object('right', p_right, 'conv', p_conv_num, 'reason', p_reason));
end $$;

create or replace function public.rights_list(p_username text, p_conv_num bigint default null) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid; c uuid;
begin
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  if p_conv_num is not null then select id into c from public.conversations where num = p_conv_num; end if;
  if not (public.staff_rank_me() >= 3 or (c is not null and exists(select 1 from public.conversation_members where conversation_id = c and user_id = auth.uid() and role = 'admin'))) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('right', o.right_key, 'conv', cv.num, 'reason', o.reason, 'by', o.by_name, 'until', o.until, 'at', o.at) order by o.id desc)
    from public.user_rights_off o left join public.conversations cv on cv.id = o.conversation_id
    where o.user_id = v and (o.until is null or o.until > now()) and (p_conv_num is null or cv.num = p_conv_num)), '[]'::jsonb);
end $$;

create or replace function public.rights_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('right', o.right_key, 'conv', cv.num)), '[]'::jsonb)
  from public.user_rights_off o left join public.conversations cv on cv.id = o.conversation_id
  where o.user_id = auth.uid() and (o.until is null or o.until > now()) and public.staff_rank_me() < 3
$$;

-- liste des conversations (nom, numéro, type) pour l'administration ; jamais les messages
create or replace function public.conv_list(p_q text default null) returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('num', c.num, 'kind', c.kind, 'mode', c.mode,
      'name', coalesce(c.name, (select string_agg('@' || p.username, ', ' order by p.username) from public.conversation_members m join public.profiles p on p.id = m.user_id where m.conversation_id = c.id)),
      'members', (select count(*) from public.conversation_members m where m.conversation_id = c.id)) x
    from public.conversations c
    where p_q is null or p_q = '' or c.name ilike '%' || p_q || '%' or c.num::text = regexp_replace(p_q, '\D', '', 'g')
       or exists(select 1 from public.conversation_members m join public.profiles p on p.id = m.user_id where m.conversation_id = c.id and p.username ilike '%' || regexp_replace(p_q, '^@', '') || '%')
    order by c.num desc limit 60) s), '[]'::jsonb);
end $$;

-- ---------- signalements ----------
create table if not exists public.reports (
  id bigint generated always as identity primary key, ref text unique,
  kind text not null check (kind in ('group','message')),
  reporter_id uuid references public.profiles(id) on delete set null, reporter_name text,
  conversation_id uuid references public.conversations(id) on delete set null, conv_num bigint, conv_name text,
  target_name text, reason text not null, snapshot jsonb not null default '[]'::jsonb,
  status text not null default 'open' check (status in ('open','closed')), note text,
  handled_by text, created_at timestamptz not null default now(), closed_at timestamptz
);
create or replace function public.trg_report_ref() returns trigger language plpgsql as $$ begin new.ref := 'S-' || lpad(new.id::text, 6, '0'); return new; end $$;
drop trigger if exists report_ref on public.reports;
create trigger report_ref before insert on public.reports for each row execute function public.trg_report_ref();
alter table public.reports enable row level security;
revoke all on public.reports from anon, authenticated;

create or replace function public.report_create(p_conv uuid, p_kind text, p_target text, p_reason text, p_snapshot jsonb default '[]'::jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare r public.reports; c record;
begin
  if auth.uid() is null or not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  perform public.rate_ok('report:' || auth.uid()::text, 10, 3600);
  if p_kind not in ('group','message') then raise exception 'Type invalide'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Expliquez la raison (5 caractères minimum)'; end if;
  if jsonb_typeof(p_snapshot) <> 'array' or jsonb_array_length(p_snapshot) > 50 or length(p_snapshot::text) > 60000 then raise exception 'Sélection trop longue'; end if;
  select num, coalesce(name, 'Discussion') as nm into c from public.conversations where id = p_conv;
  insert into public.reports(kind, reporter_id, reporter_name, conversation_id, conv_num, conv_name, target_name, reason, snapshot)
    values (p_kind, auth.uid(), (select username from public.profiles where id = auth.uid()), p_conv, c.num, c.nm, nullif(trim(coalesce(p_target,'')), ''), left(p_reason, 1000), p_snapshot) returning * into r;
  return r.ref;
end $$;

create or replace function public.report_list(p_status text default 'open') returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('ref', ref, 'kind', kind, 'by', reporter_name, 'conv', conv_num, 'conv_name', conv_name, 'target', target_name,
     'reason', reason, 'snapshot', snapshot, 'status', status, 'note', note, 'handled_by', handled_by, 'at', created_at) order by id desc)
     from (select * from public.reports where status = p_status order by id desc limit 100) r), '[]'::jsonb);
end $$;

-- lecture de la conversation signalée (mode clair seulement ; consignée)
create or replace function public.report_conv_view(p_ref text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.reports; m text;
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  select * into r from public.reports where ref = p_ref;
  if not found or r.conversation_id is null then raise exception 'Signalement introuvable'; end if;
  select mode into m from public.conversations where id = r.conversation_id;
  if m = 'e2e' then raise exception 'Conversation chiffrée de bout en bout : seule la sélection du signalement est lisible'; end if;
  perform public.log_admin('signalement_lecture', p_ref, jsonb_build_object('conv', r.conv_num));
  return coalesce((select jsonb_agg(jsonb_build_object('n', q.id, 'from', coalesce(p.username, '(supprimé)'), 'kind', q.kind, 'body', case when q.kind = 'text' then q.body end, 'at', q.created_at) order by q.id)
    from (select * from public.messages where conversation_id = r.conversation_id and whisper_to is null order by id desc limit 200) q left join public.profiles p on p.id = q.sender_id), '[]'::jsonb);
end $$;

create or replace function public.report_action(p_ref text, p_action text, p_target text default null, p_secs numeric default null, p_msgs bigint[] default null) returns text
language plpgsql security definer set search_path = public as $$
declare r public.reports; v uuid; n int := 0; mn text := (select username from public.profiles where id = auth.uid());
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  select * into r from public.reports where ref = p_ref;
  if not found or r.conversation_id is null then raise exception 'Signalement introuvable'; end if;
  if p_target is not null then select id into v from public.profiles where username = lower(regexp_replace(trim(p_target), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
    if public.staff_rank_of(v) >= public.staff_rank_me() then raise exception 'Cible protégée'; end if; end if;
  if p_action = 'kick' then
    if v is null then raise exception 'Indiquez la personne'; end if;
    insert into public.conversation_bans(conversation_id, user_id, by_id, seconds, until) values (r.conversation_id, v, auth.uid(), coalesce(p_secs, 0), case when coalesce(p_secs, 0) > 0 then now() + make_interval(secs => p_secs::double precision) end);
    delete from public.conversation_members where conversation_id = r.conversation_id and user_id = v;
  elsif p_action = 'demote' then
    if v is null then raise exception 'Indiquez la personne'; end if;
    update public.conversation_members set role = 'member' where conversation_id = r.conversation_id and user_id = v;
  elsif p_action = 'purge_user' then
    if v is null then raise exception 'Indiquez la personne'; end if;
    delete from public.messages where conversation_id = r.conversation_id and sender_id = v; get diagnostics n = row_count;
  elsif p_action = 'delete_msgs' then
    delete from public.messages where conversation_id = r.conversation_id and id = any(coalesce(p_msgs, '{}')); get diagnostics n = row_count;
  elsif p_action = 'mute' then
    if v is null then raise exception 'Indiquez la personne'; end if;
    insert into public.user_rights_off(user_id, right_key, conversation_id, reason, by_id, by_name, until)
      values (v, 'send_messages', r.conversation_id, 'Signalement ' || p_ref, auth.uid(), mn, case when coalesce(p_secs, 0) > 0 then now() + make_interval(secs => p_secs::double precision) end)
      on conflict (user_id, right_key, coalesce(conversation_id, '00000000-0000-0000-0000-000000000000'::uuid)) do update set until = excluded.until, at = now();
  elsif p_action = 'remove_bots' then
    if to_regclass('public.conversation_bots') is not null then delete from public.conversation_bots where conversation_id = r.conversation_id; get diagnostics n = row_count; end if;
  else raise exception 'Action inconnue'; end if;
  perform public.log_admin('signalement_' || p_action, p_ref, jsonb_build_object('target', p_target, 'n', n));
  return n::text;
end $$;

create or replace function public.report_close(p_ref text, p_note text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  update public.reports set status = 'closed', note = left(coalesce(p_note, ''), 500), handled_by = (select username from public.profiles where id = auth.uid()), closed_at = now() where ref = p_ref and status = 'open';
  perform public.log_admin('signalement_clos', p_ref, jsonb_build_object('note', p_note));
end $$;

do $$ declare f text; begin foreach f in array array['right_ok(uuid,text,uuid)','right_set(text,text,bigint,boolean,text,numeric)','rights_list(text,bigint)','rights_mine()','conv_list(text)','report_create(uuid,text,text,text,jsonb)','report_list(text)','report_conv_view(text)','report_action(text,text,text,numeric,bigint[])','report_close(text,text)'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
