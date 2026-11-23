-- Lot 15 : correctifs (additif). Dépend de patch_systeme.sql et patch_droits.sql.

-- ---------- connexion des comptes officiels : GoTrue refuse les colonnes de jetons à NULL (erreur 500) ----------
update auth.users set
  confirmation_token = coalesce(confirmation_token, ''), recovery_token = coalesce(recovery_token, ''),
  email_change_token_new = coalesce(email_change_token_new, ''), email_change = coalesce(email_change, ''),
  email_change_token_current = coalesce(email_change_token_current, ''), phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''), reauthentication_token = coalesce(reauthentication_token, '')
where id in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002');
update auth.identities set provider_id = (select email from auth.users u where u.id = auth.identities.user_id),
  identity_data = identity_data || jsonb_build_object('email_verified', true)
where user_id in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002') and provider = 'email';

-- ---------- signalement : tous les messages, sans plafond de 50 ----------
create or replace function public.report_create(p_conv uuid, p_kind text, p_target text, p_reason text, p_snapshot jsonb default '[]'::jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare r public.reports; c record;
begin
  if auth.uid() is null or not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  perform public.rate_ok('report:' || auth.uid()::text, 10, 3600);
  if p_kind not in ('group','message') then raise exception 'Type invalide'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Expliquez la raison (5 caractères minimum)'; end if;
  if jsonb_typeof(p_snapshot) <> 'array' or jsonb_array_length(p_snapshot) > 2000 or length(p_snapshot::text) > 1500000 then raise exception 'Sélection trop longue'; end if;
  select num, coalesce(name, 'Discussion') as nm into c from public.conversations where id = p_conv;
  insert into public.reports(kind, reporter_id, reporter_name, conversation_id, conv_num, conv_name, target_name, reason, snapshot)
    values (p_kind, auth.uid(), (select username from public.profiles where id = auth.uid()), p_conv, c.num, c.nm, nullif(trim(coalesce(p_target,'')), ''), left(p_reason, 1000), p_snapshot) returning * into r;
  return r.ref;
end $$;

-- ---------- lecture de la conversation signalée : pièces jointes consultables ----------
create or replace function public.report_conv_view(p_ref text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.reports; m text;
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  select * into r from public.reports where ref = p_ref;
  if not found or r.conversation_id is null then raise exception 'Signalement introuvable'; end if;
  select mode into m from public.conversations where id = r.conversation_id;
  if m = 'e2e' then raise exception 'Conversation chiffrée de bout en bout : seule la sélection du signalement est lisible'; end if;
  perform public.log_admin('signalement_lecture', p_ref, jsonb_build_object('conv', r.conv_num));
  return coalesce((select jsonb_agg(jsonb_build_object('n', q.id, 'from', coalesce(p.username, '(supprimé)'), 'kind', q.kind,
      'body', case when q.kind = 'text' or q.body ~ '^https://' then q.body end, 'media', q.media_path, 'at', q.created_at) order by q.id)
    from (select * from public.messages where conversation_id = r.conversation_id and whisper_to is null order by id desc limit 500) q left join public.profiles p on p.id = q.sender_id), '[]'::jsonb);
end $$;

-- ---------- annonces : plus de limite de longueur ----------
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.world_messages'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ 'char_length' loop
    execute format('alter table public.world_messages drop constraint %I', c.conname);
  end loop;
end $$;

-- ===== Cadres : destinataires (tous / personnes précises / boutique) =====
alter table public.frame_defs add column if not exists audience text not null default 'shop';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'frame_defs_audience_chk') then
    alter table public.frame_defs add constraint frame_defs_audience_chk check (audience in ('shop','all','list'));
  end if;
end $$;
create table if not exists public.frame_grants (
  frame_code text not null references public.frame_defs(code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (frame_code, user_id)
);
alter table public.frame_grants enable row level security;
revoke all on public.frame_grants from anon, authenticated;

create or replace function public._frame_ok(p_user uuid, p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.frame_defs f where f.code = p_code and (
      f.audience = 'all'
      or (f.audience = 'list' and exists(select 1 from public.frame_grants g where g.frame_code = f.code and g.user_id = p_user))
      or exists(select 1 from public.inventory i where i.user_id = p_user and i.code = 'frame_' || f.cat)))
$$;
revoke all on function public._frame_ok(uuid, text) from public, anon, authenticated;

-- cadres utilisables par moi (pour le sélecteur), hors achat de passe
create or replace function public.frames_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(f.code), '[]'::jsonb) from public.frame_defs f
  where auth.uid() is not null and (f.audience = 'all' or (f.audience = 'list' and exists(select 1 from public.frame_grants g where g.frame_code = f.code and g.user_id = auth.uid())))
$$;

-- le commandant décide : tous, personnes précises, ou boutique seulement
create or replace function public.frame_audience(p_code text, p_mode text, p_users text[] default '{}', p_revoke boolean default false) returns integer language plpgsql security definer set search_path = public as $$
declare u text; uid uuid; n int := 0; fr public.frame_defs;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select * into fr from public.frame_defs where code = p_code;
  if not found then raise exception 'Cadre inconnu'; end if;
  if p_mode not in ('shop','all','list') then raise exception 'Destinataires inconnus'; end if;
  perform public.rate_ok('frame_aud', 60, 3600);
  if p_mode = 'list' then
    foreach u in array coalesce(p_users, '{}') loop
      select id into uid from public.profiles where lower(username) = lower(btrim(ltrim(u, '@')));
      if uid is null then raise exception 'Utilisateur introuvable : %', u; end if;
      if p_revoke then
        delete from public.frame_grants where frame_code = p_code and user_id = uid;
        update public.profile_ext set photo_frame = null where user_id = uid and photo_frame = p_code and not public._frame_ok(uid, p_code);
        update public.profile_ext set profile_frame = null where user_id = uid and profile_frame = p_code and not public._frame_ok(uid, p_code);
      else
        insert into public.frame_grants(frame_code, user_id) values (p_code, uid) on conflict do nothing;
        perform public.sys_notify(uid, 'Le commandant vous a décerné le cadre « ' || fr.name || ' ». Équipez-le dans Boutique > Inventaire.');
      end if;
      n := n + 1;
    end loop;
  end if;
  update public.frame_defs set audience = p_mode where code = p_code;
  if p_mode = 'shop' then
    update public.profile_ext set photo_frame = null where photo_frame = p_code and not public._frame_ok(user_id, p_code);
    update public.profile_ext set profile_frame = null where profile_frame = p_code and not public._frame_ok(user_id, p_code);
  end if;
  perform public.log_admin('cadre_destinataires', p_code, jsonb_build_object('mode', p_mode, 'n', n, 'retrait', p_revoke));
  return n;
end $$;
revoke all on function public.frames_mine(), public.frame_audience(text,text,text[],boolean) from public, anon;
grant execute on function public.frames_mine(), public.frame_audience(text,text,text[],boolean) to authenticated;

-- cosmetic_set : accepte les cadres décernés
create or replace function public.cosmetic_set(p_field text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_value,'')), ''); f public.frame_defs; need text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('cosm', 120, 3600);
  insert into public.profile_ext(user_id) values (auth.uid()) on conflict do nothing;
  if p_field in ('name_color') then need := 'name_color';
  elsif p_field in ('profile_color','profile_text_color') then need := 'profile_color';
  elsif p_field = 'profile_bg' then need := 'profile_bg';
  elsif p_field = 'credits_name' then need := 'credits_name';
  elsif p_field in ('photo_frame','profile_frame') then need := null;
  else raise exception 'Réglage inconnu'; end if;
  if v is not null and need is not null and not exists(select 1 from public.inventory where user_id = auth.uid() and code = need) then raise exception 'Article non possédé'; end if;
  if p_field in ('photo_frame','profile_frame') and v is not null then
    select * into f from public.frame_defs where code = v;
    if not found or (p_field = 'photo_frame' and f.cat not in ('photo','photo_anim')) or (p_field = 'profile_frame' and f.cat not in ('profile','profile_anim')) then raise exception 'Cadre inconnu'; end if;
    if not public._frame_ok(auth.uid(), v) then raise exception 'Article non possédé'; end if;
  end if;
  execute format('update public.profile_ext set %I = $1 where user_id = $2', p_field) using v, auth.uid();
