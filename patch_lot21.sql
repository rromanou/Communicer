-- ============================================================================
-- Communicer! — Lot 21 (additif, relançable). À exécuter après patch_lot20.sql.
-- Sécurité, invitations de groupe, Scommunicookie, libération d'espace, tickets, comptes officiels.
-- ============================================================================
create extension if not exists pgcrypto;

-- ---------- secrets internes (jamais lisibles par les clients) ----------
create table if not exists public.app_secret (k text primary key, v text not null);
alter table public.app_secret enable row level security;
revoke all on public.app_secret from anon, authenticated;
insert into public.app_secret(k, v) values ('device_pepper', encode(gen_random_bytes(32), 'hex')), ('keys_pepper', encode(gen_random_bytes(32), 'hex')) on conflict (k) do nothing;
create or replace function public._secret(p_k text) returns text language sql security definer stable set search_path = public as $$ select v from public.app_secret where k = p_k $$;
revoke all on function public._secret(text) from public, anon, authenticated;

-- ---------- 1) VlafiBOT : saut de ligne réel dans la chaîne de l'aide ----------
update public.bot_files f set content = replace(f.content, 'proche' || chr(10) || 'vl/speed', 'proche' || chr(92) || 'nvl/speed'), size = length(replace(f.content, 'proche' || chr(10) || 'vl/speed', 'proche' || chr(92) || 'nvl/speed')), updated_at = now()
 where f.path = 'main.cmm' and f.bot_id = (select id from public.bots where username = 'vlafibot') and f.content like '%proche' || chr(10) || 'vl/speed%';

-- ---------- 2) anciens noms : masqués même pour le titulaire quand il a choisi de les cacher ----------
create or replace function public.username_history_of(p_username text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid; cur text; sh boolean;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  cur := public.name_resolve(p_username);
  select id into v from public.profiles where username = cur;
  if v is null then return '[]'::jsonb; end if;
  sh := coalesce((select show_old from public.name_prefs where user_id = v), true);
  if not sh then return jsonb_build_array(jsonb_build_object('name', cur, 'at', null, 'current', true)); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', n, 'at', at, 'current', cu) order by cu desc, at desc) from (
      select cur as n, null::timestamptz as at, true as cu
      union all select h.name, h.changed_at, false from public.username_history h where h.user_id = v and not h.hidden) q), '[]'::jsonb);
end $$;
-- un ancien nom ne doit plus mener au profil si son titulaire a masqué la liste
create or replace function public.name_resolve(p_name text) returns text language sql security definer stable set search_path = public as $$
  select coalesce((select username from public.profiles where lower(username) = lower(regexp_replace(trim(coalesce(p_name,'')), '^@', ''))),
    (select p.username from public.username_history h join public.profiles p on p.id = h.user_id
       where lower(h.name) = lower(regexp_replace(trim(coalesce(p_name,'')), '^@', '')) and coalesce((select show_old from public.name_prefs np where np.user_id = p.id), true)))
$$;

-- ---------- 3) groupes : rôle administrateur exigé, invitations avec acceptation ----------
create table if not exists public.group_invites (
  id bigint generated always as identity primary key,
  conv uuid not null references public.conversations(id) on delete cascade,
  inviter uuid not null references public.profiles(id) on delete cascade,
  invitee uuid not null references public.profiles(id) on delete cascade,
  wrapped text, created_at timestamptz not null default now(),
  unique (conv, invitee)
);
alter table public.group_invites enable row level security;
revoke all on public.group_invites from anon, authenticated;

create or replace function public._banned_in(p_conv uuid, p_user uuid) returns boolean language plpgsql security definer stable set search_path = public as $$
declare b boolean := false;
begin
  if to_regprocedure('public.ban_active(uuid,uuid)') is not null then execute 'select public.ban_active($1,$2)' into b using p_conv, p_user; end if;
  return coalesce(b, false);
end $$;
revoke all on function public._banned_in(uuid, uuid) from public, anon, authenticated;

create or replace function public.add_member(p_conv uuid, p_username text, p_wrapped text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_c public.conversations%rowtype; v_p uuid; v_un text := lower(trim(p_username));
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = v_me and role = 'admin') then raise exception 'Réservé aux administrateurs du groupe'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'Réservé aux groupes'; end if;
  select id into v_p from public.profiles where username = v_un;
  if v_p is null then raise exception 'Utilisateur introuvable'; end if;
  if v_p = v_me then raise exception 'Vous êtes déjà dans le groupe'; end if;
  if exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = v_p) then raise exception 'Déjà dans le groupe'; end if;
  if public._banned_in(p_conv, v_p) then raise exception 'Cette personne est bannie du groupe'; end if;
  if v_c.mode = 'e2e' and coalesce(p_wrapped, '') = '' then raise exception 'Clé manquante'; end if;
  perform public.rate_ok('inv', 30, 3600);
  insert into public.group_invites(conv, inviter, invitee, wrapped) values (p_conv, v_me, v_p, p_wrapped)
    on conflict (conv, invitee) do update set inviter = excluded.inviter, wrapped = excluded.wrapped, created_at = now();
end $$;

create or replace function public.invites_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'group', coalesce(c.name, 'Groupe'), 'by', (select username from public.profiles where id = i.inviter), 'at', i.created_at) order by i.created_at desc), '[]'::jsonb)
  from public.group_invites i join public.conversations c on c.id = i.conv where i.invitee = auth.uid()
$$;

