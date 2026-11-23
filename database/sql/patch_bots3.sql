-- ============================================================================
-- Communicer! — Patch 8 (additif) : sessions en direct, clés lisibles, messages (modifier / supprimer /
-- masquer), commandes LibonBOT (clear, del msgn), jeux et polices de groupe. À exécuter après patch_bots2.sql.
-- ============================================================================

-- ---------- 1) Clés API : affichables par le développeur (privée masquée dans l'interface) ----------
alter table public.bot_api_keys add column if not exists priv_plain text;
alter table public.bot_api_keys add column if not exists pub_plain text;

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
    update public.bot_api_keys set priv_hash = public.api_hash(v_priv), priv_hint = right(v_priv, 4), priv_plain = v_priv, priv_at = now() where bot_id = p_bot;
  end if;
  if p_which in ('pub','both') then
    v_pub := 'CmmApI' || public.rand_str(18, v_a);
    update public.bot_api_keys set pub_hash = public.api_hash(v_pub), pub_hint = right(v_pub, 4), pub_plain = v_pub, pub_at = now() where bot_id = p_bot;
  end if;
  perform public.bot_log_add(p_bot, case p_which when 'priv' then 'clé API privée régénérée' when 'pub' then 'clé API publique régénérée' else 'clés API régénérées' end, '{}'::jsonb);
  return jsonb_build_object('priv', v_priv, 'pub', v_pub);
end $$;

-- Le propriétaire relit ses clés (celles créées avant ce patch n'existent qu'en empreinte : à régénérer)
create or replace function public.bot_keys_get(p_bot uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare k public.bot_api_keys;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  select * into k from public.bot_api_keys where bot_id = p_bot;
  if not found then return jsonb_build_object('priv', null, 'pub', null, 'blocked', false); end if;
  return jsonb_build_object('priv', k.priv_plain, 'pub', k.pub_plain, 'priv_known', k.priv_hash is not null, 'pub_known', k.pub_hash is not null,
    'priv_at', k.priv_at, 'pub_at', k.pub_at, 'blocked', k.blocked, 'blocked_reason', k.blocked_reason);
end $$;
grant execute on function public.bot_keys_get(uuid) to authenticated;

-- ---------- 2) Sessions en direct : 1 appel + 1 jeu au plus par conversation ----------
create table if not exists public.live_sessions (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  kind text not null check (kind in ('call','game')),
  session_id text not null,
  game text,
  host uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null default now(),
  beat_at timestamptz not null default now(),
  ended_at timestamptz
);
create unique index if not exists live_one_active on public.live_sessions(conversation_id, kind) where ended_at is null;
create index if not exists live_sess_idx on public.live_sessions(session_id);
alter table public.live_sessions enable row level security;
drop policy if exists live_sel on public.live_sessions;
create policy live_sel on public.live_sessions for select to authenticated using (public.is_member(conversation_id));
grant select on public.live_sessions to authenticated;
do $$ begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'live_sessions') then
    alter publication supabase_realtime add table public.live_sessions;
  end if;
end $$;

create or replace function public.live_start(p_conv uuid, p_kind text, p_session text, p_game text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if p_kind not in ('call','game') then raise exception 'Type invalide'; end if;
  update public.live_sessions set ended_at = now() where conversation_id = p_conv and ended_at is null and beat_at < now() - interval '90 seconds';
  if exists(select 1 from public.live_sessions where conversation_id = p_conv and kind = p_kind and ended_at is null) then
    raise exception '%', case p_kind when 'call' then 'Un appel est déjà en cours dans cette conversation' else 'Un jeu est déjà en cours dans cette conversation' end;
  end if;
  insert into public.live_sessions(conversation_id, kind, session_id, game, host) values (p_conv, p_kind, left(p_session, 40), left(p_game, 40), auth.uid()) returning id into v;
  return v;
end $$;

create or replace function public.live_beat(p_session text)
returns void language sql security definer set search_path = public as $$
  update public.live_sessions set beat_at = now() where session_id = p_session and host = auth.uid() and ended_at is null
$$;

create or replace function public.live_end(p_session text)
returns void language sql security definer set search_path = public as $$
  update public.live_sessions set ended_at = now() where session_id = p_session and (host = auth.uid() or public.is_staff('moderator')) and ended_at is null
$$;

create or replace function public.live_list(p_conv uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'session', l.session_id, 'game', l.game, 'host', l.host,
      'host_name', (select username from public.profiles where id = l.host), 'started_at', l.started_at) order by l.kind)
    from public.live_sessions l where l.conversation_id = p_conv and l.ended_at is null and l.beat_at > now() - interval '90 seconds'), '[]'::jsonb);