end $$;

create or replace function public.frames_img() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'img', img, 'name', name, 'custom', custom, 'audience', audience) order by cat, sort), '[]'::jsonb)
  from public.frame_defs where img is not null
$$;

-- ===== Statistiques de jeux enrichies =====
alter table public.game_stats add column if not exists losses int not null default 0;
alter table public.game_stats add column if not exists lose_secs bigint not null default 0;
alter table public.game_stats add column if not exists best_secs int;
alter table public.game_stats add column if not exists best_score bigint;
alter table public.game_stats add column if not exists streak int not null default 0;
alter table public.game_stats add column if not exists best_streak int not null default 0;
alter table public.game_stats add column if not exists last_played timestamptz;

drop function if exists public.record_game(text, boolean, int);
create or replace function public.record_game(p_game text, p_won boolean, p_secs int, p_score bigint default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); s int := greatest(0, least(coalesce(p_secs, 0), 86400)); sc bigint := case when p_score is null then null else greatest(0, least(p_score, 1000000000)) end;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if p_game is null or p_game !~ '^[a-z0-9_]{2,24}$' then raise exception 'Jeu invalide'; end if;
  perform public.rate_ok('rec_game', 400, 3600);
  insert into public.game_stats (user_id, game, played, wins, win_secs, losses, lose_secs, best_secs, best_score, streak, best_streak, last_played)
  values (v_me, p_game, 1, case when p_won then 1 else 0 end, case when p_won then s else 0 end,
          case when p_won then 0 else 1 end, case when p_won then 0 else s end,
          case when p_won and s > 0 then s end, sc, case when p_won then 1 else 0 end, case when p_won then 1 else 0 end, now())
  on conflict (user_id, game) do update
    set played = game_stats.played + 1,
        wins = game_stats.wins + case when p_won then 1 else 0 end,
        win_secs = game_stats.win_secs + case when p_won then s else 0 end,
        losses = game_stats.losses + case when p_won then 0 else 1 end,
        lose_secs = game_stats.lose_secs + case when p_won then 0 else s end,
        best_secs = case when p_won and s > 0 then least(coalesce(game_stats.best_secs, s), s) else game_stats.best_secs end,
        best_score = case when sc is null then game_stats.best_score else greatest(coalesce(game_stats.best_score, 0), sc) end,
        streak = case when p_won then game_stats.streak + 1 else 0 end,
        best_streak = greatest(game_stats.best_streak, case when p_won then game_stats.streak + 1 else 0 end),
        last_played = now(),
        updated_at = now();