create or replace function public.invite_answer(p_id bigint, p_accept boolean) returns void language plpgsql security definer set search_path = public as $$
declare i public.group_invites; c public.conversations; un text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into i from public.group_invites where id = p_id and invitee = auth.uid() for update;
  if not found then raise exception 'Invitation introuvable'; end if;
  delete from public.group_invites where id = i.id;
  if not p_accept then return; end if;
  select * into c from public.conversations where id = i.conv;
  if c.id is null then raise exception 'Groupe introuvable'; end if;
  if not exists(select 1 from public.conversation_members where conversation_id = i.conv and user_id = i.inviter and role = 'admin') then raise exception 'L’invitation n’est plus valide'; end if;
  if public._banned_in(i.conv, auth.uid()) then raise exception 'Vous êtes banni de ce groupe'; end if;
  insert into public.conversation_members(conversation_id, user_id) values (i.conv, auth.uid()) on conflict do nothing;
  if c.mode = 'e2e' then
    insert into public.conversation_keys(conversation_id, user_id, from_user, wrapped_key) values (i.conv, auth.uid(), i.inviter, i.wrapped) on conflict do nothing;
  else
    select username into un from public.profiles where id = auth.uid();
    insert into public.messages(conversation_id, sender_id, kind, body) values (i.conv, i.inviter, 'system', '@' || un || ' a rejoint le groupe');
  end if;
end $$;

create or replace function public.update_group(p_conv uuid, p_name text, p_avatar text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = auth.uid() and role = 'admin') then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if char_length(coalesce(p_name, '')) > 60 then raise exception 'Nom trop long'; end if;
  update public.conversations set name = coalesce(nullif(trim(p_name), ''), name), avatar_url = coalesce(p_avatar, avatar_url) where id = p_conv and kind = 'group';
end $$;

create or replace function public.set_theme(p_conv uuid, p_theme jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k text;
begin
  select kind into k from public.conversations where id = p_conv;
  if k is null or not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if k = 'group' and not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = auth.uid() and role = 'admin') then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if jsonb_typeof(p_theme) <> 'object' then raise exception 'Thème invalide'; end if;
  if char_length(p_theme::text) > 4000 then raise exception 'Thème trop volumineux'; end if;
  update public.conversations set theme = p_theme where id = p_conv;
end $$;

-- demandes d'amitié : limitées en fréquence
create or replace function public.send_friend_request(p_username text)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_other uuid; v_f public.friendships%rowtype;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('freq', 20, 3600);
  select id into v_other from public.profiles where username = lower(trim(p_username));
  if v_other is null then raise exception 'Utilisateur introuvable'; end if;
  if v_other = v_me then raise exception 'Vous ne pouvez pas vous ajouter vous-même'; end if;
  select * into v_f from public.friendships where least(requester, addressee) = least(v_me, v_other) and greatest(requester, addressee) = greatest(v_me, v_other);
  if found then
    if v_f.status = 'accepted' then raise exception 'Vous êtes déjà amis'; end if;
    if v_f.requester = v_me then raise exception 'Demande déjà envoyée'; end if;
    update public.friendships set status = 'accepted' where id = v_f.id;
    return 'accepted';
  end if;
  insert into public.friendships (requester, addressee, status) values (v_me, v_other, 'pending');
  return 'sent';
end $$;

-- ---------- 4) médias : bucket privé, lecture réservée aux membres de la conversation ----------
insert into storage.buckets (id, name, public) values ('communicer-private', 'communicer-private', false) on conflict (id) do update set public = false;
drop policy if exists cm_priv_insert on storage.objects;
create policy cm_priv_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'communicer-private' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists cm_priv_read on storage.objects;
create policy cm_priv_read on storage.objects for select to authenticated
  using (bucket_id = 'communicer-private' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.staff_rank_me() >= 2
    or exists(select 1 from public.messages m join public.conversation_members cm on cm.conversation_id = m.conversation_id
              where m.media_path = storage.objects.name and cm.user_id = auth.uid())));
drop policy if exists cm_priv_delete on storage.objects;
create policy cm_priv_delete on storage.objects for delete to authenticated
  using (bucket_id = 'communicer-private' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- 5) clés privées des bots : plus de texte clair ----------
create or replace function public._enc(p text) returns text language sql security definer stable set search_path = public, extensions as $$
  select case when p is null then null else 'ENC:' || encode(pgp_sym_encrypt(p, public._secret('keys_pepper')), 'base64') end $$;
create or replace function public._dec(p text) returns text language sql security definer stable set search_path = public, extensions as $$
  select case when p is null then null when p like 'ENC:%' then pgp_sym_decrypt(decode(substr(p, 5), 'base64'), public._secret('keys_pepper')) else p end $$;
revoke all on function public._enc(text), public._dec(text) from public, anon, authenticated;
update public.bot_api_keys set priv_plain = public._enc(priv_plain) where priv_plain is not null and priv_plain not like 'ENC:%';
update public.bot_api_keys set pub_plain = public._enc(pub_plain) where pub_plain is not null and pub_plain not like 'ENC:%';

create or replace function public.bot_keys_regen(p_bot uuid, p_which text default 'both')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_priv text; v_pub text; v_a text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
begin
  perform public.bot_dev_ok(p_bot);
  if p_which not in ('priv','pub','both') then raise exception 'Choix invalide'; end if;
  if (select official from public.bots where id = p_bot) then raise exception 'Bot officiel : pas de clé API'; end if;
  insert into public.bot_api_keys(bot_id) values (p_bot) on conflict (bot_id) do nothing;
  if p_which in ('priv','both') then
    v_priv := 'CmmApI' || public.rand_str(24, v_a);
    update public.bot_api_keys set priv_hash = public.api_hash(v_priv), priv_hint = right(v_priv, 4), priv_plain = public._enc(v_priv), priv_at = now() where bot_id = p_bot;
  end if;
  if p_which in ('pub','both') then
    v_pub := 'CmmApI' || public.rand_str(18, v_a);
    update public.bot_api_keys set pub_hash = public.api_hash(v_pub), pub_hint = right(v_pub, 4), pub_plain = public._enc(v_pub), pub_at = now() where bot_id = p_bot;
  end if;
  perform public.bot_log_add(p_bot, case p_which when 'priv' then 'clé API privée régénérée' when 'pub' then 'clé API publique régénérée' else 'clés API régénérées' end, '{}'::jsonb);
  return jsonb_build_object('priv', v_priv, 'pub', v_pub);