end $$;
grant execute on function public.live_start(uuid, text, text, text), public.live_beat(text), public.live_end(text), public.live_list(uuid) to authenticated;

-- ---------- 3) Messages : modifier (5 min), supprimer pour tous (15 min), masquer pour soi ----------
alter table public.messages add column if not exists edited_at timestamptz;
create table if not exists public.message_hidden (
  user_id uuid not null references public.profiles(id) on delete cascade,
  message_id bigint not null references public.messages(id) on delete cascade,
  primary key (user_id, message_id)
);
alter table public.message_hidden enable row level security;
drop policy if exists mh_sel on public.message_hidden;
create policy mh_sel on public.message_hidden for select to authenticated using (user_id = auth.uid());
grant select on public.message_hidden to authenticated;

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    public.is_member(conversation_id)
    and (expires_at is null or expires_at > now())
    and (whisper_to is null or whisper_to = auth.uid() or sender_id = auth.uid())
    and not exists(select 1 from public.message_hidden h where h.message_id = messages.id and h.user_id = auth.uid())
    and created_at > coalesce(
      (select cm.cleared_at from public.conversation_members cm
        where cm.conversation_id = messages.conversation_id and cm.user_id = auth.uid()),
      '-infinity'::timestamptz)
  );

create or replace function public.msg_delete_all(p_msg bigint)
returns void language plpgsql security definer set search_path = public as $$
declare m public.messages;
begin
  select * into m from public.messages where id = p_msg;
  if not found then raise exception 'Message introuvable'; end if;
  if m.sender_id <> auth.uid() then raise exception 'Vous ne pouvez supprimer que vos messages'; end if;
  if m.kind = 'system' then raise exception 'Message système'; end if;
  if m.created_at < now() - interval '15 minutes' then raise exception 'Suppression possible pendant 15 minutes seulement'; end if;
  delete from public.messages where id = p_msg;
end $$;

create or replace function public.msg_hide(p_msg bigint)
returns void language plpgsql security definer set search_path = public as $$
declare m public.messages;
begin
  select * into m from public.messages where id = p_msg;
  if not found then raise exception 'Message introuvable'; end if;
  if not public.is_member(m.conversation_id) then raise exception 'Accès refusé'; end if;
  insert into public.message_hidden(user_id, message_id) values (auth.uid(), p_msg) on conflict do nothing;
end $$;

create or replace function public.msg_edit(p_msg bigint, p_body text)
returns public.messages language plpgsql security definer set search_path = public as $$
declare m public.messages;
begin
  select * into m from public.messages where id = p_msg for update;
  if not found then raise exception 'Message introuvable'; end if;
  if m.sender_id <> auth.uid() then raise exception 'Vous ne pouvez modifier que vos messages'; end if;
  if m.kind <> 'text' then raise exception 'Seuls les messages texte se modifient'; end if;
  if m.created_at < now() - interval '5 minutes' then raise exception 'Modification possible pendant 5 minutes seulement'; end if;
  if coalesce(trim(p_body), '') = '' or char_length(p_body) > 20000 then raise exception 'Message invalide'; end if;
  update public.messages set body = p_body, edited_at = now() where id = p_msg returning * into m;
  return m;