end $$;
revoke all on function public.record_game(text,boolean,int,bigint) from public, anon;
grant execute on function public.record_game(text,boolean,int,bigint) to authenticated;

-- stats_me : plus d'infos de profil
create or replace function public.stats_me() returns jsonb language plpgsql security definer stable set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not public._owns('export_stats') then raise exception 'Article non possédé'; end if;
  perform public._need_right(me, 'export');
  return jsonb_build_object(
    'messages_total', (select count(*) from public.messages where sender_id = me),
    'par_jour', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d) from (select (created_at at time zone 'America/Toronto')::date d, count(*) n from public.messages where sender_id = me and created_at > now() - interval '30 days' group by 1) q), '[]'::jsonb),
    'par_conv', coalesce((select jsonb_agg(jsonb_build_object('conv', conv, 'n', n) order by n desc) from (select conversation_id conv, count(*) n from public.messages where sender_id = me group by 1 order by 2 desc limit 5) q), '[]'::jsonb),
    'jeux', coalesce((select jsonb_agg(to_jsonb(g) - 'user_id') from public.game_stats g where g.user_id = me), '[]'::jsonb),
    'profil', jsonb_build_object(
      'membre_depuis', (select created_at from public.profiles where id = me),
      'conversations', (select count(*) from public.conversation_members where user_id = me),
      'jours_actifs', (select count(distinct (created_at at time zone 'America/Toronto')::date) from public.messages where sender_id = me),
      'premier_message', (select min(created_at) from public.messages where sender_id = me),
      'jetons', (select balance from public.wallets where user_id = me),
      'medailles', (select medals from public.wallets where user_id = me)));
end $$;