end $$;
create or replace function public.bot_keys_get(p_bot uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare k public.bot_api_keys;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  select * into k from public.bot_api_keys where bot_id = p_bot;
  if not found then return jsonb_build_object('priv', null, 'pub', null, 'blocked', false); end if;
  return jsonb_build_object('priv', public._dec(k.priv_plain), 'pub', public._dec(k.pub_plain), 'priv_known', k.priv_hash is not null, 'pub_known', k.pub_hash is not null,
    'priv_at', k.priv_at, 'pub_at', k.pub_at, 'blocked', k.blocked, 'blocked_reason', k.blocked_reason);
end $$;

-- ---------- 6) jeux : récompense et statistiques ----------
create or replace function public.game_win(p_conv uuid, p_game text, p_session text)
returns numeric language plpgsql security definer set search_path = public as $$
declare l public.live_sessions; paid_today int; r numeric := public.cfg_n('win_reward');
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if (select kind from public.conversations where id = p_conv) <> 'group' then return 0; end if;
  if p_game !~ '^[a-z0-9_]{2,24}$' then raise exception 'Jeu invalide'; end if;
  perform public.rate_ok('win', 60, 3600);
  select * into l from public.live_sessions where session_id = p_session and conversation_id = p_conv and kind = 'game';
  if not found then return 0; end if;
  if l.game is not null and l.game <> p_game then return 0; end if;
  if l.peak < 2 or l.started_at > now() - interval '30 seconds' then return 0; end if;
  begin insert into public.game_wins(user_id, conversation_id, game, session_id) values (auth.uid(), p_conv, p_game, left(p_session, 40));
  exception when unique_violation then return 0; end;
  select count(*) into paid_today from public.game_wins where user_id = auth.uid() and paid and at >= public.staff_today()::timestamp at time zone 'America/Toronto';
  if paid_today < 20 then
    update public.game_wins set paid = true where user_id = auth.uid() and session_id = left(p_session, 40);
    perform public.tok_add(auth.uid(), r, 'victoire en groupe : ' || p_game);
  else r := 0; end if;
  perform public.badges_check(auth.uid());
  return r;
end $$;

create or replace function public.record_game(p_game text, p_won boolean, p_secs int)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); s int := greatest(0, least(coalesce(p_secs, 0), 3600));
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if p_game is null or p_game !~ '^[a-z0-9_]{2,24}$' then raise exception 'Jeu invalide'; end if;
  perform public.rate_ok('rg', 240, 3600);
  insert into public.game_stats (user_id, game, played, wins, win_secs)
  values (v_me, p_game, 1, case when p_won then 1 else 0 end, case when p_won then s else 0 end)
  on conflict (user_id, game) do update
    set played = game_stats.played + 1, wins = game_stats.wins + case when p_won then 1 else 0 end,
        win_secs = game_stats.win_secs + case when p_won then s else 0 end, updated_at = now();
end $$;

-- ---------- 7) comptes @system et @staff : jetons d'authentification non nuls (cause de l'erreur 500 à la connexion) ----------
do $$
declare c text;
begin
  foreach c in array array['confirmation_token','recovery_token','email_change','email_change_token_new','email_change_token_current','phone_change','phone_change_token','reauthentication_token'] loop
    if exists(select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = c) then
      execute format('update auth.users set %I = coalesce(%I, %L) where id in (%L, %L) and %I is null', c, c, '', 'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002', c);
    end if;
  end loop;
end $$;

-- ---------- 8) tickets : fermeture par les administrateurs ----------
create or replace function public.support_close(p_ref text) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select * into t from public.support_tickets where ref = p_ref for update;
  if not found then raise exception 'Demande introuvable'; end if;
  if t.status = 'closed' then raise exception 'Demande déjà fermée'; end if;
  if t.conv is not null then insert into public.messages(conversation_id, sender_id, kind, body) values (t.conv, auth.uid(), 'system', 'Demande ' || t.ref || ' fermée.'); end if;
  update public.support_tickets set status = 'closed', closed_at = now() where id = t.id;
  perform public.log_admin('support_ferme', p_ref, '{}'::jsonb);
end $$;
create or replace function public.support_thread(p_ref text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare t public.support_tickets; me int := public.staff_rank_me(); mine boolean; w boolean;
begin
  select * into t from public.support_tickets where ref = p_ref;
  if not found then raise exception 'Demande introuvable'; end if;
  mine := t.user_id = auth.uid();
  if not mine and me < 1 then raise exception 'Accès refusé'; end if;
  w := t.status <> 'closed' and (mine or (t.status = 'claimed' and auth.uid() in (t.claimed_by, t.student_id)));
  return jsonb_build_object('ref', t.ref, 'subject', t.subject, 'status', t.status, 'user', case when mine then null else t.user_name end, 'about', t.about, 'can_write', w, 'mine', mine,
    'claimed_by', (select username from public.profiles where id = t.claimed_by), 'student', (select username from public.profiles where id = coalesce(t.student_id, t.student_req)), 'student_pending', t.student_id is null and t.student_req is not null,
    'can_close', t.status <> 'closed' and me >= 2,
    'msgs', coalesce((select jsonb_agg(jsonb_build_object('staff', m.from_staff, 'who', case when m.from_staff then 'Staff' else null end, 'body', m.body, 'at', m.at) order by m.id) from public.support_msgs m where m.ticket_id = t.id), '[]'::jsonb));
end $$;

-- ---------- 9) @system / @staff : peuvent écrire en premier à n'importe qui ----------
create or replace function public.official_start_chat(p_username text) returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v uuid; c uuid;
begin
  if me is null or me not in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002') then raise exception 'Réservé aux comptes officiels'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username, '')), '^@', ''));
  if v is null or v = me then raise exception 'Utilisateur introuvable'; end if;
  select cv.id into c from public.conversations cv where cv.kind = 'direct' and cv.mode = 'clear' and cv.hub is null
    and exists(select 1 from public.conversation_members a where a.conversation_id = cv.id and a.user_id = me)
    and exists(select 1 from public.conversation_members b where b.conversation_id = cv.id and b.user_id = v) limit 1;
  if c is null then
    insert into public.conversations(kind, mode, created_by) values ('direct', 'clear', me) returning id into c;
    insert into public.conversation_members(conversation_id, user_id) values (c, me), (c, v);
  end if;
  return c;
