-- Lot 24 : phase des sessions, messages vidéo/GIF, cadres payants, groupe Administration, premier changement de nom gratuit,
-- comptes bidon/classe/biome, badges, panneau caché, protection contre les abus — additif

-- ---------- 1) sessions : phase (attente / en cours) et participants d'un appel ----------
alter table public.live_sessions add column if not exists phase text not null default 'wait';
create or replace function public.live_phase(p_session text, p_phase text) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_phase not in ('wait', 'live') then raise exception 'Phase invalide'; end if;
  update public.live_sessions set phase = p_phase
   where session_id = p_session and ended_at is null
     and exists(select 1 from public.live_members m where m.session_id = p_session and m.user_id = auth.uid() and not m.spec);
end $$;
revoke all on function public.live_phase(text, text) from public, anon;
grant execute on function public.live_phase(text, text) to authenticated;
create or replace function public.live_list(p_conv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  perform public.live_sweep();
  return coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'session', l.session_id, 'game', l.game, 'host', l.host,
      'host_name', (select username from public.profiles where id = l.host), 'started_at', l.started_at, 'phase', l.phase,
      'members', (select count(*) from public.live_members m where m.session_id = l.session_id and not m.spec),
      'users', coalesce((select jsonb_agg(m.user_id order by m.joined_at) from public.live_members m where m.session_id = l.session_id and not m.spec), '[]'::jsonb)) order by l.kind)
    from public.live_sessions l where l.conversation_id = p_conv and l.ended_at is null), '[]'::jsonb);
end $$;
grant execute on function public.live_list(uuid) to authenticated;
revoke execute on function public.live_list(uuid) from anon, public;

-- ---------- 2) messages : GIF et vidéos (compression automatique) ----------
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check check (kind in ('text','image','voice','drawing','system','game','video'));
create or replace function public.send_message(
  p_conv uuid, p_kind text, p_body text, p_media text default null, p_ttl int default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_row public.messages;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Vous ne faites pas partie de cette conversation'; end if;
  if p_kind not in ('text','image','voice','drawing','game','video') then raise exception 'Type de message invalide'; end if;
  if p_ttl is not null and (p_ttl < 1 or p_ttl > 86400) then raise exception 'Durée invalide (1 s à 24 h)'; end if;
  insert into public.messages (conversation_id, sender_id, kind, body, media_path, expires_at)
  values (p_conv, v_me, p_kind, p_body, p_media, case when p_ttl is null then null else now() + make_interval(secs => p_ttl) end)
  returning * into v_row;
  return v_row;
end $$;
revoke all on function public.send_message(uuid, text, text, text, int) from public, anon;
grant execute on function public.send_message(uuid, text, text, text, int) to authenticated;

-- ---------- 3) cadres payants : un cadre avec un prix ne s'obtient qu'en l'achetant ----------
create or replace function public._frame_ok(p_user uuid, p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.frame_defs f where f.code = p_code and (
      (f.price is null and f.audience = 'all')
      or exists(select 1 from public.frame_grants g where g.frame_code = f.code and g.user_id = p_user)
      or f.seller = p_user
      or (f.price is null and exists(select 1 from public.inventory i where i.user_id = p_user and i.code = 'frame_' || f.cat))))
$$;
revoke all on function public._frame_ok(uuid, text) from public, anon, authenticated;
create or replace function public.frames_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(f.code), '[]'::jsonb) from public.frame_defs f
  where auth.uid() is not null and ((f.price is null and f.audience = 'all') or f.seller = auth.uid()
        or exists(select 1 from public.frame_grants g where g.frame_code = f.code and g.user_id = auth.uid()))
$$;
-- rattrapage : cadres payants portés sans avoir été achetés
update public.profile_ext e set photo_frame = null where e.photo_frame is not null and exists(select 1 from public.frame_defs f where f.code = e.photo_frame and f.price is not null) and not public._frame_ok(e.user_id, e.photo_frame);
update public.profile_ext e set profile_frame = null where e.profile_frame is not null and exists(select 1 from public.frame_defs f where f.code = e.profile_frame and f.price is not null) and not public._frame_ok(e.user_id, e.profile_frame);