end $$;
grant execute on function public.msg_delete_all(bigint), public.msg_hide(bigint), public.msg_edit(bigint, text) to authenticated;
do $$ begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime set (publish = 'insert, update, delete'); exception when others then null; end;
  end if;
end $$;

-- dernière connexion à jour (rafraîchissement sans recharger tout le profil)
create or replace function public.profiles_seen(p_ids uuid[])
returns table (id uuid, last_seen timestamptz) language sql security definer stable set search_path = public as $$
  select p.id, p.last_seen from public.profiles p where p.id = any(p_ids)
$$;
grant execute on function public.profiles_seen(uuid[]) to authenticated;

-- ---------- 4) LibonBOT : !clear et !del msgn:[nombre] ----------
create or replace function public.libon_clear(p_conv uuid, p_n int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if (select kind from public.conversations where id = p_conv) <> 'group' then raise exception 'LibonBOT agit dans les groupes'; end if;
  if not public.has_cmd_right(p_conv) then raise exception 'Vous n''avez pas le droit d''utiliser les commandes de LibonBOT'; end if;
  if p_n is null then
    delete from public.messages where conversation_id = p_conv; get diagnostics v_n = row_count;
  else
    if p_n < 1 or p_n > 500 then raise exception 'Nombre invalide (1 à 500)'; end if;
    delete from public.messages where id in (select id from public.messages where conversation_id = p_conv order by id desc limit p_n); get diagnostics v_n = row_count;
  end if;
  perform public.libon_log(p_conv, auth.uid(), case when p_n is null then 'chat vidé' else 'messages supprimés' end, v_n::text);
  return jsonb_build_object('ok', true, 'n', v_n);
end $$;
grant execute on function public.libon_clear(uuid, int) to authenticated;

-- ---------- 5) Jeux et polices propres à un groupe ----------
-- analyse Ciffron d'un texte (HTML/JS) avec les règles du serveur
create or replace function public.cif_scan_text(p_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_lines text[] := string_to_array(coalesce(p_text, ''), E'\n'); i int; v_out jsonb := '[]'::jsonb;
begin
  for r in select * from public.ciffron_rules where enabled and (files = '*' or files like '%js%') loop
    for i in 1 .. least(coalesce(array_length(v_lines, 1), 0), 20000) loop
      continue when not (case when r.fl like '%i%' then v_lines[i] ~* r.pat else v_lines[i] ~ r.pat end);
      continue when exists(select 1 from public.ciffron_allow a where a.rule = r.id and a.bot_id is null);
      v_out := v_out || jsonb_build_object('line', i, 'text', left(v_lines[i], 200), 'rule', r.id, 'reason', r.reason);
      if jsonb_array_length(v_out) >= 40 then return v_out; end if;
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function public.cif_scan_text(text) from public, anon, authenticated;

create table if not exists public.group_games (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  num int not null,                                  -- numéro visible (1, 2, 3…) propre au groupe
  title text not null check (char_length(title) between 1 and 40),
  html text not null check (char_length(html) <= 400000),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (conversation_id, num)
);
alter table public.group_games enable row level security;
drop policy if exists gg_sel on public.group_games;
create policy gg_sel on public.group_games for select to authenticated using (public.is_member(conversation_id));
revoke select on public.group_games from authenticated;
grant select (id, conversation_id, num, title, created_at) on public.group_games to authenticated;

create or replace function public.group_game_add(p_conv uuid, p_title text, p_html text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_num int; v_f jsonb;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if (select kind from public.conversations where id = p_conv) <> 'group' then raise exception 'Réservé aux groupes'; end if;
  if not public.has_cmd_right(p_conv) then raise exception 'Vous n''avez pas le droit d''utiliser les commandes de LibonBOT'; end if;
  p_title := trim(coalesce(p_title, ''));
  if char_length(p_title) < 1 or char_length(p_title) > 40 then raise exception 'Titre invalide (1 à 40 caractères)'; end if;
  if char_length(coalesce(p_html, '')) < 20 or char_length(p_html) > 400000 then raise exception 'Fichier HTML invalide (400 Ko maximum)'; end if;
  if (select count(*) from public.group_games where conversation_id = p_conv) >= 20 then raise exception 'Maximum 20 jeux par groupe'; end if;
  v_f := public.cif_scan_text(p_html);
  if jsonb_array_length(v_f) > 0 then
    perform public.libon_log(p_conv, auth.uid(), 'jeu refusé par Ciffron', left(p_title, 60));
    return jsonb_build_object('ok', false, 'findings', v_f);
  end if;
  select coalesce(max(num), 0) + 1 into v_num from public.group_games where conversation_id = p_conv;
  insert into public.group_games(conversation_id, num, title, html, created_by) values (p_conv, v_num, p_title, p_html, auth.uid());
  perform public.libon_log(p_conv, auth.uid(), 'jeu ajouté', '#' || v_num || ' ' || left(p_title, 60));
  return jsonb_build_object('ok', true, 'num', v_num);
end $$;

create or replace function public.group_game_get(p_conv uuid, p_num int)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare g public.group_games;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into g from public.group_games where conversation_id = p_conv and num = p_num;
  if not found then raise exception 'Jeu introuvable'; end if;
  return jsonb_build_object('num', g.num, 'title', g.title, 'html', g.html);
end $$;

create or replace function public.group_game_list(p_conv uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('num', num, 'title', title) order by num) from public.group_games where conversation_id = p_conv), '[]'::jsonb);
end $$;