end $$;
revoke all on function public.official_start_chat(text) from public, anon;
grant execute on function public.official_start_chat(text) to authenticated;

-- ---------- 10) équipes e-Sport : mes équipes ----------
create or replace function public.esport_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('conv', t.conv, 'name', t.name, 'title', t.title, 'mine', t.owner = auth.uid(),
    'members', (select count(*) from public.conversation_members m where m.conversation_id = t.conv)) order by t.created_at desc), '[]'::jsonb)
  from public.esport_teams t where exists(select 1 from public.conversation_members m where m.conversation_id = t.conv and m.user_id = auth.uid())
$$;
revoke all on function public.esport_mine() from public, anon; grant execute on function public.esport_mine() to authenticated;
revoke all on function public.add_member(uuid, text, text), public.invites_mine(), public.invite_answer(bigint, boolean), public.update_group(uuid, text, text), public.set_theme(uuid, jsonb),
  public.send_friend_request(text), public.support_close(text), public.support_thread(text), public.game_win(uuid, text, text), public.record_game(text, boolean, int),
  public.bot_keys_regen(uuid, text), public.bot_keys_get(uuid), public.username_history_of(text) from public, anon;
grant execute on function public.add_member(uuid, text, text), public.invites_mine(), public.invite_answer(bigint, boolean), public.update_group(uuid, text, text), public.set_theme(uuid, jsonb),
  public.send_friend_request(text), public.support_close(text), public.support_thread(text), public.game_win(uuid, text, text), public.record_game(text, boolean, int),
  public.bot_keys_regen(uuid, text), public.bot_keys_get(uuid), public.username_history_of(text) to authenticated;

-- ---------- 11) Scommunicookie : identifiant de navigateur signé par le serveur ----------
create table if not exists public.user_devices (
  user_id uuid not null references public.profiles(id) on delete cascade,
  dev text not null,                       -- empreinte (SHA-256 salée) du Scommunicookie
  first_seen timestamptz not null default now(), last_seen timestamptz not null default now(),
  primary key (user_id, dev)
);
create index if not exists user_devices_dev on public.user_devices(dev);
create table if not exists public.device_bans (dev text primary key, reason text, by_id uuid references public.profiles(id) on delete set null, at timestamptz not null default now());
alter table public.user_devices enable row level security; alter table public.device_bans enable row level security;
revoke all on public.user_devices, public.device_bans from anon, authenticated;

create or replace function public._dev_sig(p_id text) returns text language sql security definer stable set search_path = public, extensions as $$
  select encode(hmac(p_id, public._secret('device_pepper'), 'sha256'), 'hex') $$;
create or replace function public._dev_hash(p_cookie text) returns text language sql security definer stable set search_path = public, extensions as $$
  select encode(digest(p_cookie || public._secret('device_pepper'), 'sha256'), 'hex') $$;
revoke all on function public._dev_sig(text), public._dev_hash(text) from public, anon, authenticated;

-- émet un nouveau Scommunicookie (id aléatoire + signature serveur) ; seuls les cookies émis ici sont acceptés
create or replace function public.device_issue() returns text language plpgsql security definer set search_path = public, extensions as $$
declare id text := encode(gen_random_bytes(24), 'hex');
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('dvi', 10, 3600);
  return 'SC1.' || id || '.' || public._dev_sig(id);
end $$;

-- associe le cookie au compte (conserve celui du navigateur s'il existe déjà) ; renvoie l'état de bannissement
create or replace function public.device_register(p_cookie text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare parts text[]; h text; me uuid := auth.uid();
begin
  if me is null then raise exception 'Non connecté'; end if;
  parts := string_to_array(coalesce(p_cookie, ''), '.');
  if array_length(parts, 1) <> 3 or parts[1] <> 'SC1' or parts[3] <> public._dev_sig(parts[2]) then return jsonb_build_object('ok', false); end if;
  h := public._dev_hash(p_cookie);
  insert into public.user_devices(user_id, dev) values (me, h) on conflict (user_id, dev) do nothing;
  return jsonb_build_object('ok', true, 'banned', exists(select 1 from public.device_bans where dev = h));
end $$;

create or replace function public.staff_user_devices(p_username text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id into v from public.profiles where username = public.name_resolve(p_username);
  if v is null then raise exception 'Compte introuvable'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', left(d.dev, 12), 'first', d.first_seen, 'last', d.last_seen, 'banned', exists(select 1 from public.device_bans b where b.dev = d.dev),
     'others', (select count(distinct u.user_id) - 1 from public.user_devices u where u.dev = d.dev)) order by d.last_seen desc) from public.user_devices d where d.user_id = v), '[]'::jsonb);