-- ---------- 4) groupe Administration : @system et @staff y restent ----------
create or replace function public.staff_group_sync() returns void language plpgsql security definer set search_path = public as $$
declare g uuid; r record; owner uuid; off uuid[] := array['aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002']::uuid[]; o uuid;
begin
  select conversation_id into g from public.staff_group where id = 1;
  if g is null or not exists(select 1 from public.conversations where id = g) then
    select user_id into owner from public.site_staff where role = 'commander' limit 1;
    if owner is null then select user_id into owner from public.site_staff order by rank_at limit 1; end if;
    if owner is null then return; end if;
    insert into public.conversations(kind, mode, name, created_by) values ('group', 'clear', 'Administration', owner) returning id into g;
    insert into public.staff_group(id, conversation_id) values (1, g) on conflict (id) do update set conversation_id = excluded.conversation_id;
  end if;
  for r in select user_id, role from public.site_staff loop
    insert into public.conversation_members(conversation_id, user_id, role) values (g, r.user_id, case when public.staff_rank(r.role) >= 3 then 'admin' else 'member' end)
    on conflict (conversation_id, user_id) do update set role = excluded.role;
  end loop;
  foreach o in array off loop
    if exists(select 1 from public.profiles where id = o) then
      insert into public.conversation_members(conversation_id, user_id, role) values (g, o, 'admin') on conflict (conversation_id, user_id) do update set role = 'admin';
    end if;
  end loop;
  delete from public.conversation_members where conversation_id = g and user_id not in (select user_id from public.site_staff) and user_id <> all(off);
end $$;
revoke all on function public.staff_group_sync() from public, anon, authenticated;
create or replace function public.trg_staff_leave() returns trigger language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select conversation_id into g from public.staff_group where id = 1;
  if g is not null and old.user_id <> all(array['aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002']::uuid[]) then delete from public.conversation_members where conversation_id = g and user_id = old.user_id; end if;
  return old;
end $$;
do $$ begin perform public.staff_group_sync(); exception when others then raise notice 'staff_group_sync : %', sqlerrm; end $$;

-- ---------- 5) le premier changement de nom d'utilisateur est gratuit ----------
create or replace function public.rename_me(p_new text)
returns text language plpgsql security definer set search_path = public as $$
declare n text := lower(trim(coalesce(p_new,''))); old text; free boolean := false; e public.profile_ext;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if n !~ '^[a-z0-9_]{3,20}$' then raise exception 'Nom invalide (3 à 20 caractères : lettres, chiffres, _)'; end if;
  if n = (select username from public.profiles where id = auth.uid()) then raise exception 'C’est déjà votre nom'; end if;
  case public.name_available(n) when 'taken' then raise exception 'Ce nom est déjà pris ou réservé'; when 'forbidden' then raise exception 'Ce nom d’utilisateur n’est pas autorisé'; when 'ok' then null; else raise exception 'Nom invalide'; end case;
  insert into public.profile_ext(user_id) values (auth.uid()) on conflict do nothing;
  select * into e from public.profile_ext where user_id = auth.uid() for update;
  if e.last_rename is null and not exists(select 1 from public.token_log where user_id = auth.uid() and reason like 'nom changé :%') then free := true; end if;   -- premier changement : gratuit
  if not free and public.has_cplus() and (e.last_rename is null or e.last_rename < now() - interval '30 days') then free := true; end if;
  if not free then
    update public.profile_ext set rename_credits = rename_credits - 1 where user_id = auth.uid() and rename_credits > 0;
    if not found then raise exception 'Achetez d’abord un changement de nom (le premier est gratuit ; Customize+ : un par 30 jours)'; end if;
  end if;
  update public.profile_ext set last_rename = now() where user_id = auth.uid();
  select username into old from public.profiles where id = auth.uid();
  update public.profiles set username = n where id = auth.uid();
  insert into public.token_log(user_id, delta, reason) values (auth.uid(), 0, 'nom changé : ' || old || ' vers ' || n);
  return n;
end $$;
revoke all on function public.rename_me(text) from public, anon; grant execute on function public.rename_me(text) to authenticated;
create or replace function public.rename_free() returns boolean language sql security definer stable set search_path = public as $$
  select auth.uid() is not null and not exists(select 1 from public.token_log where user_id = auth.uid() and reason like 'nom changé :%')
         and coalesce((select last_rename is null from public.profile_ext where user_id = auth.uid()), true)
$$;
revoke all on function public.rename_free() from public, anon; grant execute on function public.rename_free() to authenticated;