create or replace function public.group_game_del(p_conv uuid, p_num int)
returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not public.has_cmd_right(p_conv) then raise exception 'Vous n''avez pas le droit d''utiliser les commandes de LibonBOT'; end if;
  delete from public.group_games where conversation_id = p_conv and num = p_num returning title into t;
  if t is null then raise exception 'Jeu introuvable'; end if;
  perform public.libon_log(p_conv, auth.uid(), 'jeu supprimé', '#' || p_num || ' ' || left(t, 60));
  return t;
end $$;

create table if not exists public.group_fonts (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9 _-]{1,30}$'),
  data_b64 text not null check (char_length(data_b64) <= 2000000),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (conversation_id, name)
);
alter table public.group_fonts enable row level security;

create or replace function public.group_font_add(p_conv uuid, p_name text, p_b64 text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not public.has_cmd_right(p_conv) then raise exception 'Vous n''avez pas le droit d''utiliser les commandes de LibonBOT'; end if;
  if (select count(*) from public.group_fonts where conversation_id = p_conv) >= 10 then raise exception 'Maximum 10 polices par groupe'; end if;
  -- signature TrueType (00 01 00 00) ou OpenType (OTTO)
  if left(p_b64, 6) not in ('AAEAAA', 'T1RUTw') then raise exception 'Ce fichier n''est pas une police .ttf ou .otf'; end if;
  insert into public.group_fonts(conversation_id, name, data_b64, created_by) values (p_conv, trim(p_name), p_b64, auth.uid())
  on conflict (conversation_id, name) do update set data_b64 = excluded.data_b64, created_by = auth.uid(), created_at = now();
  perform public.libon_log(p_conv, auth.uid(), 'police ajoutée', left(trim(p_name), 30));
end $$;

create or replace function public.group_font_list(p_conv uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', name, 'data', data_b64) order by name) from public.group_fonts where conversation_id = p_conv), '[]'::jsonb);
end $$;
grant execute on function public.group_game_add(uuid, text, text), public.group_game_get(uuid, int), public.group_game_list(uuid),
  public.group_game_del(uuid, int), public.group_font_add(uuid, text, text), public.group_font_list(uuid) to authenticated;