end $$;
create or replace function public.staff_device_accounts(p_code text) returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if p_code !~ '^[0-9a-f]{12}$' then raise exception 'Code invalide'; end if;
  return coalesce((select jsonb_agg(p.username) from public.user_devices d join public.profiles p on p.id = d.user_id where left(d.dev, 12) = p_code), '[]'::jsonb);
end $$;
create or replace function public.staff_device_ban(p_code text, p_on boolean, p_reason text default null) returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if p_code !~ '^[0-9a-f]{12}$' then raise exception 'Code invalide'; end if;
  for r in select distinct dev from public.user_devices where left(dev, 12) = p_code loop
    if p_on then insert into public.device_bans(dev, reason, by_id) values (r.dev, left(coalesce(p_reason, ''), 300), auth.uid()) on conflict (dev) do nothing;
    else delete from public.device_bans where dev = r.dev; end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Navigateur introuvable'; end if;
  perform public.log_admin(case when p_on then 'device_ban' else 'device_deban' end, p_code, '{}'::jsonb);
  return n;
end $$;
-- un navigateur banni ne peut plus écrire
create or replace function public.trg_dev_ban() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sender_id = auth.uid() and new.kind <> 'system' and exists(select 1 from public.user_devices d join public.device_bans b on b.dev = d.dev where d.user_id = new.sender_id) then
    raise exception 'Ce navigateur est banni';
  end if;
  return new;
end $$;
drop trigger if exists aa_dev_ban on public.messages;
create trigger aa_dev_ban before insert on public.messages for each row execute function public.trg_dev_ban();
revoke all on function public.device_issue(), public.device_register(text), public.staff_user_devices(text), public.staff_device_accounts(text), public.staff_device_ban(text, boolean, text) from public, anon;
grant execute on function public.device_issue(), public.device_register(text), public.staff_user_devices(text), public.staff_device_accounts(text), public.staff_device_ban(text, boolean, text) to authenticated;

-- ---------- 12) libération d'espace (commandant seulement) ----------
create table if not exists public.purge_cfg (kind text not null check (kind in ('g','u')), item text not null, auto boolean not null default false, months int check (months is null or months in (1,2,3,6,9,12,24)), primary key (kind, item));
create table if not exists public.purge_tokens (token uuid primary key default gen_random_uuid(), user_id uuid not null, kind text not null, item text not null, mode text not null, n int, months int,
  est_rows bigint not null, est_bytes bigint not null, expires_at timestamptz not null default now() + interval '10 minutes', used boolean not null default false);
create table if not exists public.purge_log (id bigint generated always as identity primary key, at timestamptz not null default now(), by_id uuid, kind text, item text, mode text, rows_deleted bigint, bytes_est bigint, auto boolean not null default false, err text);
alter table public.purge_cfg enable row level security; alter table public.purge_tokens enable row level security; alter table public.purge_log enable row level security;
revoke all on public.purge_cfg, public.purge_tokens, public.purge_log from anon, authenticated;

-- catalogue fermé : seuls ces éléments peuvent être supprimés (aucun nom de table ne vient du client)
create or replace function public._purge_cat() returns table(kind text, item text, tbl text, col text, col2 text, extra text) language sql immutable as $$
  select * from (values
   ('g','admin_logs','admin_logs',null,null,null),('g','audit_flags','audit_flags',null,null,null),('g','badge_requests','badge_requests',null,null,null),('g','bot_logs','bot_logs',null,null,null),
   ('g','bot_requests','bot_requests',null,null,null),('g','bug_reports','bug_reports',null,null,null),('g','ciffron_flags','ciffron_flags',null,null,null),('g','conversation_user_log','conversation_user_log',null,null,null),
   ('g','crypto_orders','crypto_orders',null,null,null),('g','crypto_supply_events','crypto_supply_events',null,null,null),('g','crypto_trades','crypto_trades',null,null,null),('g','daily_claims','daily_claims',null,null,null),
   ('g','daily_state','daily_state',null,null,null),('g','live_sessions','live_sessions',null,null,'ended_at is not null'),('g','log_alert_ack','log_alert_ack',null,null,null),('g','log_alerts','log_alerts',null,null,null),
   ('g','login_days','login_days',null,null,null),('g','mail_log','mail_log',null,null,null),('g','orders','orders',null,null,null),('g','panel_flags','panel_flags',null,null,null),
   ('g','quest_events','quest_events',null,null,null),('g','rate_hits','rate_hits',null,null,null),('g','reports','reports',null,null,null),('g','staff_activity','staff_activity',null,null,null),
   ('g','staff_week_log','staff_week_log',null,null,null),('g','staff_weekly_quiz','staff_weekly_quiz',null,null,null),('g','support_msgs','support_msgs',null,null,null),('g','support_tickets','support_tickets',null,null,'status = ''closed'''),
   ('g','t_matches','t_matches',null,null,null),('g','email_codes','email_codes',null,null,null),('g','group_votes','group_votes',null,null,null),('g','smoke_deaths','smoke_deaths',null,null,null),
   ('g','smoke_rescue','smoke_rescue',null,null,null),('g','user_quests','user_quests',null,null,null),('g','world_messages','world_messages',null,null,null),('g','world_reads','world_reads',null,null,null),('g','t_entries','t_entries',null,null,null),
   ('u','absence','absence','user_id',null,null),('u','badge_requests','badge_requests','user_id',null,null),('u','conv_nicks','conv_nicks','user_id',null,null),('u','conv_pins','conv_pins','user_id',null,null),
   ('u','conversation_members_droits','user_rights_off','user_id',null,null),('u','game_stats','game_stats','user_id',null,null),('u','game_wins','game_wins','user_id',null,null),('u','group_votes','group_votes','user_id',null,null),
   ('u','inventory','inventory','user_id',null,null),('u','message_hidden','message_hidden','user_id',null,null),('u','name_prefs','name_prefs','user_id',null,null),('u','profile_ext','profile_ext','user_id',null,null),
   ('u','referral_codes','referral_codes','user_id',null,null),('u','referral_contests','referral_contests','user_id','referrer_id',null),('u','referrals','referrals','referrer_id','referred_id',null),
   ('u','romanomoney_saves','romanomoney_saves','user_id',null,null),('u','smoke_chars','smoke_chars','user_id',null,null),('u','smoke_cosm_inv','smoke_cosm_inv','user_id',null,null),('u','smoke_inv','smoke_inv','user_id',null,null),
   ('u','smoke_pill_inv','smoke_pill_inv','user_id',null,null),('u','smoke_powder','smoke_powder','user_id',null,null),('u','smoke_trick_inv','smoke_trick_inv','user_id',null,null),
   ('u','support_tickets','support_tickets','user_id',null,null),('u','t_entries','t_entries','ref',null,'kind = ''user'''),('u','user_blocks','user_blocks','blocker',null,null),('u','user_quests','user_quests','user_id',null,null),
   ('u','username_history','username_history','user_id',null,null),('u','wallets','wallets','user_id',null,null)
  ) v(kind, item, tbl, col, col2, extra)