-- ---------- 6) temps passé sur le site ----------
create table if not exists public.site_time (user_id uuid primary key references public.profiles(id) on delete cascade, seconds bigint not null default 0, updated_at timestamptz not null default now());
alter table public.site_time enable row level security; revoke all on public.site_time from anon, authenticated;
create or replace function public.time_beat() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.site_time(user_id, seconds) values (auth.uid(), 60)
  on conflict (user_id) do update set seconds = public.site_time.seconds + case when public.site_time.updated_at > now() - interval '50 seconds' then 0 else 60 end,
    updated_at = case when public.site_time.updated_at > now() - interval '50 seconds' then public.site_time.updated_at else now() end;
end $$;
revoke all on function public.time_beat() from public, anon; grant execute on function public.time_beat() to authenticated;

-- ---------- 7) comptes bidon / classe / biome (visibles seulement par le personnel avec le panneau) ----------
create or replace function public._acct_points(p_user uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare bad numeric := 0; good numeric := 0; u record; hrs numeric := 0; d jsonb := '[]'::jsonb; cl text;
begin
  if exists(select 1 from public.casier where user_id = p_user and kind in ('ban_temp','ban_perm','ban_erase')) then bad := bad + 6; d := d || '"Déjà banni (+6)"'::jsonb; end if;
  if exists(select 1 from public.account_flags where user_id = p_user) then bad := bad + 4; d := d || '"Flaggé (+4)"'::jsonb; end if;
  select email_confirmed_at, phone_confirmed_at into u from auth.users where id = p_user;
  if u.email_confirmed_at is not null or u.phone_confirmed_at is not null
     or exists(select 1 from public.contact_emails where user_id = p_user and verified_at is not null)
     or exists(select 1 from public.contact_phones where user_id = p_user and verified_at is not null) then good := good + 1; d := d || '"Courriel ou téléphone vérifié (+1)"'::jsonb; end if;
  if exists(select 1 from auth.mfa_factors where user_id = p_user and status = 'verified') then good := good + 1; d := d || '"Authentification à deux facteurs (+1)"'::jsonb; end if;
  select coalesce(seconds, 0) / 3600.0 into hrs from public.site_time where user_id = p_user;
  if coalesce(hrs, 0) >= 1900 then good := good + 2; d := d || '"1 900 heures sur le site (+2)"'::jsonb; end if;
  if (select created_at from public.profiles where id = p_user) < now() - interval '60 days' then good := good + 2; d := d || '"Compte de plus de 60 jours (+2)"'::jsonb; end if;
  if not exists(select 1 from public.legal_versions v where not exists(select 1 from public.legal_acceptances a where a.user_id = p_user and a.version >= v.version)
                  and v.published_at > (select created_at from public.profiles where id = p_user)) then good := good + 0.2; d := d || '"Politique de confidentialité acceptée (+0,2)"'::jsonb; end if;
  cl := case when abs(good - bad) < 1 then 'biome' when bad > good then 'bidon' else 'classe' end;
  return jsonb_build_object('class', cl, 'bad', bad, 'good', good, 'details', d);
end $$;
revoke all on function public._acct_points(uuid) from public, anon, authenticated;

-- ---------- 8) badges : testeur, premier testeur, bugger ----------
insert into public.badge_defs(code, name, descr, tier, sort) values
 ('testeur', 'Testeur', 'Avoir lancé une version ALPHA de l’application Android (compte de plus de 60 jours).', 'special', 900),
 ('premier_testeur', 'Premier testeur', 'Avoir lancé une version BETA de l’application Android (réservée aux administrateurs).', 'special', 901),
 ('bugger', 'Bugger', 'Avoir installé une application dont la version n’existe pas dans la liste officielle.', 'special', 902)
on conflict (code) do nothing;
create or replace function public.badge_catalog() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tot int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select greatest(count(*), 1) into tot from public.profiles;
  return coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier,
      'owned', exists(select 1 from public.user_badges b where b.user_id = auth.uid() and b.code = d.code),
      'pct', round(100.0 * (select count(*) from public.user_badges b where b.code = d.code) / tot, 2)) order by d.sort, d.name) from public.badge_defs d), '[]'::jsonb);
end $$;
revoke all on function public.badge_catalog() from public, anon; grant execute on function public.badge_catalog() to authenticated;