$$;
revoke all on function public._purge_cat() from public, anon, authenticated;

create or replace function public._purge_tcol(p_tbl text) returns text language sql stable set search_path = public as $$
  select c.column_name from information_schema.columns c where c.table_schema = 'public' and c.table_name = p_tbl
    and c.column_name in ('created_at','at','ts','changed_at','sent_at','updated_at','last_seen','started_at','day','d') and c.data_type in ('timestamp with time zone','timestamp without time zone','date')
  order by array_position(array['created_at','at','ts','changed_at','sent_at','updated_at','last_seen','started_at','day','d'], c.column_name::text) limit 1
$$;
create or replace function public._purge_inactive(p_months int) returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p
   where coalesce(p.last_seen, p.created_at) < now() - make_interval(months => p_months)
     and not exists(select 1 from public.site_staff s where s.user_id = p.id)
     and p.id not in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002')
$$;
revoke all on function public._purge_tcol(text), public._purge_inactive(int) from public, anon, authenticated;

-- nombre de lignes concernées
create or replace function public._purge_count(p_kind text, p_item text, p_mode text, p_n int, p_months int) returns bigint language plpgsql security definer set search_path = public as $$
declare c record; tc text; w text := 'true'; n bigint;
begin
  select * into c from public._purge_cat() where kind = p_kind and item = p_item;
  if not found or to_regclass('public.' || c.tbl) is null then return -1; end if;
  if c.extra is not null then w := '(' || c.extra || ')'; end if;
  if p_kind = 'g' then
    if p_mode = 'all' then execute format('select count(*) from public.%I where %s', c.tbl, w) into n;
    elsif p_mode = 'oldest' then execute format('select least(count(*), %s) from public.%I where %s', greatest(p_n, 0), c.tbl, w) into n;
    elsif p_mode = 'age' then
      tc := public._purge_tcol(c.tbl); if tc is null or p_months is null then return -1; end if;
      execute format('select count(*) from public.%I where %s and %I < now() - make_interval(months => %s)', c.tbl, w, tc, p_months) into n;
    else return -1; end if;
  else
    if p_months is null then return -1; end if;
    execute format('select count(*) from public.%I where %s and (%I in (select public._purge_inactive(%s))%s)', c.tbl, w, c.col, p_months,
      case when c.col2 is null then '' else format(' or %I in (select public._purge_inactive(%s))', c.col2, p_months) end) into n;
  end if;
  return n;
end $$;
revoke all on function public._purge_count(text, text, text, int, int) from public, anon, authenticated;

create or replace function public.purge_overview() returns jsonb language plpgsql security definer set search_path = public as $$
declare total bigint := pg_database_size(current_database()); lim bigint; pub bigint; listed bigint := 0; stor bigint := 0; tmp bigint := 0; items jsonb := '[]'::jsonb; c record; rws bigint; sz bigint; v_auto boolean; v_m int;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  lim := coalesce((select v::bigint from public.app_secret where k = 'db_limit_mb'), 500) * 1048576;
  select coalesce(sum(pg_total_relation_size(pc.oid)), 0) into pub from pg_class pc join pg_namespace pn on pn.oid = pc.relnamespace where pn.nspname = 'public' and pc.relkind = 'r';
  begin execute 'select coalesce(sum((metadata->>''size'')::bigint), 0) from storage.objects' into stor; exception when others then stor := 0; end;
  begin execute 'select coalesce(sum((o.metadata->>''size'')::bigint), 0) from storage.objects o where o.bucket_id = ''communicer-private'' and o.created_at < now() - interval ''1 day'' and not exists(select 1 from public.messages m where m.media_path = o.name)' into tmp; exception when others then tmp := 0; end;
  for c in select * from public._purge_cat() loop
    if to_regclass('public.' || c.tbl) is null then continue; end if;
    execute format('select count(*) from public.%I', c.tbl) into rws;
    sz := pg_total_relation_size(('public.' || c.tbl)::regclass);
    v_auto := false; v_m := null;
    select pcf.auto, pcf.months into v_auto, v_m from public.purge_cfg pcf where pcf.kind = c.kind and pcf.item = c.item;
    if c.kind = 'g' then listed := listed + sz; end if;
    items := items || jsonb_build_object('kind', c.kind, 'item', c.item, 'rows', rws, 'bytes', sz, 'tcol', public._purge_tcol(c.tbl), 'auto', coalesce(v_auto, false), 'months', v_m,
      'eligible', case when c.kind = 'u' and v_m is not null then public._purge_count('u', c.item, 'all', 0, v_m) else null end);
  end loop;
  return jsonb_build_object('total', total, 'limit', lim, 'free', greatest(lim - total, 0), 'system', greatest(total - pub, 0), 'sql_public', pub, 'listed', listed, 'storage', stor, 'tmp', tmp, 'items', items);