-- version de l'application Android : accès aux versions ALPHA / BETA et badges
create or replace function public.app_version_report(p_version text, p_known boolean default true) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v text := left(coalesce(p_version, ''), 40);
begin
  if me is null then raise exception 'Non connecté'; end if;
  if v !~ '^v[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(-(ALPHA|BETA))?$' then
    perform public.badge_grant(me, 'bugger'); return jsonb_build_object('ok', true, 'bugger', true);
  end if;
  if coalesce(p_known, true) = false then perform public.badge_grant(me, 'bugger'); end if;
  if v like '%-BETA' then
    if public.staff_rank_of(me) < 1 then return jsonb_build_object('ok', false, 'reason', 'Version BETA réservée aux administrateurs'); end if;
    perform public.badge_grant(me, 'premier_testeur');
  elsif v like '%-ALPHA' then
    if (select created_at from public.profiles where id = me) > now() - interval '60 days' then return jsonb_build_object('ok', false, 'reason', 'Version ALPHA réservée aux comptes de plus de 60 jours'); end if;
    perform public.badge_grant(me, 'testeur');
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.app_version_report(text, boolean) from public, anon; grant execute on function public.app_version_report(text, boolean) to authenticated;

-- ---------- 9) panneau caché ----------
create table if not exists public.panel_cfg (id int primary key default 1 check (id = 1), seq text[] not null default array['D','D','D','L','L','U','D','D','L','U'], pin_hash text, updated_at timestamptz not null default now(), updated_by uuid);
insert into public.panel_cfg(id) values (1) on conflict do nothing;
create table if not exists public.panel_users (user_id uuid primary key references public.profiles(id) on delete cascade, seq_at timestamptz, pin_fail int not null default 0,
  unlocked boolean not null default false, unlocked_at timestamptz, banned boolean not null default false, revoked boolean not null default false, vanish boolean not null default false);
create table if not exists public.panel_log (id bigint generated always as identity primary key, at timestamptz not null default now(), user_id uuid, action text not null, detail jsonb);
create table if not exists public.ui_layout (sel text primary key check (sel ~ '^(#[A-Za-z][A-Za-z0-9_-]{0,40}|\.[A-Za-z][A-Za-z0-9_-]{0,40}|\[data-(mid|id|k)="[A-Za-z0-9_-]{1,40}"\])$'),
  dx int not null check (dx between -3000 and 3000), dy int not null check (dy between -3000 and 3000), by_id uuid, at timestamptz not null default now());
alter table public.panel_cfg enable row level security; alter table public.panel_users enable row level security; alter table public.panel_log enable row level security; alter table public.ui_layout enable row level security;
revoke all on public.panel_cfg, public.panel_users, public.panel_log, public.ui_layout from anon, authenticated;

create or replace function public._panel_ok(p_user uuid default auth.uid()) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select u.unlocked and not u.banned and (not u.revoked or public.staff_rank_of(p_user) >= 2) from public.panel_users u where u.user_id = p_user), false)
$$;
revoke all on function public._panel_ok(uuid) from public, anon, authenticated;
create or replace function public._panel_need(p_rank int) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public._panel_ok(auth.uid()) then raise exception 'Panneau non débloqué'; end if;
  if public.staff_rank_of(auth.uid()) < p_rank then raise exception 'Rang insuffisant'; end if;
end $$;
revoke all on function public._panel_need(int) from public, anon, authenticated;
create or replace function public._panel_log(p_action text, p_detail jsonb default '{}'::jsonb) returns void language sql security definer set search_path = public as $$
  insert into public.panel_log(user_id, action, detail) values (auth.uid(), p_action, p_detail)
$$;
revoke all on function public._panel_log(text, jsonb) from public, anon, authenticated;

create or replace function public.panel_state() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.panel_users; c public.panel_cfg;
begin
  if auth.uid() is null then return jsonb_build_object('unlocked', false); end if;
  select * into u from public.panel_users where user_id = auth.uid(); select * into c from public.panel_cfg where id = 1;
  return jsonb_build_object('unlocked', coalesce(u.unlocked, false) and not coalesce(u.banned, false) and (not coalesce(u.revoked, false) or public.staff_rank_me() >= 2),
    'banned', coalesce(u.banned, false), 'rank', public.staff_rank_me(), 'len', array_length(c.seq, 1), 'vanish', coalesce(u.vanish, false));