end $$;

create or replace function public.purge_prepare(p_kind text, p_item text, p_mode text, p_n int default null, p_months int default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare c record; cnt bigint; rws bigint; sz bigint; est bigint; tk uuid; total bigint := pg_database_size(current_database());
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  perform public.rate_ok('purge_prep', 60, 3600);
  if p_kind = 't' then
    if p_item <> 'tmpfiles' then raise exception 'Élément inconnu'; end if;
    execute 'select count(*), coalesce(sum((o.metadata->>''size'')::bigint), 0) from storage.objects o where o.bucket_id = ''communicer-private'' and o.created_at < now() - interval ''1 day'' and not exists(select 1 from public.messages m where m.media_path = o.name)' into cnt, est;
  else
    if p_mode not in ('all','oldest','age') then raise exception 'Mode invalide'; end if;
    if p_mode = 'oldest' and (p_n is null or p_n not between 1 and 1000000) then raise exception 'Nombre invalide'; end if;
    select * into c from public._purge_cat() where kind = p_kind and item = p_item;
    if not found or to_regclass('public.' || c.tbl) is null then raise exception 'Élément inconnu ou absent de cette base'; end if;
    cnt := public._purge_count(p_kind, p_item, p_mode, p_n, p_months);
    if cnt < 0 then raise exception 'Combinaison non permise (colonne de date introuvable ou durée manquante)'; end if;
    execute format('select count(*) from public.%I', c.tbl) into rws; sz := pg_total_relation_size(('public.' || c.tbl)::regclass);
    est := case when rws = 0 then 0 else (sz * cnt / rws)::bigint end;
  end if;
  insert into public.purge_tokens(user_id, kind, item, mode, n, months, est_rows, est_bytes) values (auth.uid(), p_kind, p_item, coalesce(p_mode, 'all'), p_n, p_months, cnt, est) returning token into tk;
  return jsonb_build_object('token', tk, 'rows', cnt, 'bytes', est, 'pct', round(100.0 * est / greatest(total, 1), 2), 'total', total);
end $$;

create or replace function public._purge_do(p_kind text, p_item text, p_mode text, p_n int, p_months int) returns bigint language plpgsql security definer set search_path = public as $$
declare c record; tc text; w text := 'true'; n bigint;
begin
  select * into c from public._purge_cat() where kind = p_kind and item = p_item;
  if not found or to_regclass('public.' || c.tbl) is null then raise exception 'Élément inconnu'; end if;
  if c.extra is not null then w := '(' || c.extra || ')'; end if;
  if p_kind = 'g' then
    if p_mode = 'all' then execute format('delete from public.%I where %s', c.tbl, w);
    elsif p_mode = 'oldest' then
      tc := public._purge_tcol(c.tbl); if tc is null then raise exception 'Aucune colonne de date : utilisez « tout »'; end if;
      execute format('delete from public.%I where ctid in (select ctid from public.%I where %s order by %I asc limit %s)', c.tbl, c.tbl, w, tc, p_n);
    else
      tc := public._purge_tcol(c.tbl); if tc is null or p_months is null then raise exception 'Durée invalide'; end if;
      execute format('delete from public.%I where %s and %I < now() - make_interval(months => %s)', c.tbl, w, tc, p_months);
    end if;
  else
    if p_months is null then raise exception 'Durée invalide'; end if;
    execute format('delete from public.%I where %s and (%I in (select public._purge_inactive(%s))%s)', c.tbl, w, c.col, p_months,
      case when c.col2 is null then '' else format(' or %I in (select public._purge_inactive(%s))', c.col2, p_months) end);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public._purge_do(text, text, text, int, int) from public, anon, authenticated;

create or replace function public.purge_exec(p_token uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.purge_tokens; n bigint; now_cnt bigint; names jsonb;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select * into t from public.purge_tokens where token = p_token and user_id = auth.uid() for update;
  if not found or t.used or t.expires_at < now() then raise exception 'Confirmation expirée : recommencez'; end if;
  update public.purge_tokens set used = true where token = p_token;
  if t.kind = 't' then
    execute 'select coalesce(jsonb_agg(o.name), ''[]''::jsonb) from (select o.name from storage.objects o where o.bucket_id = ''communicer-private'' and o.created_at < now() - interval ''1 day'' and not exists(select 1 from public.messages m where m.media_path = o.name) limit 1000) o' into names;
    insert into public.purge_log(by_id, kind, item, mode, rows_deleted, bytes_est) values (auth.uid(), 't', 'tmpfiles', 'all', jsonb_array_length(names), t.est_bytes);
    perform public.log_admin('purge', 'tmpfiles', jsonb_build_object('n', jsonb_array_length(names)));
    return jsonb_build_object('remove', names);
  end if;
  now_cnt := public._purge_count(t.kind, t.item, t.mode, t.n, t.months);
  if now_cnt > t.est_rows * 1.2 + 50 then raise exception 'Le nombre de lignes a changé depuis la confirmation : recommencez'; end if;
  begin
    n := public._purge_do(t.kind, t.item, t.mode, t.n, t.months);
  exception when others then
    insert into public.purge_log(by_id, kind, item, mode, rows_deleted, bytes_est, err) values (auth.uid(), t.kind, t.item, t.mode, 0, 0, sqlerrm);
    raise exception 'Suppression annulée (rien n’a été supprimé) : %', sqlerrm;
  end;
  insert into public.purge_log(by_id, kind, item, mode, rows_deleted, bytes_est) values (auth.uid(), t.kind, t.item, t.mode, n, t.est_bytes);
  perform public.log_admin('purge', t.kind || ':' || t.item, jsonb_build_object('mode', t.mode, 'n', t.n, 'months', t.months, 'rows', n));
  return jsonb_build_object('rows', n, 'bytes', t.est_bytes);
end $$;

create or replace function public.purge_cfg_set(p_kind text, p_item text, p_auto boolean, p_months int) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_kind not in ('g','u') or not exists(select 1 from public._purge_cat() where kind = p_kind and item = p_item) then raise exception 'Élément inconnu'; end if;
  if p_months is not null and p_months not in (1,2,3,6,9,12,24) then raise exception 'Durée invalide'; end if;
  if p_auto and p_months is null then raise exception 'Choisissez une durée pour activer la suppression automatique'; end if;
  insert into public.purge_cfg(kind, item, auto, months) values (p_kind, p_item, p_auto, p_months)
    on conflict (kind, item) do update set auto = excluded.auto, months = excluded.months;
  perform public.log_admin('purge_cfg', p_kind || ':' || p_item, jsonb_build_object('auto', p_auto, 'months', p_months));
end $$;
create or replace function public.purge_limit_set(p_mb int) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_mb not between 100 and 100000 then raise exception 'Valeur invalide'; end if;
  insert into public.app_secret(k, v) values ('db_limit_mb', p_mb::text) on conflict (k) do update set v = excluded.v;
end $$;

-- suppression automatique (appelée par pg_cron si présent, ou par le commandant)
create or replace function public.purge_auto_run() returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n bigint; tot bigint := 0; me uuid := auth.uid();
begin
  if me is not null and public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  for r in select * from public.purge_cfg where auto and months is not null loop
    begin
      n := public._purge_do(r.kind, r.item, case when r.kind = 'g' then 'age' else 'all' end, null, r.months);
      tot := tot + coalesce(n, 0);
      if n > 0 then insert into public.purge_log(by_id, kind, item, mode, rows_deleted, bytes_est, auto) values (me, r.kind, r.item, 'auto', n, 0, true); end if;
    exception when others then
      insert into public.purge_log(by_id, kind, item, mode, rows_deleted, bytes_est, auto, err) values (me, r.kind, r.item, 'auto', 0, 0, true, sqlerrm);
    end;
  end loop;
  return jsonb_build_object('rows', tot);
end $$;
revoke all on function public.purge_overview(), public.purge_prepare(text, text, text, int, int), public.purge_exec(uuid), public.purge_cfg_set(text, text, boolean, int), public.purge_limit_set(int), public.purge_auto_run() from public, anon;
grant execute on function public.purge_overview(), public.purge_prepare(text, text, text, int, int), public.purge_exec(uuid), public.purge_cfg_set(text, text, boolean, int), public.purge_limit_set(int), public.purge_auto_run() to authenticated;
revoke execute on function public.purge_auto_run() from anon;
do $$ begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.schedule('communicer-purge-auto', '17 4 * * *', 'select public.purge_auto_run()'); exception when others then raise notice 'pg_cron : %', sqlerrm; end;
  end if;
end $$;
drop policy if exists cm_priv_delete_cmd on storage.objects;
create policy cm_priv_delete_cmd on storage.objects for delete to authenticated using (bucket_id = 'communicer-private' and public.staff_rank_me() >= 4);

-- ---------- 13) Ciffron : règles révisées (moins de fausses alertes, plus de contournements couverts) ----------
insert into public.ciffron_rules(id, pat, fl, files, reason) values
 ('html-bad', '(<[ ]*(iframe|object|embed|base)([^A-Za-z0-9]|$)|<[ ]*meta[^>]*http-equiv|<[ ]*form[^>]*action[ ]*=|<[ ]*script[^>]*[ ]src|javascript[ ]*:)', 'i', 'html|js|cmm', 'Élément HTML dangereux'),
 ('loop-inf', '(tant[ ]+que[ ]+(vrai|1)[ ]*:|while[ ]*\([ ]*(true|1)[ ]*\)|for[ ]*\([ ]*;[ ]*;[ ]*\))', '', 'js|cmm', 'Boucle infinie (risque de spam ou de gel)'),
 ('priv-info', '(^|[^A-Za-z0-9_$"''])(sender_id|user_id|auth\.uid|private_key|public_key)([^A-Za-z0-9_$"'']|$)', 'i', 'js|cmm', 'Recherche d’informations privées'),
 ('proto', '(__proto__|\.[ ]*constructor[ ]*(\.|\(|\[)|constructor[ ]*\[|Object[ ]*\.[ ]*(setPrototypeOf|getPrototypeOf))', '', 'js|cmm', 'Accès aux prototypes (sortie du bac à sable)'),
 ('idx-net', '\[[ ]*[''"`][ ]*(fetch|XMLHttpRequest|WebSocket|eval|Function|constructor|importScripts|localStorage|cookie|parent|top)', '', 'js|cmm', 'Accès indirect à une fonction interdite'),
 ('dyn-import', '(^|[^A-Za-z0-9_$.])import[ ]*\(|new[ ]+(Worker|SharedWorker)[ ]*\(|navigator[ ]*\.[ ]*serviceWorker', '', 'js|cmm', 'Chargement dynamique ou travailleur'),
 ('global-obj', '(^|[^A-Za-z0-9_$.])(globalThis|self|window)[ ]*\[', '', 'js|cmm', 'Accès dynamique à l’objet global'),
 ('str-timer', '(setTimeout|setInterval)[ ]*\([ ]*[''"`+]', '', 'js|cmm', 'Minuterie avec du texte (code dynamique)')
on conflict (id) do update set pat = excluded.pat, fl = excluded.fl, files = excluded.files, reason = excluded.reason, enabled = true;