end $$;
-- étape 1 : le code de flèches est vérifié par le serveur (jamais envoyé aux clients)
create or replace function public.panel_seq(p_seq text) returns boolean language plpgsql security definer set search_path = public as $$
declare c public.panel_cfg; s text; u public.panel_users;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('panel_seq', 120, 3600);
  select * into u from public.panel_users where user_id = auth.uid();
  if found and u.banned then return false; end if;
  select * into c from public.panel_cfg where id = 1; s := array_to_string(c.seq, '');
  if p_seq is null or p_seq !~ '^[UDLR]{1,64}$' or right(p_seq, length(s)) <> s then return false; end if;
  insert into public.panel_users(user_id, seq_at) values (auth.uid(), now()) on conflict (user_id) do update set seq_at = now();
  return true;
end $$;
-- étape 2 : NIP de 8 lettres, 3 essais au maximum, puis bannissement du panneau
create or replace function public.panel_pin(p_pin text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u public.panel_users; c public.panel_cfg; okp boolean;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into u from public.panel_users where user_id = auth.uid() for update;
  if not found or u.seq_at is null or u.seq_at < now() - interval '5 minutes' then return jsonb_build_object('ok', false, 'left', null, 'why', 'seq'); end if;
  if u.banned then return jsonb_build_object('ok', false, 'banned', true); end if;
  select * into c from public.panel_cfg where id = 1;
  okp := c.pin_hash is not null and p_pin ~ '^[A-Za-z]{8}$' and c.pin_hash = extensions.crypt(lower(p_pin), c.pin_hash);
  if okp then
    update public.panel_users set unlocked = true, unlocked_at = coalesce(unlocked_at, now()), pin_fail = 0, seq_at = null, revoked = false where user_id = auth.uid();
    perform public._panel_log('unlock', '{}'::jsonb);
    return jsonb_build_object('ok', true);
  end if;
  update public.panel_users set pin_fail = pin_fail + 1, seq_at = null,
      banned = (pin_fail + 1 >= 3 and public.staff_rank_of(auth.uid()) < 4) where user_id = auth.uid() returning * into u;
  perform public._panel_log('pin_fail', jsonb_build_object('n', u.pin_fail));
  return jsonb_build_object('ok', false, 'left', greatest(3 - u.pin_fail, 0), 'banned', u.banned);
end $$;
create or replace function public.panel_cfg_info() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.panel_cfg;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select * into c from public.panel_cfg where id = 1;
  return jsonb_build_object('seq', array_to_string(c.seq, ''), 'pin', c.pin_hash is not null);
end $$;
create or replace function public.panel_cfg_set(p_seq text, p_pin text default null) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_seq is null or p_seq !~ '^[UDLR]{4,24}$' then raise exception 'Code : 4 à 24 flèches (U, D, L, R)'; end if;
  if p_pin is not null and p_pin !~ '^[A-Za-z]{8}$' then raise exception 'Le NIP doit contenir exactement 8 lettres'; end if;
  update public.panel_cfg set seq = string_to_array(p_seq, null), pin_hash = case when p_pin is null then pin_hash else extensions.crypt(lower(p_pin), extensions.gen_salt('bf')) end, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform public._panel_log('cfg_set', jsonb_build_object('pin_changed', p_pin is not null));
end $$;
create or replace function public.panel_users_list() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('username', p.username, 'unlocked', u.unlocked, 'banned', u.banned, 'revoked', u.revoked, 'fails', u.pin_fail, 'rank', public.staff_rank_of(u.user_id), 'at', u.unlocked_at) order by u.unlocked_at desc nulls last)
    from public.panel_users u join public.profiles p on p.id = u.user_id), '[]'::jsonb);
end $$;
create or replace function public.panel_admin(p_username text, p_action text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_action = 'revoke_all' then
    update public.panel_users set unlocked = false, revoked = true where public.staff_rank_of(user_id) < 2;
    perform public._panel_log('revoke_all', '{}'::jsonb); return;
  end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  insert into public.panel_users(user_id) values (v) on conflict do nothing;
  if p_action = 'grant' then update public.panel_users set unlocked = true, revoked = false, banned = false, pin_fail = 0, unlocked_at = coalesce(unlocked_at, now()) where user_id = v;
  elsif p_action = 'revoke' then update public.panel_users set unlocked = false, revoked = true where user_id = v;
  elsif p_action = 'reset' then update public.panel_users set banned = false, pin_fail = 0, revoked = false where user_id = v;
  else raise exception 'Action inconnue'; end if;
  perform public._panel_log('admin_' || p_action, jsonb_build_object('cible', p_username));
end $$;

-- actions serveur du panneau (administrateur et plus)
create or replace function public.panel_sysmsg(p_conv uuid, p_text text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  if char_length(trim(coalesce(p_text,''))) not between 1 and 300 then raise exception 'Message de 1 à 300 caractères'; end if;
  if not exists(select 1 from public.conversations where id = p_conv) then raise exception 'Discussion introuvable'; end if;
  perform public.rate_ok('panel_sys', 30, 3600);
  insert into public.messages(conversation_id, sender_id, kind, body) values (p_conv, auth.uid(), 'system', trim(p_text));
  perform public._panel_log('sysmsg', jsonb_build_object('conv', p_conv));
end $$;
create or replace function public.panel_add(p_conv uuid, p_username text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid; m text;
begin
  perform public._panel_need(2);
  select mode into m from public.conversations where id = p_conv; if m is null then raise exception 'Discussion introuvable'; end if;
  if m = 'e2e' then raise exception 'Discussion chiffrée : la clé ne peut pas être transmise'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
  insert into public.conversation_members(conversation_id, user_id) values (p_conv, v) on conflict do nothing;
  perform public._panel_log('add', jsonb_build_object('conv', p_conv, 'cible', p_username));
end $$;
create or replace function public.panel_rank(p_conv uuid, p_username text, p_admin boolean) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(2);
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
  update public.conversation_members set role = case when p_admin then 'admin' else 'member' end where conversation_id = p_conv and user_id = v;
  if not found then raise exception 'Cette personne n’est pas dans la discussion'; end if;
  perform public._panel_log('rank', jsonb_build_object('conv', p_conv, 'cible', p_username, 'admin', p_admin));
end $$;
create or replace function public.panel_dm(p_username text, p_reason text) returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v uuid; c uuid;
begin
  perform public._panel_need(2);
  if char_length(trim(coalesce(p_reason,''))) < 10 then raise exception 'Motif justifié obligatoire (10 caractères minimum)'; end if;
  perform public.rate_ok('panel_dm', 20, 3600);
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null or v = me then raise exception 'Utilisateur introuvable'; end if;
  select cv.id into c from public.conversations cv where cv.kind = 'direct' and cv.mode = 'clear' and cv.hub is null
    and exists(select 1 from public.conversation_members a where a.conversation_id = cv.id and a.user_id = me)
    and exists(select 1 from public.conversation_members b where b.conversation_id = cv.id and b.user_id = v) limit 1;
  if c is null then
    insert into public.conversations(kind, mode, created_by) values ('direct', 'clear', me) returning id into c;
    insert into public.conversation_members(conversation_id, user_id) values (c, me), (c, v);
  end if;
  perform public._panel_log('dm', jsonb_build_object('cible', p_username, 'motif', left(p_reason, 300)));
  perform public.log_admin('panneau_dm', p_username, jsonb_build_object('motif', left(p_reason, 300)));
  return c;
end $$;
create or replace function public.panel_vanish(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  update public.panel_users set vanish = coalesce(p_on, false) where user_id = auth.uid();
  perform public._panel_log('vanish', jsonb_build_object('on', p_on));
end $$;
create or replace function public.panel_vanished() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(user_id), '[]'::jsonb) from public.panel_users where vanish and unlocked and not banned and auth.uid() is not null
$$;
create or replace function public.panel_console(p_n int default 40) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare n int := least(greatest(coalesce(p_n, 40), 5), 200);
begin
  perform public._panel_need(2);
  return jsonb_build_object(
    'admin', coalesce((select jsonb_agg(x) from (select at, staff_name, action, target from public.admin_logs order by id desc limit n) x), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(x) from (select at, tbl, op from public.log_alerts order by id desc limit n) x), '[]'::jsonb),
    'panel', coalesce((select jsonb_agg(x) from (select l.at, p.username, l.action from public.panel_log l left join public.profiles p on p.id = l.user_id order by l.id desc limit n) x), '[]'::jsonb));
end $$;
create or replace function public.acct_class(p_username text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(2);
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
  return public._acct_points(v);
end $$;
create or replace function public.acct_class_batch(p_users uuid[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  return coalesce((select jsonb_object_agg(u::text, public._acct_points(u)->>'class') from (select distinct x as u from unnest(p_users) x limit 60) q), '{}'::jsonb);
end $$;
create or replace function public.ui_layout_get() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('sel', sel, 'dx', dx, 'dy', dy)), '[]'::jsonb) from public.ui_layout where auth.uid() is not null
$$;
create or replace function public.ui_layout_set(p_sel text, p_dx int, p_dy int) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  perform public.rate_ok('ui_layout', 200, 3600);
  if p_dx = 0 and p_dy = 0 then delete from public.ui_layout where sel = p_sel;
  else insert into public.ui_layout(sel, dx, dy, by_id) values (p_sel, p_dx, p_dy, auth.uid()) on conflict (sel) do update set dx = excluded.dx, dy = excluded.dy, by_id = excluded.by_id, at = now(); end if;
  perform public._panel_log('layout', jsonb_build_object('sel', p_sel, 'dx', p_dx, 'dy', p_dy));
end $$;
create or replace function public.ui_layout_reset() returns void language plpgsql security definer set search_path = public as $$
begin perform public._panel_need(2); delete from public.ui_layout; perform public._panel_log('layout_reset', '{}'::jsonb); end $$;
-- les commandes de LibonBOT fonctionnent partout pour le personnel débloqué (sans être marqué administrateur du groupe)
create or replace function public.has_cmd_right(p_conv uuid, p_user uuid default auth.uid())
returns boolean language sql security definer stable set search_path = public as $$
  select public.conv_is_admin(p_conv, p_user) or exists(select 1 from public.conversation_rights where conversation_id = p_conv and user_id = p_user)
         or (public._panel_ok(p_user) and public.staff_rank_of(p_user) >= 2)
$$;
do $$ declare f text; begin
  foreach f in array array['panel_state()','panel_seq(text)','panel_pin(text)','panel_cfg_info()','panel_cfg_set(text,text)','panel_users_list()','panel_admin(text,text)','panel_sysmsg(uuid,text)','panel_add(uuid,text)','panel_rank(uuid,text,boolean)','panel_dm(text,text)','panel_vanish(boolean)','panel_vanished()','panel_console(int)','acct_class(text)','acct_class_batch(uuid[])','ui_layout_get()','ui_layout_set(text,int,int)','ui_layout_reset()'] loop
    execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------- 10) protection contre les abus (avant chaque requête de l'API) ----------
create unlogged table if not exists public.ip_hits (ip text not null, at timestamptz not null default now());
create index if not exists ip_hits_ip_at on public.ip_hits (ip, at);
create table if not exists public.ip_blocks (ip text primary key, until timestamptz not null, why text);
alter table public.ip_hits enable row level security; alter table public.ip_blocks enable row level security; revoke all on public.ip_hits, public.ip_blocks from anon, authenticated;
create or replace function public.api_guard() returns void language plpgsql security definer set search_path = public as $$
declare v_ip text; n int;
begin
  begin v_ip := public.req_ip(); exception when others then return; end;
  if v_ip is null then return; end if;
  if exists(select 1 from public.ip_blocks b where b.ip = v_ip and b.until > now()) then raise exception 'Trop de requêtes'; end if;
  if random() < 0.02 then delete from public.ip_hits where at < now() - interval '2 minutes'; delete from public.ip_blocks where until < now(); end if;
  select count(*) into n from public.ip_hits h where h.ip = v_ip and h.at > now() - interval '10 seconds';
  if n > 250 then
    insert into public.ip_blocks(ip, until, why) values (v_ip, now() + interval '10 minutes', 'plus de 250 requêtes en 10 s') on conflict (ip) do update set until = excluded.until;
    return;   -- le blocage est enregistré ; les requêtes suivantes sont refusées pendant 10 minutes
  end if;
  insert into public.ip_hits(ip) values (v_ip);
end $$;
revoke all on function public.api_guard() from public;
grant execute on function public.api_guard() to anon, authenticated;
do $$ begin
  begin execute 'alter role authenticator set pgrst.db_pre_request = ''public.api_guard'''; exception when others then raise notice 'db_pre_request : %', sqlerrm; end;
end $$;

notify pgrst, 'reload config';
notify pgrst, 'reload schema';
