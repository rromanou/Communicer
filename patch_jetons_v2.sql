-- ============================================================================
-- Communicer! — patch_jetons_v2.sql (additif, relançable) : appels et jeux en direct (fin automatique),
-- jetons v2 (parrainage, quêtes, badges, cadres, boutique, échange Romanomoney, bogues) et durcissement de la sécurité.
-- À exécuter après patch_hierarchie.sql. Remplace patch_jetons.sql (peut avoir été exécuté ou non).
-- ============================================================================

-- ---------- A) Sessions en direct : membres, hôte transféré, fin immédiate quand il ne reste personne ----------
create table if not exists public.live_members (
  session_id text not null, user_id uuid not null references public.profiles(id) on delete cascade,
  spec boolean not null default false, joined_at timestamptz not null default now(), beat_at timestamptz not null default now(),
  primary key (session_id, user_id)
);
alter table public.live_members enable row level security;

create or replace function public.live_sweep() returns void language sql security definer set search_path = public as $$
  update public.live_sessions set ended_at = now() where ended_at is null and beat_at < now() - interval '35 seconds';
  delete from public.live_members m where not exists(select 1 from public.live_sessions l where l.session_id = m.session_id and l.ended_at is null);
$$;
revoke all on function public.live_sweep() from public, anon, authenticated;

create or replace function public.live_start(p_conv uuid, p_kind text, p_session text, p_game text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if p_kind not in ('call','game') then raise exception 'Type invalide'; end if;
  perform public.live_sweep();
  -- l'ancienne session de la même personne (page fermée, retour) est terminée : elle recommence proprement
  update public.live_sessions set ended_at = now() where conversation_id = p_conv and kind = p_kind and ended_at is null
    and (host = auth.uid() or exists(select 1 from public.live_members m where m.session_id = live_sessions.session_id and m.user_id = auth.uid() and not m.spec));
  if exists(select 1 from public.live_sessions where conversation_id = p_conv and kind = p_kind and ended_at is null) then
    raise exception '%', case p_kind when 'call' then 'Un appel est déjà en cours dans cette conversation' else 'Un jeu est déjà en cours dans cette conversation' end;
  end if;
  insert into public.live_sessions(conversation_id, kind, session_id, game, host) values (p_conv, p_kind, left(p_session, 40), left(p_game, 40), auth.uid()) returning id into v;
  insert into public.live_members(session_id, user_id) values (left(p_session, 40), auth.uid()) on conflict do nothing;
  return v;
end $$;

create or replace function public.live_join(p_session text, p_spec boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare l public.live_sessions;
begin
  select * into l from public.live_sessions where session_id = p_session and ended_at is null;
  if not found then raise exception 'Session terminée'; end if;
  if not public.is_member(l.conversation_id) then raise exception 'Accès refusé'; end if;
  insert into public.live_members(session_id, user_id, spec) values (p_session, auth.uid(), coalesce(p_spec, false))
  on conflict (session_id, user_id) do update set spec = excluded.spec, beat_at = now();
  if not coalesce(p_spec, false) then update public.live_sessions set beat_at = now() where session_id = p_session; end if;
end $$;

create or replace function public.live_beat(p_session text)
returns void language plpgsql security definer set search_path = public as $$
declare sp boolean;
begin
  update public.live_members set beat_at = now() where session_id = p_session and user_id = auth.uid() returning spec into sp;
  if found and not sp then update public.live_sessions set beat_at = now() where session_id = p_session and ended_at is null; end if;
end $$;

create or replace function public.live_leave(p_session text)
returns text language plpgsql security definer set search_path = public as $$
declare l public.live_sessions; nh uuid; me_spec boolean;
begin
  select spec into me_spec from public.live_members where session_id = p_session and user_id = auth.uid();
  delete from public.live_members where session_id = p_session and user_id = auth.uid();
  select * into l from public.live_sessions where session_id = p_session and ended_at is null;
  if not found then return 'ended'; end if;
  if coalesce(me_spec, false) then return 'left'; end if;
  select user_id into nh from public.live_members where session_id = p_session and not spec order by joined_at limit 1;
  if nh is null then update public.live_sessions set ended_at = now() where session_id = p_session; return 'ended'; end if;
  if l.host = auth.uid() then update public.live_sessions set host = nh where session_id = p_session; end if;
  return 'left';
end $$;

create or replace function public.live_end(p_session text)
returns void language sql security definer set search_path = public as $$
  update public.live_sessions set ended_at = now() where session_id = p_session and (host = auth.uid() or public.is_staff('moderator')) and ended_at is null
$$;

create or replace function public.live_list(p_conv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  perform public.live_sweep();
  return coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'session', l.session_id, 'game', l.game, 'host', l.host,
      'host_name', (select username from public.profiles where id = l.host), 'started_at', l.started_at,
      'members', (select count(*) from public.live_members m where m.session_id = l.session_id and not m.spec)) order by l.kind)
    from public.live_sessions l where l.conversation_id = p_conv and l.ended_at is null), '[]'::jsonb);
end $$;
grant execute on function public.live_start(uuid, text, text, text), public.live_join(text, boolean), public.live_beat(text), public.live_leave(text), public.live_end(text), public.live_list(uuid) to authenticated;
revoke execute on function public.live_start(uuid, text, text, text), public.live_join(text, boolean), public.live_beat(text), public.live_leave(text), public.live_end(text), public.live_list(uuid) from anon, public;

-- ---------- B) Jetons v2 : portefeuille (demi-jetons), journal, configuration ----------
create table if not exists public.wallets (user_id uuid primary key references public.profiles(id) on delete cascade, balance numeric(14,1) not null default 0 check (balance >= 0), updated_at timestamptz not null default now());
alter table public.wallets alter column balance type numeric(14,1);
create table if not exists public.token_log (id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade,
  delta numeric(14,1) not null, reason text not null, by_id uuid references public.profiles(id) on delete set null, at timestamptz not null default now());
alter table public.token_log alter column delta type numeric(14,1);
create index if not exists token_log_user on public.token_log(user_id, id desc);
-- le journal des jetons ne se modifie jamais
drop trigger if exists token_log_imm on public.token_log;
create or replace function public.trg_tok_imm() returns trigger language plpgsql as $$
begin if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if; raise exception 'Journal immuable'; end $$;
create trigger token_log_imm before update or delete on public.token_log for each row execute function public.trg_tok_imm();
create table if not exists public.daily_claims (user_id uuid not null references public.profiles(id) on delete cascade, day date not null, primary key (user_id, day));
create table if not exists public.daily_state (user_id uuid primary key references public.profiles(id) on delete cascade, last_at timestamptz not null);
create table if not exists public.tok_cfg (k text primary key, v text not null);
do $$ declare t text; begin foreach t in array array['wallets','token_log','daily_claims','daily_state','tok_cfg'] loop execute format('alter table public.%I enable row level security', t); end loop; end $$;
insert into public.tok_cfg(k, v) values ('release_date', '2026-10-29'), ('xchg_unit_tokens', '0.5'), ('xchg_month_cap', '23'),
  ('ref_referrer', '350'), ('ref_referred', '125'), ('win_reward', '0.5'), ('bug_reward', '55'), ('daily_reward', '2'), ('quest_reward', '4'),
  ('pack_price_cad', '119.99'), ('pack_tokens', '85000')
on conflict (k) do nothing;
create or replace function public.cfg_n(p_k text) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select v::numeric from public.tok_cfg where k = p_k), 0) $$;
revoke all on function public.cfg_n(text) from public, anon, authenticated;

-- anciennes signatures (patch10) remplacées
drop function if exists public.tok_add(uuid, int, text, uuid);
drop function if exists public.quest_value(uuid, public.quest_defs);
drop function if exists public.quest_claim(text);
drop function if exists public.shop_buy(text);
drop function if exists public.shop_equip(text, text);
drop function if exists public.pe_owned();
drop function if exists public.admin_item(text, text, boolean);
drop function if exists public.admin_wallet(text);
create or replace function public.tok_add(p_user uuid, p_delta numeric, p_reason text, p_by uuid default null)
returns numeric language plpgsql security definer set search_path = public as $$
declare b numeric;
begin
  insert into public.wallets(user_id, balance) values (p_user, 0) on conflict do nothing;
  update public.wallets set balance = balance + p_delta, updated_at = now() where user_id = p_user returning balance into b;
  insert into public.token_log(user_id, delta, reason, by_id) values (p_user, p_delta, left(p_reason, 200), p_by);
  return b;
end $$;
revoke all on function public.tok_add(uuid, numeric, text, uuid) from public, anon, authenticated;
create or replace function public.period_start(p text) returns date language sql stable as $$
  select case when p = 'week' then public.staff_week() else public.staff_today() end $$;

-- limiteur simple : p_max appels par p_secs secondes, par utilisateur et par clé
create table if not exists public.rate_hits (user_id uuid, k text, at timestamptz not null default now());
create index if not exists rate_hits_idx on public.rate_hits(user_id, k, at);
create table if not exists public.rate_hits_ip (ip text, k text, at timestamptz not null default now());
create index if not exists rate_hits_ip_idx on public.rate_hits_ip(ip, k, at);
alter table public.rate_hits enable row level security; alter table public.rate_hits_ip enable row level security;
create or replace function public.rate_ok(p_k text, p_max int, p_secs int) returns void language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.rate_hits where at < now() - interval '2 days';
  select count(*) into n from public.rate_hits where user_id = auth.uid() and k = p_k and at > now() - make_interval(secs => p_secs);
  if n >= p_max then raise exception 'Trop de demandes, réessayez plus tard'; end if;
  insert into public.rate_hits(user_id, k) values (auth.uid(), p_k);
end $$;
revoke all on function public.rate_ok(text, int, int) from public, anon, authenticated;
create or replace function public.rate_ok_ip(p_k text, p_max int, p_secs int) returns void language plpgsql security definer set search_path = public as $$
declare n int; v_ip text := coalesce(public.req_ip(), 'inconnue');
begin
  delete from public.rate_hits_ip where at < now() - interval '2 days';
  select count(*) into n from public.rate_hits_ip where rate_hits_ip.ip = v_ip and rate_hits_ip.k = p_k and at > now() - make_interval(secs => p_secs);
  if n >= p_max then raise exception 'Trop de demandes, réessayez plus tard'; end if;
  insert into public.rate_hits_ip(ip, k) values (v_ip, p_k);
end $$;
revoke all on function public.rate_ok_ip(text, int, int) from public, anon, authenticated;

-- ---------- Victoires aux jeux de groupe (0,5 jeton) ----------
alter table public.live_sessions add column if not exists peak int not null default 1;
create or replace function public.live_peak(p_session text) returns void language sql security definer set search_path = public as $$
  update public.live_sessions set peak = greatest(peak, (select count(*) from public.live_members where session_id = p_session and not spec)::int) where session_id = p_session
$$;
revoke all on function public.live_peak(text) from public, anon, authenticated;
create or replace function public.live_join(p_session text, p_spec boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare l public.live_sessions;
begin
  select * into l from public.live_sessions where session_id = p_session and ended_at is null;
  if not found then raise exception 'Session terminée'; end if;
  if not public.is_member(l.conversation_id) then raise exception 'Accès refusé'; end if;
  insert into public.live_members(session_id, user_id, spec) values (p_session, auth.uid(), coalesce(p_spec, false))
  on conflict (session_id, user_id) do update set spec = excluded.spec, beat_at = now();
  if not coalesce(p_spec, false) then update public.live_sessions set beat_at = now() where session_id = p_session; end if;
  perform public.live_peak(p_session);
end $$;

create table if not exists public.game_wins (
  id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade, game text not null check (game ~ '^[a-z0-9_]{2,24}$'),
  session_id text not null, at timestamptz not null default now(), paid boolean not null default false, unique (user_id, session_id)
);
create index if not exists game_wins_user on public.game_wins(user_id, game);
alter table public.game_wins enable row level security;

-- victoire annoncée par le client ; acceptée seulement si : groupe, session réelle terminée ou en cours depuis 30 s, au moins 2 joueurs, une fois par session, 20 par jour
create or replace function public.game_win(p_conv uuid, p_game text, p_session text)
returns numeric language plpgsql security definer set search_path = public as $$
declare l public.live_sessions; paid_today int; r numeric := public.cfg_n('win_reward'); b numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if (select kind from public.conversations where id = p_conv) <> 'group' then return 0; end if;       -- conversations normales : rien
  if p_game !~ '^[a-z0-9_]{2,24}$' then raise exception 'Jeu invalide'; end if;
  perform public.rate_ok('win', 60, 3600);
  select * into l from public.live_sessions where session_id = p_session and conversation_id = p_conv and kind = 'game';
  if not found then return 0; end if;
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

-- ---------- Récompense quotidienne (2 jetons toutes les 12 h, en cliquant sur le solde) ----------
create or replace function public.daily_claim()
returns jsonb language plpgsql security definer set search_path = public as $$
declare last timestamptz; nxt timestamptz; b numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select last_at into last from public.daily_state where user_id = auth.uid() for update;
  if last is not null and last > now() - interval '12 hours' then
    return jsonb_build_object('ok', false, 'next', last + interval '12 hours', 'balance', (select balance from public.wallets where user_id = auth.uid()));
  end if;
  insert into public.daily_state(user_id, last_at) values (auth.uid(), now()) on conflict (user_id) do update set last_at = now();
  b := public.tok_add(auth.uid(), public.cfg_n('daily_reward'), 'récompense quotidienne');
  return jsonb_build_object('ok', true, 'next', now() + interval '12 hours', 'balance', b, 'gain', public.cfg_n('daily_reward'));
end $$;

-- ---------- Quêtes : 3 au hasard par jour, 4 jetons chacune ----------
create table if not exists public.quest_pool (code text primary key, title text not null, kind text not null, target int not null, sort int not null default 0);
create table if not exists public.user_quests (user_id uuid not null references public.profiles(id) on delete cascade, day date not null, code text not null references public.quest_pool(code) on delete cascade,
  claimed boolean not null default false, primary key (user_id, day, code));
alter table public.quest_pool enable row level security; alter table public.user_quests enable row level security;
-- tables de l'ancien système (patch10) : remplacées
create table if not exists public.quest_events (user_id uuid not null references public.profiles(id) on delete cascade, kind text not null, day date not null, n int not null default 0, primary key (user_id, kind, day));
alter table public.quest_events enable row level security;
insert into public.quest_pool(code, title, kind, target, sort) values
 ('msg10', 'Envoyer 10 messages', 'msgs', 10, 1), ('msg30', 'Envoyer 30 messages', 'msgs', 30, 2),
 ('conv1', 'Créer une discussion', 'conv', 1, 3), ('friend1', 'Ajouter un ami', 'friend', 1, 4),
 ('call1', 'Participer à un appel', 'call', 1, 5), ('game1', 'Jouer une partie en groupe', 'game', 1, 6), ('game3', 'Jouer trois parties', 'game', 3, 7),
 ('win1', 'Gagner une partie en groupe', 'win', 1, 8), ('bot1', 'Utiliser une commande de bot', 'bot', 1, 9), ('bot3', 'Utiliser trois commandes de bot', 'bot', 3, 10),
 ('img1', 'Envoyer une image', 'img', 1, 11), ('voice1', 'Envoyer un message vocal', 'voice', 1, 12)
on conflict (code) do update set title = excluded.title, kind = excluded.kind, target = excluded.target, sort = excluded.sort;

create or replace function public.quest_value(p_user uuid, p_kind text, p_day date)
returns int language plpgsql security definer stable set search_path = public as $$
declare s timestamptz := p_day::timestamp at time zone 'America/Toronto'; e timestamptz := (p_day + 1)::timestamp at time zone 'America/Toronto'; v int := 0;
begin
  if p_kind = 'msgs' then select count(*) into v from public.messages where sender_id = p_user and created_at >= s and created_at < e and kind <> 'system';
  elsif p_kind = 'img' then select count(*) into v from public.messages where sender_id = p_user and created_at >= s and created_at < e and kind = 'image';
  elsif p_kind = 'voice' then select count(*) into v from public.messages where sender_id = p_user and created_at >= s and created_at < e and kind = 'voice';
  elsif p_kind = 'conv' then select count(*) into v from public.conversations where created_by = p_user and created_at >= s and created_at < e;
  elsif p_kind = 'friend' then select count(*) into v from public.friendships where status = 'accepted' and (requester = p_user or addressee = p_user) and created_at >= s and created_at < e;
  elsif p_kind = 'win' then select count(*) into v from public.game_wins where user_id = p_user and at >= s and at < e;
  else select coalesce(sum(n), 0) into v from public.quest_events where user_id = p_user and kind = p_kind and day = p_day;
  end if;
  return v;
end $$;
revoke all on function public.quest_value(uuid, text, date) from public, anon, authenticated;

create or replace function public.quests_list()
returns jsonb language plpgsql security definer set search_path = public as $$
declare d date := public.staff_today();
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not exists(select 1 from public.user_quests where user_id = auth.uid() and day = d) then
    insert into public.user_quests(user_id, day, code) select auth.uid(), d, code from public.quest_pool order by random() limit 3 on conflict do nothing;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'title', p.title, 'target', p.target, 'reward', public.cfg_n('quest_reward'),
      'value', least(public.quest_value(auth.uid(), p.kind, d), p.target), 'claimed', u.claimed) order by p.sort)
    from public.user_quests u join public.quest_pool p on p.code = u.code where u.user_id = auth.uid() and u.day = d), '[]'::jsonb);
end $$;
create or replace function public.quest_event(p_kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('game','call','bot') then raise exception 'Événement inconnu'; end if;
  insert into public.quest_events(user_id, kind, day, n) values (auth.uid(), p_kind, public.staff_today(), 1)
  on conflict (user_id, kind, day) do update set n = least(public.quest_events.n + 1, 20);
end $$;
create or replace function public.quest_claim(p_code text)
returns numeric language plpgsql security definer set search_path = public as $$
declare d date := public.staff_today(); p public.quest_pool; u public.user_quests;
begin
  select * into u from public.user_quests where user_id = auth.uid() and day = d and code = p_code for update;
  if not found then raise exception 'Quête introuvable'; end if;
  if u.claimed then raise exception 'Récompense déjà récupérée'; end if;
  select * into p from public.quest_pool where code = p_code;
  if public.quest_value(auth.uid(), p.kind, d) < p.target then raise exception 'Quête non terminée'; end if;
  update public.user_quests set claimed = true where user_id = auth.uid() and day = d and code = p_code;
  return public.tok_add(auth.uid(), public.cfg_n('quest_reward'), 'quête : ' || p.title);
end $$;

-- ---------- Signalement de bogues (55 jetons si l'administrateur approuve) ----------
create table if not exists public.bug_reports (
  id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120), body text not null check (char_length(body) between 10 and 4000),
  status text not null default 'pending' check (status in ('pending','approved','refused')),
  created_at timestamptz not null default now(), decided_by uuid references public.profiles(id) on delete set null, decided_at timestamptz, note text
);
alter table public.bug_reports enable row level security;
create or replace function public.bug_report(p_title text, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if char_length(trim(coalesce(p_title,''))) < 3 or char_length(trim(coalesce(p_body,''))) < 10 then raise exception 'Décrivez le bogue (titre et explication)'; end if;
  perform public.rate_ok('bug', 5, 86400);
  insert into public.bug_reports(user_id, title, body) values (auth.uid(), left(trim(p_title), 120), left(trim(p_body), 4000)) returning id into v;
  return v;
end $$;
create or replace function public.bug_list(p_status text default 'pending')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'user', p.username, 'title', b.title, 'body', b.body, 'status', b.status, 'at', b.created_at) order by b.id desc)
    from (select * from public.bug_reports where p_status = 'all' or status = p_status order by id desc limit 100) b join public.profiles p on p.id = b.user_id), '[]'::jsonb);
end $$;
create or replace function public.bug_review(p_id bigint, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.bug_reports;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select * into b from public.bug_reports where id = p_id for update;
  if not found then raise exception 'Signalement introuvable'; end if;
  if b.status <> 'pending' then raise exception 'Déjà traité'; end if;
  if b.user_id = auth.uid() then raise exception 'Vous ne pouvez pas approuver votre propre signalement'; end if;
  update public.bug_reports set status = case when p_approve then 'approved' else 'refused' end, decided_by = auth.uid(), decided_at = now(), note = left(p_note, 300) where id = p_id;
  if p_approve then
    perform public.tok_add(b.user_id, public.cfg_n('bug_reward'), 'bogue approuvé : ' || left(b.title, 60));
    perform public.badges_check(b.user_id);
  end if;
  perform public.log_admin(case when p_approve then 'bogue_approuve' else 'bogue_refuse' end, (select username from public.profiles where id = b.user_id), jsonb_build_object('id', p_id, 'titre', b.title));
end $$;

-- ---------- C) Parrainage v2 : codes de 5 caractères sensibles à la casse, page d'invitation, contestation ----------
create table if not exists public.referral_codes (user_id uuid primary key references public.profiles(id) on delete cascade, code text not null unique);
alter table public.referral_codes enable row level security;
alter table public.referral_codes drop constraint if exists referral_codes_code_check;
alter table public.referral_codes add constraint referral_codes_code_check check (code ~ '^[a-zA-Z0-9]{5}$');
alter table public.referrals add column if not exists paid boolean not null default false;
alter table public.referrals add column if not exists status text not null default 'no_reward';
alter table public.referrals add column if not exists reason text;
alter table public.referrals add column if not exists rewarded_at timestamptz;
-- anciens parrainages déjà payés par le système précédent : conservés tels quels
update public.referrals set status = 'rewarded', rewarded_at = coalesce(rewarded_at, created_at) where paid and status = 'no_reward';

create table if not exists public.referral_contests (
  id bigint generated always as identity primary key, token text not null unique check (char_length(token) between 16 and 64),
  code text not null, referrer_id uuid references public.profiles(id) on delete set null, user_id uuid references public.profiles(id) on delete set null,
  reason text not null check (char_length(reason) between 5 and 1500), cache jsonb not null default '{}'::jsonb, ip text,
  status text not null default 'pending' check (status in ('pending','approved','refused')),
  created_at timestamptz not null default now(), decided_by uuid references public.profiles(id) on delete set null, decided_at timestamptz, note text
);
alter table public.referral_contests enable row level security;

create or replace function public.rand_code(n int) returns text language plpgsql volatile as $$
declare chars text := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'; r text := ''; i int;
begin for i in 1..n loop r := r || substr(chars, 1 + floor(random() * 62)::int, 1); end loop; return r; end $$;

create or replace function public.referral_code_me()
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int := 0;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select code into c from public.referral_codes where user_id = auth.uid();
  if c is not null then return c; end if;
  loop
    c := public.rand_code(5);
    begin insert into public.referral_codes(user_id, code) values (auth.uid(), c); return c;
    exception when unique_violation then i := i + 1; if i > 30 then raise exception 'Réessayez'; end if; end;
  end loop;
end $$;

-- page d'invitation (visiteur non connecté) : qui parraine ?
create or replace function public.referral_preview(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  perform public.rate_ok_ip('refprev', 60, 600);
  if p_code is null or p_code !~ '^[a-zA-Z0-9]{5}$' then return jsonb_build_object('ok', false); end if;
  select user_id into u from public.referral_codes where code = p_code;
  if u is null then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'username', (select username from public.profiles where id = u), 'nickname', (select nickname from public.profiles where id = u),
    'referrer', public.cfg_n('ref_referrer'), 'referred', public.cfg_n('ref_referred'));
end $$;

-- contestation déposée avant la création du compte (visiteur anonyme) : cache complet + raison
create or replace function public.referral_contest_anon(p_code text, p_token text, p_reason text, p_cache jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  perform public.rate_ok_ip('refcontest', 3, 86400);
  if p_code is null or p_code !~ '^[a-zA-Z0-9]{5}$' then raise exception 'Code invalide'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Expliquez la raison de la contestation'; end if;
  if p_token is null or char_length(p_token) < 16 then raise exception 'Jeton invalide'; end if;
  if octet_length(coalesce(p_cache, '{}'::jsonb)::text) > 300000 then raise exception 'Cache trop volumineux'; end if;
  select user_id into u from public.referral_codes where code = p_code;
  if u is null then raise exception 'Code invalide'; end if;
  insert into public.referral_contests(token, code, referrer_id, reason, cache, ip) values (left(p_token, 64), p_code, u, left(trim(p_reason), 1500), coalesce(p_cache, '{}'::jsonb), public.req_ip())
  on conflict (token) do nothing;
end $$;

create or replace function public.ref_pay(p_ref bigint, p_why text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.referrals;
begin
  select * into r from public.referrals where id = p_ref for update;
  if r.paid then return; end if;
  update public.referrals set paid = true, approved = true, status = 'rewarded', reason = p_why, rewarded_at = now() where id = p_ref;
  perform public.tok_add(r.referrer_id, public.cfg_n('ref_referrer'), 'parrainage : ' || coalesce((select username from public.profiles where id = r.referred_id), '?'));
  perform public.tok_add(r.referred_id, public.cfg_n('ref_referred'), 'bienvenue : parrainé par ' || coalesce((select username from public.profiles where id = r.referrer_id), '?'));
  perform public.badges_check(r.referrer_id);
end $$;
revoke all on function public.ref_pay(bigint, text) from public, anon, authenticated;

-- à l'inscription : lie le parrain, devient ami automatiquement, récompenses si le nouveau compte est propre
create or replace function public.referral_claim(p_code text, p_clean boolean, p_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o uuid; rid bigint; me uuid := auth.uid(); shared boolean; today int; why text; c public.referral_contests;
begin
  if me is null then raise exception 'Non connecté'; end if;
  perform public.register_ip();
  if exists(select 1 from public.referrals where referred_id = me) then return jsonb_build_object('status', (select status from public.referrals where referred_id = me)); end if;
  if (select created_at from public.profiles where id = me) < now() - interval '1 day' then raise exception 'Le code s’utilise à l’inscription'; end if;
  select user_id into o from public.referral_codes where code = p_code;
  if o is null then raise exception 'Code invalide'; end if;
  if o = me then raise exception 'Vous ne pouvez pas utiliser votre propre code'; end if;
  -- ami automatique avec le parrain (dans tous les cas)
  insert into public.friendships(requester, addressee, status) values (o, me, 'accepted') on conflict do nothing;
  update public.friendships set status = 'accepted' where least(requester, addressee) = least(o, me) and greatest(requester, addressee) = greatest(o, me) and status <> 'accepted';
  -- contrôles côté serveur : même connexion que d'autres comptes, cache ancien signalé par le navigateur, plafond du parrain
  select exists(select 1 from public.user_ips a join public.user_ips b on b.ip = a.ip and b.user_id <> a.user_id where a.user_id = me) into shared;
  select count(*) into today from public.referrals where referrer_id = o and paid and rewarded_at > now() - interval '1 day';
  why := case when not coalesce(p_clean, false) then 'old_cache' when shared then 'shared_ip' when today >= 10 then 'cap' else null end;
  insert into public.referrals(referrer_id, referred_id, status, reason) values (o, me, 'no_reward', why) returning id into rid;
  if p_token is not null then
    update public.referral_contests set user_id = me where token = left(p_token, 64) and user_id is null returning * into c;
    if c.id is not null and c.status = 'approved' then perform public.ref_pay(rid, 'contest_approved'); return jsonb_build_object('status', 'rewarded', 'referrer', (select username from public.profiles where id = o)); end if;
    if c.id is not null and c.status = 'pending' then update public.referrals set status = 'contest_pending' where id = rid; return jsonb_build_object('status', 'contest_pending', 'referrer', (select username from public.profiles where id = o)); end if;
  end if;
  if why is null then perform public.ref_pay(rid, 'ok'); return jsonb_build_object('status', 'rewarded', 'referrer', (select username from public.profiles where id = o), 'gain', public.cfg_n('ref_referred')); end if;
  return jsonb_build_object('status', 'no_reward', 'reason', why, 'referrer', (select username from public.profiles where id = o));
end $$;

create or replace function public.referral_status_me()
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce((select jsonb_build_object('status', r.status, 'reason', r.reason, 'referrer', (select username from public.profiles where id = r.referrer_id)) from public.referrals r where r.referred_id = auth.uid()), '{}'::jsonb)
$$;

create or replace function public.contest_list(p_status text default 'pending')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'reason', c.reason, 'at', c.created_at, 'cache', c.cache,
      'user', (select username from public.profiles where id = c.user_id), 'referrer', (select username from public.profiles where id = c.referrer_id)) order by c.id desc)
    from (select * from public.referral_contests where p_status = 'all' or status = p_status order by id desc limit 50) c), '[]'::jsonb);
end $$;
create or replace function public.contest_decide(p_id bigint, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c public.referral_contests; rid bigint;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select * into c from public.referral_contests where id = p_id for update;
  if not found then raise exception 'Contestation introuvable'; end if;
  if c.status <> 'pending' then raise exception 'Déjà traitée'; end if;
  if c.user_id = auth.uid() or c.referrer_id = auth.uid() then raise exception 'Vous ne pouvez pas juger votre propre contestation'; end if;
  update public.referral_contests set status = case when p_approve then 'approved' else 'refused' end, decided_by = auth.uid(), decided_at = now(), note = left(p_note, 300) where id = p_id;
  if c.user_id is not null then
    select id into rid from public.referrals where referred_id = c.user_id;
    if rid is not null then
      if p_approve then perform public.ref_pay(rid, 'contest_approved');
      else update public.referrals set status = 'contest_refused' where id = rid and not paid; end if;
    end if;
  end if;
  perform public.log_admin(case when p_approve then 'contestation_acceptee' else 'contestation_refusee' end, coalesce((select username from public.profiles where id = c.user_id), '(compte à venir)'), jsonb_build_object('id', p_id));
end $$;


-- contestation après inscription (récompense refusée à l'inscription : connexion partagée, etc.)
create or replace function public.referral_contest_me(p_reason text, p_cache jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare r public.referrals;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('refcontest', 3, 86400);
  select * into r from public.referrals where referred_id = auth.uid() for update;
  if not found or r.status <> 'no_reward' then raise exception 'Aucune récompense à contester'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Expliquez la raison de la contestation'; end if;
  if octet_length(coalesce(p_cache, '{}'::jsonb)::text) > 300000 then raise exception 'Cache trop volumineux'; end if;
  insert into public.referral_contests(token, code, referrer_id, user_id, reason, cache, ip)
  values (public.rand_code(32), coalesce((select code from public.referral_codes where user_id = r.referrer_id), '-----'), r.referrer_id, auth.uid(), left(trim(p_reason), 1500), coalesce(p_cache, '{}'::jsonb), public.req_ip());
  update public.referrals set status = 'contest_pending' where id = r.id;
end $$;

-- ancienne fonction : plus de saisie manuelle de code après coup
drop function if exists public.referral_use(text);
drop function if exists public.referral_check();

-- ---------- D) Boutique v2, badges, cadres, couleurs, épinglage, emojis premium ----------
create table if not exists public.shop_items (code text primary key, kind text not null, name text not null, descr text not null default '', price numeric(14,1), sort int not null default 0);
create table if not exists public.inventory (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.shop_items(code) on delete cascade, at timestamptz not null default now(), source text not null default 'achat', primary key (user_id, code));
alter table public.shop_items enable row level security; alter table public.inventory enable row level security;

-- remboursement des achats de l'ancienne boutique (patch10), puis retrait de ces articles
do $$ begin
  if to_regclass('public.inventory') is not null then
    insert into public.token_log(user_id, delta, reason)
    select i.user_id, s.price, 'remboursement : ancienne boutique (' || s.name || ')' from public.inventory i join public.shop_items s on s.code = i.code
     where s.price is not null and i.source = 'achat' and s.code in ('frame_or','frame_arc','frame_feu','frame_neon','frame_glace','badge_etoile','badge_flamme','badge_couronne','badge_feuille','badge_eclair','badge_gemme','pack_visages','pack_nature');
    update public.wallets w set balance = balance + x.t from (
      select i.user_id, sum(s.price) t from public.inventory i join public.shop_items s on s.code = i.code
       where s.price is not null and i.source = 'achat' and s.code in ('frame_or','frame_arc','frame_feu','frame_neon','frame_glace','badge_etoile','badge_flamme','badge_couronne','badge_feuille','badge_eclair','badge_gemme','pack_visages','pack_nature') group by i.user_id) x
     where w.user_id = x.user_id;
    delete from public.inventory where code in ('frame_or','frame_arc','frame_feu','frame_neon','frame_glace','badge_etoile','badge_flamme','badge_couronne','badge_feuille','badge_eclair','badge_gemme','badge_fondateur','pack_visages','pack_nature');
  end if;
end $$;
drop table if exists public.equipped cascade;
drop table if exists public.premium_emoji cascade;
drop table if exists public.quest_defs cascade;
drop table if exists public.quest_claims cascade;
delete from public.shop_items where code in ('frame_or','frame_arc','frame_feu','frame_neon','frame_glace','badge_etoile','badge_flamme','badge_couronne','badge_feuille','badge_eclair','badge_gemme','badge_fondateur','pack_visages','pack_nature');
alter table public.shop_items drop constraint if exists shop_items_kind_check;
alter table public.shop_items add constraint shop_items_kind_check check (kind in ('frame','badge','pack','feature','credit'));
alter table public.shop_items alter column price type numeric(14,1);
insert into public.shop_items(code, kind, name, descr, price, sort) values
 ('lite','feature','Communicer Lite','Version économie d’énergie',9,1),
 ('pin','feature','Épinglage','Épingler jusqu’à 3 conversations (clic droit)',29,2),
 ('name_color','feature','Couleur du nom','Couleur de votre nom partout',279,3),
 ('profile_color','feature','Couleur du profil','Couleur du profil et de son texte',389,4),
 ('profile_bg','feature','Fond du profil','Image ou GIF en fond de profil',589,5),
 ('frame_photo','feature','Cadres de photo','Débloque 6 cadres de photo',299,6),
 ('frame_photo_anim','feature','Cadres de photo animés','Débloque 6 cadres de photo animés',379,7),
 ('frame_profile','feature','Cadres de profil','Débloque 6 cadres de profil',299,8),
 ('frame_profile_anim','feature','Cadres de profil animés','Débloque 6 cadres de profil animés',379,9),
 ('badge_slot5','feature','5e emplacement de badge','Afficher 5 badges au lieu de 4',1199,10),
 ('rename','credit','Changer de nom d’utilisateur','Un changement de nom (se rachète à chaque fois)',1150,11),
 ('credits_name','feature','Nom dans les crédits','Votre nom affiché dans les crédits du site',8940,12),
 ('pack_emoji','pack','Pack d’emojis premium','Tous les emojis premium (nouvel onglet du sélecteur)',499,13)
on conflict (code) do update set kind = excluded.kind, name = excluded.name, descr = excluded.descr, price = excluded.price, sort = excluded.sort;
-- 'rename' est consommable : le crédit est compté à part
create table if not exists public.profile_ext (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  name_color text check (name_color is null or name_color ~ '^#[0-9a-fA-F]{6}$'),
  profile_color text check (profile_color is null or profile_color ~ '^#[0-9a-fA-F]{6}$'),
  profile_text_color text check (profile_text_color is null or profile_text_color ~ '^#[0-9a-fA-F]{6}$'),
  profile_bg text check (profile_bg is null or profile_bg ~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$'),
  photo_frame text, profile_frame text, badges text[] not null default '{}', rename_credits int not null default 0 check (rename_credits >= 0),
  credits_name text check (credits_name is null or char_length(credits_name) between 1 and 40)
);
alter table public.profile_ext enable row level security;
create table if not exists public.conv_pins (user_id uuid not null references public.profiles(id) on delete cascade, conversation_id uuid not null references public.conversations(id) on delete cascade,
  at timestamptz not null default now(), primary key (user_id, conversation_id));
alter table public.conv_pins enable row level security;

create table if not exists public.frame_defs (code text primary key, cat text not null check (cat in ('photo','photo_anim','profile','profile_anim')), name text not null, sort int not null default 0);
alter table public.frame_defs enable row level security;
insert into public.frame_defs(code, cat, name, sort) values
 ('pf_s1','photo','Or','1'),('pf_s2','photo','Argent','2'),('pf_s3','photo','Rubis','3'),('pf_s4','photo','Saphir','4'),('pf_s5','photo','Émeraude','5'),('pf_s6','photo','Ébène','6'),
 ('pf_a1','photo_anim','Arc-en-ciel','1'),('pf_a2','photo_anim','Flammes','2'),('pf_a3','photo_anim','Néon pulsé','3'),('pf_a4','photo_anim','Aurore','4'),('pf_a5','photo_anim','Éclairs','5'),('pf_a6','photo_anim','Orbite','6'),
 ('rf_s1','profile','Filet doré','1'),('rf_s2','profile','Double trait','2'),('rf_s3','profile','Pointillé','3'),('rf_s4','profile','Coins ornés','4'),('rf_s5','profile','Ombre portée','5'),('rf_s6','profile','Ruban','6'),
 ('rf_a1','profile_anim','Contour arc-en-ciel','1'),('rf_a2','profile_anim','Lueur respirante','2'),('rf_a3','profile_anim','Fil de lumière','3'),('rf_a4','profile_anim','Braises','4'),('rf_a5','profile_anim','Vagues','5'),('rf_a6','profile_anim','Étincelles','6')
on conflict (code) do update set cat = excluded.cat, name = excluded.name, sort = excluded.sort;

-- ---------- badges ----------
create table if not exists public.badge_defs (code text primary key, name text not null, descr text not null, tier text not null check (tier in ('merit','special','premium','patron','union')),
  price numeric(14,1), sort int not null default 0);
create table if not exists public.badge_counters (code text primary key, n int not null default 0);
create table if not exists public.user_badges (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.badge_defs(code),
  seq int not null, at timestamptz not null default now(), given_by uuid references public.profiles(id) on delete set null, extra jsonb not null default '{}'::jsonb, primary key (user_id, code));
create table if not exists public.badge_requests (id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade,
  code text not null references public.badge_defs(code), note text not null check (char_length(note) between 5 and 1000), status text not null default 'pending' check (status in ('pending','accepted','refused')),
  created_at timestamptz not null default now(), decided_by uuid references public.profiles(id) on delete set null, decided_at timestamptz);
alter table public.badge_defs enable row level security; alter table public.badge_counters enable row level security; alter table public.user_badges enable row level security; alter table public.badge_requests enable row level security;
insert into public.badge_defs(code, name, descr, tier, price, sort) values
 ('nouveau_venu','Nouveau venu','A créé son profil.','merit',null,1),
 ('habitue','Habitué','S’est connecté 30 jours différents.','merit',null,2),
 ('veteran','Vétéran','Avait un compte avant la sortie officielle du site.','merit',null,3),
 ('aine','Aîné','Membre depuis un an.','merit',null,4),
 ('champion','Champion','A gagné 100 parties de groupe.','merit',null,5),
 ('chasseur','Chasseur de bogue','5 bogues signalés et approuvés.','merit',null,6),
 ('ambassadeur','Ambassadeur','10 parrainages valides.','merit',null,7),
 ('strategie','Stratège','50 victoires dans un même jeu.','merit',null,8),
 ('elite','Élite','500 victoires aux jeux de groupe.','merit',null,9),
 ('premier','Premier','Parmi les 100 premiers comptes du site.','merit',null,10),
 ('ingenieur','Ingénieur','A inventé un bot utilisé dans plus de 20 conversations.','merit',null,11),
 ('gardien','Gardien','Contribution exceptionnelle au site.','special',null,20),
 ('developpeur','Développeur','Contribution de code reconnue.','special',null,21),
 ('concepteur','Concepteur','A aidé à concevoir le site, sans code.','special',null,22),
 ('fondateur','Fondateur','Créateur du site.','special',null,23),
 ('moderateur','Modérateur','Administrateur du site.','special',null,24),
 ('aristocrate','Aristocrate','Badge premium.','premium',1200,30),
 ('cybernaute','Cybernaute','Badge premium.','premium',800,31),
 ('enigmatique','Énigmatique','Badge premium.','premium',1000,32),
 ('legende','Légende','Badge de mécène.','patron',15000,40),
 ('souverain','Souverain','Badge de mécène.','patron',5000,41),
 ('grand_mecene','Grand mécène','Remis par les modérateurs.','patron',null,42),
 ('mecene','Mécène','Badge de mécène.','patron',85000,43),
 ('legende_mecene','Légende du mécène','Union du Grand mécène et du Mécène.','union',null,44)
on conflict (code) do update set name = excluded.name, descr = excluded.descr, tier = excluded.tier, price = excluded.price, sort = excluded.sort;

create or replace function public.badge_grant(p_user uuid, p_code text, p_by uuid default null, p_extra jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare k int;
begin
  if exists(select 1 from public.user_badges where user_id = p_user and code = p_code) then return false; end if;
  insert into public.badge_counters as bc(code, n) values (p_code, 1) on conflict (code) do update set n = bc.n + 1 returning bc.n into k;
  insert into public.user_badges(user_id, code, seq, given_by, extra) values (p_user, p_code, k, p_by, coalesce(p_extra, '{}'::jsonb));
  return true;
end $$;
revoke all on function public.badge_grant(uuid, text, uuid, jsonb) from public, anon, authenticated;

create or replace function public.badges_check(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare cr timestamptz; rel timestamptz;
begin
  select created_at into cr from public.profiles where id = p_user;
  if cr is null then return; end if;
  rel := (public.cfg_text('release_date') || ' 00:00')::timestamp at time zone 'America/Toronto';
  perform public.badge_grant(p_user, 'nouveau_venu');
  if (select count(*) from public.daily_claims where user_id = p_user) >= 30 then perform public.badge_grant(p_user, 'habitue'); end if;
  if cr < rel then perform public.badge_grant(p_user, 'veteran'); end if;
  if cr <= now() - interval '1 year' then perform public.badge_grant(p_user, 'aine'); end if;
  if (select count(*) from public.game_wins where user_id = p_user) >= 100 then perform public.badge_grant(p_user, 'champion'); end if;
  if (select count(*) from public.game_wins where user_id = p_user) >= 500 then perform public.badge_grant(p_user, 'elite'); end if;
  if coalesce((select max(c) from (select count(*) c from public.game_wins where user_id = p_user group by game) x), 0) >= 50 then perform public.badge_grant(p_user, 'strategie'); end if;
  if (select count(*) from public.bug_reports where user_id = p_user and status = 'approved') >= 5 then perform public.badge_grant(p_user, 'chasseur'); end if;
  if (select count(*) from public.referrals where referrer_id = p_user and paid) >= 10 then perform public.badge_grant(p_user, 'ambassadeur'); end if;
  if (select count(*) from (select id from public.profiles order by created_at, id limit 100) f where f.id = p_user) > 0 then perform public.badge_grant(p_user, 'premier'); end if;
  if (select count(distinct cb.conversation_id) from public.conversation_bots cb join public.bots b on b.id = cb.bot_id where b.owner_id = p_user and not b.official) > 20 then perform public.badge_grant(p_user, 'ingenieur'); end if;
end $$;
revoke all on function public.badges_check(uuid) from public, anon, authenticated;
create or replace function public.cfg_text(p_k text) returns text language sql stable security definer set search_path = public as $$ select (select v from public.tok_cfg where k = p_k) $$;
revoke all on function public.cfg_text(text) from public, anon, authenticated;

-- Modérateur : automatique, obligatoire, retiré quand la personne n'est plus administrateur
create or replace function public.trg_staff_badge() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    delete from public.user_badges where user_id = old.user_id and code = 'moderateur';
    update public.profile_ext set badges = array_remove(badges, 'moderateur') where user_id = old.user_id;
    return old;
  end if;
  perform public.badge_grant(new.user_id, 'moderateur', null);
  return new;
end $$;
drop trigger if exists site_staff_badge on public.site_staff;
create trigger site_staff_badge after insert or update of role on public.site_staff for each row execute function public.trg_staff_badge();
drop trigger if exists site_staff_badge_del on public.site_staff;
create trigger site_staff_badge_del after delete on public.site_staff for each row execute function public.trg_staff_badge();
select public.badge_grant(user_id, 'moderateur') from public.site_staff;

-- ---------- lecture ----------
create or replace function public.badge_json(p_user uuid, p_code text)
returns jsonb language sql security definer stable set search_path = public as $$
  select jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier, 'seq', u.seq, 'at', u.at,
    'by', case when d.tier = 'special' or d.code = 'grand_mecene' then (select username from public.profiles where id = u.given_by) end,
    'extra', u.extra)
  from public.user_badges u join public.badge_defs d on d.code = u.code where u.user_id = p_user and u.code = p_code
$$;
revoke all on function public.badge_json(uuid, text) from public, anon, authenticated;

create or replace function public.cosmetics_of(p_users text[])
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_object_agg(p.username, jsonb_strip_nulls(jsonb_build_object('nc', e.name_color, 'pf', e.photo_frame, 'mod', exists(select 1 from public.user_badges b where b.user_id = p.id and b.code = 'moderateur')))), '{}'::jsonb)
  from public.profiles p left join public.profile_ext e on e.user_id = p.id where p.username = any(p_users) and (e.name_color is not null or e.photo_frame is not null or exists(select 1 from public.user_badges b where b.user_id = p.id and b.code = 'moderateur'))
$$;

create or replace function public.profile_full(p_username text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare u uuid; e public.profile_ext; shown jsonb := '[]'::jsonb; c text;
begin
  select id into u from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if u is null then return '{}'::jsonb; end if;
  select * into e from public.profile_ext where user_id = u;
  if exists(select 1 from public.user_badges where user_id = u and code = 'moderateur') then shown := shown || jsonb_build_array(public.badge_json(u, 'moderateur')); end if;
  foreach c in array coalesce(e.badges, '{}') loop
    if c <> 'moderateur' and exists(select 1 from public.user_badges where user_id = u and code = c) then shown := shown || jsonb_build_array(public.badge_json(u, c)); end if;
  end loop;
  return jsonb_build_object('nc', e.name_color, 'pc', e.profile_color, 'ptc', e.profile_text_color, 'bg', e.profile_bg, 'pf', e.photo_frame, 'rf', e.profile_frame, 'badges', shown);
end $$;

create or replace function public.inventory_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.profile_ext;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into e from public.profile_ext where user_id = auth.uid();
  return jsonb_build_object('ext', coalesce(to_jsonb(e) - 'user_id', '{}'::jsonb),
    'items', coalesce((select jsonb_agg(code) from public.inventory where user_id = auth.uid()), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(public.badge_json(auth.uid(), code) order by (select sort from public.badge_defs where code = u.code)) from public.user_badges u where user_id = auth.uid()), '[]'::jsonb),
    'slots', 4 + case when exists(select 1 from public.inventory where user_id = auth.uid() and code = 'badge_slot5') then 1 else 0 end);
end $$;

create or replace function public.shop_list()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'descr', s.descr, 'price', s.price, 'kind', s.kind,
       'owned', s.kind <> 'credit' and exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code)) order by s.sort) from public.shop_items s), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier, 'price', d.price,
       'owned', exists(select 1 from public.user_badges b where b.user_id = auth.uid() and b.code = d.code)) order by d.sort) from public.badge_defs d where d.price is not null), '[]'::jsonb),
    'frames', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'name', name) order by cat, sort) from public.frame_defs), '[]'::jsonb),
    'pack', jsonb_build_object('cad', public.cfg_n('pack_price_cad'), 'tokens', public.cfg_n('pack_tokens')))
$$;

-- ---------- achats ----------
create or replace function public.shop_buy(p_code text)
returns numeric language plpgsql security definer set search_path = public as $$
declare it public.shop_items; bd public.badge_defs; b numeric; price numeric; nm text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('buy', 60, 3600);
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select balance into b from public.wallets where user_id = auth.uid() for update;
  select * into it from public.shop_items where code = p_code;
  if found then
    if it.price is null then raise exception 'Cet article ne s’achète pas'; end if;
    if it.kind <> 'credit' and exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
    price := it.price; nm := it.name;
  else
    select * into bd from public.badge_defs where code = p_code;
    if not found or bd.price is null then raise exception 'Article introuvable'; end if;
    if exists(select 1 from public.user_badges where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
    price := bd.price; nm := 'badge ' || bd.name;
  end if;
  if b < price then raise exception 'Jetons insuffisants'; end if;
  if it.code is not null then
    if it.kind = 'credit' then
      insert into public.profile_ext(user_id, rename_credits) values (auth.uid(), 1) on conflict (user_id) do update set rename_credits = public.profile_ext.rename_credits + 1;
    else insert into public.inventory(user_id, code) values (auth.uid(), p_code); end if;
  else perform public.badge_grant(auth.uid(), p_code, null); end if;
  return public.tok_add(auth.uid(), -price, 'achat : ' || nm);
end $$;

create or replace function public.rename_me(p_new text)
returns text language plpgsql security definer set search_path = public as $$
declare n text := lower(trim(coalesce(p_new,''))); old text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if n !~ '^[a-z0-9_]{3,20}$' then raise exception 'Nom invalide (3 à 20 caractères : lettres, chiffres, _)'; end if;
  if exists(select 1 from public.profiles where username = n) or exists(select 1 from public.bots where username = n and status <> 'deleted') then raise exception 'Ce nom est déjà pris'; end if;
  update public.profile_ext set rename_credits = rename_credits - 1 where user_id = auth.uid() and rename_credits > 0;
  if not found then raise exception 'Achetez d’abord un changement de nom'; end if;
  select username into old from public.profiles where id = auth.uid();
  update public.profiles set username = n where id = auth.uid();
  insert into public.token_log(user_id, delta, reason) values (auth.uid(), 0, 'nom changé : ' || old || ' vers ' || n);
  return n;
end $$;

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
    if not exists(select 1 from public.inventory where user_id = auth.uid() and code = 'frame_' || f.cat) then raise exception 'Article non possédé'; end if;
  end if;
  execute format('update public.profile_ext set %I = $1 where user_id = $2', p_field) using v, auth.uid();
end $$;

create or replace function public.badges_equip(p_codes text[])
returns void language plpgsql security definer set search_path = public as $$
declare c text; slots int; arr text[] := '{}';
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  slots := 4 + case when exists(select 1 from public.inventory where user_id = auth.uid() and code = 'badge_slot5') then 1 else 0 end;
  foreach c in array coalesce(p_codes, '{}') loop
    if c = 'moderateur' or c = any(arr) then continue; end if;
    if not exists(select 1 from public.user_badges where user_id = auth.uid() and code = c) then raise exception 'Badge non possédé'; end if;
    arr := arr || c;
  end loop;
  if coalesce(array_length(arr, 1), 0) > slots then raise exception 'Seulement % badges affichables', slots; end if;
  insert into public.profile_ext(user_id, badges) values (auth.uid(), arr) on conflict (user_id) do update set badges = excluded.badges;
end $$;

create or replace function public.badge_union()
returns void language plpgsql security definer set search_path = public as $$
declare a jsonb; b jsonb; bal numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not (exists(select 1 from public.user_badges where user_id = auth.uid() and code = 'grand_mecene') and exists(select 1 from public.user_badges where user_id = auth.uid() and code = 'mecene')) then raise exception 'Il faut le Grand mécène et le Mécène'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select balance into bal from public.wallets where user_id = auth.uid() for update;
  if bal < 2750 then raise exception 'Jetons insuffisants'; end if;
  a := public.badge_json(auth.uid(), 'grand_mecene'); b := public.badge_json(auth.uid(), 'mecene');
  delete from public.user_badges where user_id = auth.uid() and code in ('grand_mecene','mecene');
  update public.profile_ext set badges = array_remove(array_remove(badges, 'grand_mecene'), 'mecene') where user_id = auth.uid();
  perform public.badge_grant(auth.uid(), 'legende_mecene', null, jsonb_build_object('a', a, 'b', b));
  perform public.tok_add(auth.uid(), -2750, 'union : Légende du mécène');
end $$;

-- demandes de badge (Gardien…) validées par un administrateur
create or replace function public.badge_request(p_code text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_code not in ('gardien','developpeur','concepteur') then raise exception 'Ce badge ne se demande pas'; end if;
  if exists(select 1 from public.user_badges where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
  if exists(select 1 from public.badge_requests where user_id = auth.uid() and code = p_code and status = 'pending') then raise exception 'Demande déjà en attente'; end if;
  perform public.rate_ok('badgereq', 5, 86400);
  insert into public.badge_requests(user_id, code, note) values (auth.uid(), p_code, left(trim(coalesce(p_note,'')), 1000));
end $$;
create or replace function public.badge_requests_list()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'user', p.username, 'code', r.code, 'note', r.note, 'at', r.created_at) order by r.id) from public.badge_requests r join public.profiles p on p.id = r.user_id where r.status = 'pending'), '[]'::jsonb);
end $$;
create or replace function public.badge_request_decide(p_id bigint, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r public.badge_requests;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select * into r from public.badge_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Demande introuvable'; end if;
  if r.user_id = auth.uid() then raise exception 'Vous ne pouvez pas valider votre propre demande'; end if;
  update public.badge_requests set status = case when p_ok then 'accepted' else 'refused' end, decided_by = auth.uid(), decided_at = now() where id = p_id;
  if p_ok then perform public.badge_grant(r.user_id, r.code, auth.uid()); end if;
  perform public.log_admin(case when p_ok then 'badge_demande_acceptee' else 'badge_demande_refusee' end, (select username from public.profiles where id = r.user_id), jsonb_build_object('badge', r.code));
end $$;

-- épinglage (3 conversations, article requis)
create or replace function public.pin_set(p_conv uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not p_on then delete from public.conv_pins where user_id = auth.uid() and conversation_id = p_conv; return; end if;
  if not exists(select 1 from public.inventory where user_id = auth.uid() and code = 'pin') then raise exception 'Achetez l’épinglage dans la boutique'; end if;
  if (select count(*) from public.conv_pins where user_id = auth.uid() and conversation_id <> p_conv) >= 3 then raise exception 'Trois conversations épinglées au maximum'; end if;
  insert into public.conv_pins(user_id, conversation_id) values (auth.uid(), p_conv) on conflict do nothing;
end $$;
create or replace function public.pins_me() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(conversation_id order by at), '[]'::jsonb) from public.conv_pins where user_id = auth.uid() $$;
create or replace function public.has_item(p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code) $$;
create or replace function public.credits_list() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(e.credits_name order by e.user_id), '[]'::jsonb) from public.profile_ext e where e.credits_name is not null and exists(select 1 from public.inventory i where i.user_id = e.user_id and i.code = 'credits_name') $$;

-- ---------- emojis premium ----------
create table if not exists public.premium_emoji (code text primary key, cat text not null);
alter table public.premium_emoji enable row level security;
create or replace function public.emoji_premium_list() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_object_agg(cat, l), '{}'::jsonb) from (select cat, jsonb_agg(code order by code) l from public.premium_emoji group by cat) x $$;
create or replace function public.pe_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'text' and new.body is not null and new.body ~ '[\U0001F000-\U0001FAFF☀-⯿]' and not exists(select 1 from public.inventory where user_id = new.sender_id and code = 'pack_emoji') then
    if exists(select 1 from public.premium_emoji e where position(e.code in new.body) > 0) then raise exception 'Emoji réservé aux abonnés du pack premium'; end if;
  end if;
  return new;
end $$;
drop trigger if exists messages_pe_guard on public.messages;
create trigger messages_pe_guard before insert or update of body on public.messages for each row execute function public.pe_guard();
insert into public.premium_emoji(code, cat) values ('😈','Visages+'),('😌','Visages+'),('😒','Visages+'),('😓','Visages+'),('😔','Visages+'),('😕','Visages+'),('😖','Visages+'),('😗','Visages+'),('😙','Visages+'),('😚','Visages+'),('😝','Visages+'),('😞','Visages+'),('😟','Visages+'),('😠','Visages+'),('😣','Visages+'),('😥','Visages+'),('😦','Visages+'),('😧','Visages+'),('😨','Visages+'),('😩','Visages+'),('😪','Visages+'),('😫','Visages+'),('😬','Visages+'),('😯','Visages+'),('😰','Visages+'),('😱','Visages+'),('😵','Visages+'),('😶','Visages+'),('😷','Visages+'),('😸','Visages+'),('😹','Visages+'),('😺','Visages+'),('😻','Visages+'),('😼','Visages+'),('😽','Visages+'),('😾','Visages+'),('😿','Visages+'),('🙀','Visages+'),('🙁','Visages+'),('🙃','Visages+'),('🙅','Visages+'),('🙆','Visages+'),('🙇','Visages+'),('🙈','Visages+'),('🙉','Visages+'),('🙊','Visages+'),('🙋','Visages+'),('🙍','Visages+'),('🙎','Visages+'),('👂','Mains+'),('👃','Mains+'),('👄','Mains+'),('👅','Mains+'),('👆','Mains+'),('👇','Mains+'),('👈','Mains+'),('👉','Mains+'),('👐','Mains+'),('👑','Mains+'),('👒','Mains+'),('👓','Mains+'),('👔','Mains+'),('👕','Mains+'),('👖','Mains+'),('👗','Mains+'),('👘','Mains+'),('👙','Mains+'),('👚','Mains+'),('👛','Mains+'),('👜','Mains+'),('👝','Mains+'),('👞','Mains+'),('👟','Mains+'),('👠','Mains+'),('👡','Mains+'),('👢','Mains+'),('👣','Mains+'),('👤','Mains+'),('👥','Mains+'),('👦','Mains+'),('👧','Mains+'),('👨','Mains+'),('👩','Mains+'),('👪','Mains+'),('👫','Mains+'),('👬','Mains+'),('👭','Mains+'),('👮','Mains+'),('👯','Mains+'),('👰','Mains+'),('👱','Mains+'),('👲','Mains+'),('👳','Mains+'),('👴','Mains+'),('👵','Mains+'),('👶','Mains+'),('👷','Mains+'),('👸','Mains+'),('👹','Mains+'),('👺','Mains+'),('👻','Mains+'),('👼','Mains+'),('👽','Mains+'),('👾','Mains+'),('👿','Mains+'),('💀','Mains+'),('💁','Mains+'),('💂','Mains+'),('💃','Mains+'),('💄','Mains+'),('💅','Mains+'),('💆','Mains+'),('💇','Mains+'),('💈','Mains+'),('💉','Mains+'),('💊','Mains+'),('💋','Mains+'),('💌','Mains+'),('💍','Mains+'),('💎','Mains+'),('💏','Mains+'),('💐','Mains+'),('💑','Mains+'),('💒','Mains+'),('💓','Mains+'),('💕','Mains+'),('💗','Mains+'),('💘','Mains+'),('💝','Mains+'),('💞','Mains+'),('💟','Mains+'),('💠','Mains+'),('💢','Mains+'),('💣','Mains+'),('💤','Mains+'),('💦','Mains+'),('💧','Mains+'),('💨','Mains+'),('💩','Mains+'),('🐀','Animaux'),('🐁','Animaux'),('🐂','Animaux'),('🐃','Animaux'),('🐄','Animaux'),('🐅','Animaux'),('🐆','Animaux'),('🐇','Animaux'),('🐈','Animaux'),('🐉','Animaux'),('🐊','Animaux'),('🐋','Animaux'),('🐌','Animaux'),('🐍','Animaux'),('🐎','Animaux'),('🐏','Animaux'),('🐐','Animaux'),('🐑','Animaux'),('🐒','Animaux'),('🐓','Animaux'),('🐔','Animaux'),('🐕','Animaux'),('🐖','Animaux'),('🐗','Animaux'),('🐘','Animaux'),('🐙','Animaux'),('🐚','Animaux'),('🐛','Animaux'),('🐜','Animaux'),('🐝','Animaux'),('🐞','Animaux'),('🐟','Animaux'),('🐠','Animaux'),('🐡','Animaux'),('🐣','Animaux'),('🐤','Animaux'),('🐥','Animaux'),('🐦','Animaux'),('🐧','Animaux'),('🐨','Animaux'),('🐩','Animaux'),('🐪','Animaux'),('🐫','Animaux'),('🐬','Animaux'),('🐭','Animaux'),('🐮','Animaux'),('🐯','Animaux'),('🐰','Animaux'),('🐲','Animaux'),('🐳','Animaux'),('🐴','Animaux'),('🐷','Animaux'),('🐹','Animaux'),('🐺','Animaux'),('🐻','Animaux'),('🐽','Animaux'),('🐾','Animaux'),('🍅','Nourriture'),('🍆','Nourriture'),('🍇','Nourriture'),('🍈','Nourriture'),('🍉','Nourriture'),('🍊','Nourriture'),('🍋','Nourriture'),('🍌','Nourriture'),('🍍','Nourriture'),('🍎','Nourriture'),('🍏','Nourriture'),('🍐','Nourriture'),('🍑','Nourriture'),('🍒','Nourriture'),('🍓','Nourriture'),('🍖','Nourriture'),('🍗','Nourriture'),('🍘','Nourriture'),('🍙','Nourriture'),('🍚','Nourriture'),('🍛','Nourriture'),('🍜','Nourriture'),('🍝','Nourriture'),('🍞','Nourriture'),('🍠','Nourriture'),('🍡','Nourriture'),('🍢','Nourriture'),('🍣','Nourriture'),('🍤','Nourriture'),('🍥','Nourriture'),('🍦','Nourriture'),('🍧','Nourriture'),('🍨','Nourriture'),('🍪','Nourriture'),('🍫','Nourriture'),('🍬','Nourriture'),('🍭','Nourriture'),('🍮','Nourriture'),('🍯','Nourriture'),('🍰','Nourriture'),('🍱','Nourriture'),('🍲','Nourriture'),('🍳','Nourriture'),('🍴','Nourriture'),('🍵','Nourriture'),('🍶','Nourriture'),('🍷','Nourriture'),('🍸','Nourriture'),('🍹','Nourriture'),('🍻','Nourriture'),('🍼','Nourriture'),('🍾','Nourriture'),('🍿','Nourriture'),('🎀','Fête et sport'),('🎂','Fête et sport'),('🎃','Fête et sport'),('🎄','Fête et sport'),('🎅','Fête et sport'),('🎆','Fête et sport'),('🎇','Fête et sport'),('🎊','Fête et sport'),('🎋','Fête et sport'),('🎌','Fête et sport'),('🎍','Fête et sport'),('🎎','Fête et sport'),('🎏','Fête et sport'),('🎐','Fête et sport'),('🎑','Fête et sport'),('🎒','Fête et sport'),('🎓','Fête et sport'),('🎠','Fête et sport'),('🎡','Fête et sport'),('🎢','Fête et sport'),('🎣','Fête et sport'),('🎤','Fête et sport'),('🎥','Fête et sport'),('🎦','Fête et sport'),('🎧','Fête et sport'),('🎨','Fête et sport'),('🎩','Fête et sport'),('🎪','Fête et sport'),('🎫','Fête et sport'),('🎬','Fête et sport'),('🎭','Fête et sport'),('🎯','Fête et sport'),('🎰','Fête et sport'),('🎱','Fête et sport'),('🎲','Fête et sport'),('🎳','Fête et sport'),('🎴','Fête et sport'),('🎶','Fête et sport'),('🎷','Fête et sport'),('🎸','Fête et sport'),('🎹','Fête et sport'),('🎺','Fête et sport'),('🎻','Fête et sport'),('🎼','Fête et sport'),('🎽','Fête et sport'),('🎾','Fête et sport'),('🎿','Fête et sport'),('🏀','Fête et sport'),('🏁','Fête et sport'),('🏂','Fête et sport'),('🏃','Fête et sport'),('🏄','Fête et sport'),('🏅','Fête et sport'),('🏇','Fête et sport'),('🏈','Fête et sport'),('🏉','Fête et sport'),('🏊','Fête et sport'),('🏏','Fête et sport'),('🏐','Fête et sport'),('🏑','Fête et sport'),('🏒','Fête et sport'),('🏓','Fête et sport'),('🏠','Fête et sport'),('🏡','Fête et sport'),('🏢','Fête et sport'),('🏣','Fête et sport'),('🏤','Fête et sport'),('🏥','Fête et sport'),('🏦','Fête et sport'),('🏧','Fête et sport'),('🏨','Fête et sport'),('🏩','Fête et sport'),('🏪','Fête et sport'),('🏫','Fête et sport'),('🏬','Fête et sport'),('🏭','Fête et sport'),('🏮','Fête et sport'),('🏯','Fête et sport'),('🏰','Fête et sport'),('🏴','Fête et sport'),('🏸','Fête et sport'),('🏹','Fête et sport'),('🏺','Fête et sport'),('🚁','Voyage'),('🚂','Voyage'),('🚃','Voyage'),('🚄','Voyage'),('🚅','Voyage'),('🚆','Voyage'),('🚇','Voyage'),('🚈','Voyage'),('🚉','Voyage'),('🚊','Voyage'),('🚋','Voyage'),('🚌','Voyage'),('🚍','Voyage'),('🚎','Voyage'),('🚏','Voyage'),('🚐','Voyage'),('🚑','Voyage'),('🚒','Voyage'),('🚓','Voyage'),('🚔','Voyage'),('🚕','Voyage'),('🚖','Voyage'),('🚗','Voyage'),('🚘','Voyage'),('🚙','Voyage'),('🚚','Voyage'),('🚛','Voyage'),('🚜','Voyage'),('🚝','Voyage'),('🚞','Voyage'),('🚟','Voyage'),('🚠','Voyage'),('🚡','Voyage'),('🚢','Voyage'),('🚣','Voyage'),('🚤','Voyage'),('🚥','Voyage'),('🚦','Voyage'),('🚧','Voyage'),('🚨','Voyage'),('🚩','Voyage'),('🚪','Voyage'),('🚫','Voyage'),('🚬','Voyage'),('🚭','Voyage'),('🚮','Voyage'),('🚯','Voyage'),('🚰','Voyage'),('🚱','Voyage'),('🚲','Voyage'),('🚳','Voyage'),('🚴','Voyage'),('🚵','Voyage'),('🚶','Voyage'),('🚷','Voyage'),('🚸','Voyage'),('🚹','Voyage'),('🚺','Voyage'),('🚻','Voyage'),('🚼','Voyage'),('🚽','Voyage'),('🚾','Voyage'),('🚿','Voyage'),('🛀','Voyage'),('🛁','Voyage'),('🛂','Voyage'),('🛃','Voyage'),('🛄','Voyage'),('🛅','Voyage'),('🛌','Voyage'),('🛐','Voyage'),('🛑','Voyage'),('🛒','Voyage'),('🛕','Voyage'),('🛖','Voyage'),('🛗','Voyage'),('🛜','Voyage'),('🛝','Voyage'),('🛞','Voyage'),('🛟','Voyage'),('🛫','Voyage'),('🛬','Voyage'),('🛴','Voyage'),('🛵','Voyage'),('🛶','Voyage'),('🛷','Voyage'),('🛸','Voyage'),('🛹','Voyage'),('🛺','Voyage'),('🛻','Voyage'),('🛼','Voyage'),('💬','Objets'),('💭','Objets'),('💮','Objets'),('💰','Objets'),('💱','Objets'),('💲','Objets'),('💳','Objets'),('💴','Objets'),('💵','Objets'),('💶','Objets'),('💷','Objets'),('💸','Objets'),('💹','Objets'),('💺','Objets'),('💻','Objets'),('💼','Objets'),('💽','Objets'),('💾','Objets'),('💿','Objets'),('📀','Objets'),('📁','Objets'),('📂','Objets'),('📃','Objets'),('📄','Objets'),('📅','Objets'),('📆','Objets'),('📇','Objets'),('📈','Objets'),('📉','Objets'),('📊','Objets'),('📋','Objets'),('📌','Objets'),('📍','Objets'),('📎','Objets'),('📏','Objets'),('📐','Objets'),('📑','Objets'),('📒','Objets'),('📓','Objets'),('📔','Objets'),('📕','Objets'),('📖','Objets'),('📗','Objets'),('📘','Objets'),('📙','Objets'),('📚','Objets'),('📛','Objets'),('📜','Objets'),('📝','Objets'),('📞','Objets'),('📟','Objets'),('📠','Objets'),('📡','Objets'),('📢','Objets'),('📣','Objets'),('📤','Objets'),('📥','Objets'),('📦','Objets'),('📧','Objets'),('📨','Objets'),('📩','Objets'),('📪','Objets'),('📫','Objets'),('📬','Objets'),('📭','Objets'),('📮','Objets'),('📯','Objets'),('📰','Objets'),('📱','Objets'),('📲','Objets'),('📳','Objets'),('📴','Objets'),('📵','Objets'),('📶','Objets'),('📸','Objets'),('📹','Objets'),('📺','Objets'),('📻','Objets'),('📼','Objets'),('📿','Objets'),('🔀','Symboles'),('🔁','Symboles'),('🔂','Symboles'),('🔃','Symboles'),('🔄','Symboles'),('🔅','Symboles'),('🔆','Symboles'),('🔇','Symboles'),('🔈','Symboles'),('🔉','Symboles'),('🔊','Symboles'),('🔋','Symboles'),('🔌','Symboles'),('🔍','Symboles'),('🔎','Symboles'),('🔏','Symboles'),('🔐','Symboles'),('🔑','Symboles'),('🔒','Symboles'),('🔓','Symboles'),('🔔','Symboles'),('🔕','Symboles'),('🔖','Symboles'),('🔗','Symboles'),('🔘','Symboles'),('🔙','Symboles'),('🔚','Symboles'),('🔛','Symboles'),('🔜','Symboles'),('🔝','Symboles'),('🔞','Symboles'),('🔟','Symboles'),('🔠','Symboles'),('🔡','Symboles'),('🔢','Symboles'),('🔣','Symboles'),('🔤','Symboles'),('🔦','Symboles'),('🔧','Symboles'),('🔨','Symboles'),('🔩','Symboles'),('🔪','Symboles'),('🔫','Symboles'),('🔬','Symboles'),('🔭','Symboles'),('🔮','Symboles'),('🔯','Symboles'),('🔰','Symboles'),('🔱','Symboles'),('🔲','Symboles'),('🔳','Symboles'),('🔴','Symboles'),('🔵','Symboles'),('🔶','Symboles'),('🔷','Symboles'),('🔸','Symboles'),('🔹','Symboles'),('🔺','Symboles'),('🔻','Symboles'),('🔼','Symboles'),('🔽','Symboles'),('🕋','Symboles'),('🕌','Symboles'),('🕍','Symboles'),('🕎','Symboles'),('🕐','Symboles'),('🕑','Symboles'),('🕒','Symboles'),('🕓','Symboles'),('🕔','Symboles'),('🕕','Symboles'),('🕖','Symboles'),('🕗','Symboles'),('🕘','Symboles'),('🕙','Symboles'),('🕚','Symboles'),('🕛','Symboles'),('🕜','Symboles'),('🕝','Symboles'),('🕞','Symboles'),('🕟','Symboles'),('🕠','Symboles'),('🕡','Symboles'),('🕢','Symboles'),('🕣','Symboles'),('🕤','Symboles'),('🕥','Symboles'),('🕦','Symboles'),('🕧','Symboles'),('🕺','Symboles'),('🖕','Symboles'),('🖖','Symboles'),('🗻','Symboles'),('🗼','Symboles'),('🗽','Symboles'),('🗾','Symboles'),('🗿','Symboles'),('🤌','Divers+'),('🤍','Divers+'),('🤎','Divers+'),('🤏','Divers+'),('🤐','Divers+'),('🤑','Divers+'),('🤒','Divers+'),('🤕','Divers+'),('🤖','Divers+'),('🤘','Divers+'),('🤚','Divers+'),('🤛','Divers+'),('🤜','Divers+'),('🤟','Divers+'),('🤠','Divers+'),('🤡','Divers+'),('🤢','Divers+'),('🤤','Divers+'),('🤥','Divers+'),('🤦','Divers+'),('🤧','Divers+'),('🤩','Divers+'),('🤬','Divers+'),('🤮','Divers+'),('🤰','Divers+'),('🤱','Divers+'),('🤲','Divers+'),('🤳','Divers+'),('🤴','Divers+'),('🤵','Divers+'),('🤶','Divers+'),('🤷','Divers+'),('🤸','Divers+'),('🤹','Divers+'),('🤺','Divers+'),('🤼','Divers+'),('🤽','Divers+'),('🤾','Divers+'),('🤿','Divers+'),('🥀','Divers+'),('🥁','Divers+'),('🥂','Divers+'),('🥃','Divers+'),('🥄','Divers+'),('🥅','Divers+'),('🥇','Divers+'),('🥈','Divers+'),('🥉','Divers+'),('🥊','Divers+'),('🥋','Divers+'),('🥌','Divers+'),('🥍','Divers+'),('🥎','Divers+'),('🥏','Divers+'),('🥐','Divers+'),('🥑','Divers+'),('🥒','Divers+'),('🥓','Divers+'),('🥔','Divers+'),('🥕','Divers+'),('🥖','Divers+'),('🥗','Divers+'),('🥘','Divers+'),('🥙','Divers+'),('🥚','Divers+'),('🥛','Divers+'),('🥜','Divers+'),('🥝','Divers+'),('🥞','Divers+'),('🥟','Divers+'),('🥠','Divers+'),('🥡','Divers+'),('🥢','Divers+'),('🥣','Divers+'),('🥤','Divers+'),('🥥','Divers+'),('🥦','Divers+'),('🥧','Divers+'),('🥨','Divers+'),('🥩','Divers+'),('🥪','Divers+'),('🥫','Divers+'),('🥬','Divers+'),('🥭','Divers+'),('🥮','Divers+'),('🥯','Divers+'),('🥱','Divers+'),('🥲','Divers+'),('🥴','Divers+'),('🥵','Divers+'),('🥶','Divers+'),('🥷','Divers+'),('🥸','Divers+'),('🥹','Divers+'),('🥻','Divers+'),('🥼','Divers+'),('🥽','Divers+'),('🥾','Divers+'),('🥿','Divers+'),('🦀','Divers+'),('🦁','Divers+'),('🦂','Divers+'),('🦃','Divers+'),('🦅','Divers+'),('🦆','Divers+'),('🦇','Divers+'),('🦈','Divers+'),('🦉','Divers+'),('🦋','Divers+'),('🦌','Divers+'),('🦍','Divers+'),('🦎','Divers+'),('🦏','Divers+'),('🦐','Divers+'),('🦑','Divers+'),('🦒','Divers+'),('🦓','Divers+'),('🦔','Divers+'),('🦕','Divers+'),('🦖','Divers+'),('🦗','Divers+'),('🦘','Divers+'),('🦙','Divers+'),('🦚','Divers+'),('🦛','Divers+'),('🦜','Divers+'),('🦝','Divers+'),('🦞','Divers+'),('🦟','Divers+'),('🦠','Divers+'),('🦡','Divers+'),('🦢','Divers+'),('🦣','Divers+'),('🦤','Divers+'),('🦥','Divers+'),('🦦','Divers+'),('🦧','Divers+'),('🦨','Divers+'),('🦩','Divers+'),('🦪','Divers+'),('🦫','Divers+'),('🦬','Divers+'),('🦭','Divers+'),('🦮','Divers+'),('🦯','Divers+'),('🦰','Divers+'),('🦱','Divers+'),('🦲','Divers+'),('🦳','Divers+'),('🦴','Divers+'),('🦵','Divers+'),('🦶','Divers+'),('🦷','Divers+'),('🦸','Divers+'),('🦹','Divers+'),('🦺','Divers+'),('🦻','Divers+'),('🦼','Divers+'),('🦽','Divers+'),('🦾','Divers+'),('🦿','Divers+'),('🧀','Divers+'),('🧁','Divers+'),('🧂','Divers+'),('🧃','Divers+'),('🧄','Divers+'),('🧅','Divers+'),('🧆','Divers+'),('🧇','Divers+'),('🧈','Divers+'),('🧉','Divers+'),('🧊','Divers+'),('🧋','Divers+'),('🧌','Divers+'),('🧍','Divers+'),('🧎','Divers+'),('🧏','Divers+'),('🧐','Divers+'),('🧑','Divers+'),('🧒','Divers+'),('🧓','Divers+'),('🧔','Divers+'),('🧕','Divers+'),('🧖','Divers+'),('🧗','Divers+'),('🧘','Divers+'),('🧙','Divers+'),('🧚','Divers+'),('🧛','Divers+'),('🧜','Divers+'),('🧝','Divers+'),('🧞','Divers+'),('🧟','Divers+'),('🧢','Divers+'),('🧣','Divers+'),('🧤','Divers+'),('🧥','Divers+'),('🧦','Divers+'),('🧧','Divers+'),('🧨','Divers+'),('🧩','Divers+'),('🧪','Divers+'),('🧫','Divers+'),('🧬','Divers+'),('🧭','Divers+'),('🧮','Divers+'),('🧯','Divers+'),('🧰','Divers+'),('🧱','Divers+'),('🧲','Divers+'),('🧳','Divers+'),('🧴','Divers+'),('🧵','Divers+'),('🧶','Divers+'),('🧷','Divers+'),('🧸','Divers+'),('🧹','Divers+'),('🧺','Divers+'),('🧻','Divers+'),('🧼','Divers+'),('🧽','Divers+'),('🧾','Divers+'),('🧿','Divers+'),('🩰','Divers+'),('🩱','Divers+'),('🩲','Divers+'),('🩳','Divers+'),('🩴','Divers+'),('🩵','Divers+'),('🩶','Divers+'),('🩷','Divers+'),('🩸','Divers+'),('🩹','Divers+'),('🩺','Divers+'),('🩻','Divers+'),('🩼','Divers+'),('🪀','Divers+'),('🪁','Divers+'),('🪂','Divers+'),('🪃','Divers+'),('🪄','Divers+'),('🪅','Divers+'),('🪆','Divers+'),('🪇','Divers+'),('🪈','Divers+'),('🪉','Divers+'),('🪏','Divers+'),('🪐','Divers+'),('🪑','Divers+'),('🪒','Divers+'),('🪓','Divers+'),('🪔','Divers+'),('🪕','Divers+'),('🪖','Divers+'),('🪗','Divers+'),('🪘','Divers+'),('🪙','Divers+'),('🪚','Divers+'),('🪛','Divers+'),('🪜','Divers+'),('🪝','Divers+'),('🪞','Divers+'),('🪟','Divers+'),('🪠','Divers+'),('🪡','Divers+'),('🪢','Divers+'),('🪣','Divers+'),('🪤','Divers+'),('🪥','Divers+'),('🪦','Divers+'),('🪧','Divers+'),('🪨','Divers+'),('🪩','Divers+'),('🪪','Divers+'),('🪫','Divers+'),('🪬','Divers+'),('🪭','Divers+'),('🪮','Divers+'),('🪯','Divers+'),('🪰','Divers+'),('🪱','Divers+'),('🪲','Divers+'),('🪳','Divers+'),('🪴','Divers+'),('🪵','Divers+'),('🪶','Divers+'),('🪷','Divers+'),('🪸','Divers+'),('🪹','Divers+'),('🪺','Divers+'),('🪻','Divers+'),('🪼','Divers+'),('🪽','Divers+'),('🪾','Divers+'),('🪿','Divers+'),('🫀','Divers+'),('🫁','Divers+'),('🫂','Divers+'),('🫃','Divers+'),('🫄','Divers+'),('🫅','Divers+'),('🫆','Divers+'),('🫎','Divers+'),('🫏','Divers+'),('🫐','Divers+'),('🫑','Divers+'),('🫒','Divers+'),('🫓','Divers+'),('🫔','Divers+'),('🫕','Divers+'),('🫖','Divers+'),('🫗','Divers+'),('🫘','Divers+'),('🫙','Divers+'),('🫚','Divers+'),('🫛','Divers+'),('🫜','Divers+'),('🫟','Divers+'),('🫠','Divers+'),('🫡','Divers+'),('🫢','Divers+'),('🫣','Divers+'),('🫤','Divers+'),('🫥','Divers+'),('🫦','Divers+'),('🫧','Divers+'),('🫨','Divers+'),('🫩','Divers+'),('🫰','Divers+'),('🫱','Divers+'),('🫲','Divers+'),('🫳','Divers+'),('🫴','Divers+'),('🫵','Divers+'),('🫶','Divers+'),('🫷','Divers+'),('🫸','Divers+'),('⌚','Divers+'),('⌛','Divers+'),('⏰','Divers+'),('⏳','Divers+'),('☔','Divers+'),('⚓','Divers+'),('⛄','Divers+'),('⛅','Divers+'),('⛎','Divers+'),('⛔','Divers+'),('⛪','Divers+'),('⛲','Divers+'),('⛳','Divers+'),('⛵','Divers+'),('⛺','Divers+'),('⛽','Divers+'),('✅','Divers+'),('✋','Divers+'),('❌','Divers+'),('❎','Divers+'),('❓','Divers+'),('❔','Divers+'),('❕','Divers+'),('❗','Divers+'),('➕','Divers+'),('➖','Divers+'),('➗','Divers+'),('➰','Divers+'),('➿','Divers+'),('⬛','Divers+'),('⬜','Divers+'),('⭕','Divers+') on conflict (code) do update set cat = excluded.cat;

-- ---------- E) Portefeuille, échange Romanomoney, administration ----------
create table if not exists public.panel_flags (user_id uuid primary key references public.profiles(id) on delete cascade, ext boolean not null default false, site boolean not null default false, at timestamptz not null default now());
alter table public.panel_flags enable row level security;
create table if not exists public.xchg (id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade, src text not null check (src in ('ext','site')),
  units int not null check (units between 1 and 100), nonce text not null unique, status text not null default 'open' check (status in ('open','done','cancelled')),
  created_at timestamptz not null default now(), done_at timestamptz);
alter table public.xchg enable row level security;

create or replace function public.panel_flag(p_where text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_where not in ('ext','site') then raise exception 'Source inconnue'; end if;
  insert into public.panel_flags(user_id, ext, site) values (auth.uid(), p_where = 'ext', p_where = 'site')
  on conflict (user_id) do update set ext = public.panel_flags.ext or (p_where = 'ext'), site = public.panel_flags.site or (p_where = 'site');
end $$;

create or replace function public.xchg_month_used(p_user uuid) returns int language sql security definer stable set search_path = public as $$
  select coalesce(sum(units), 0)::int from public.xchg where user_id = p_user
    and created_at >= date_trunc('month', now() at time zone 'America/Toronto') at time zone 'America/Toronto'
    and (status = 'done' or (status = 'open' and created_at > now() - interval '10 minutes')) $$;
revoke all on function public.xchg_month_used(uuid) from public, anon, authenticated;

create or replace function public.xchg_info()
returns jsonb language sql security definer stable set search_path = public as $$
  select jsonb_build_object('cap', public.cfg_n('xchg_month_cap'), 'used', public.xchg_month_used(auth.uid()), 'unit_tokens', public.cfg_n('xchg_unit_tokens'),
    'blocked', coalesce((select ext or site from public.panel_flags where user_id = auth.uid()), false)) $$;

create or replace function public.xchg_begin(p_src text, p_units int)
returns text language plpgsql security definer set search_path = public as $$
declare nonce text := public.rand_code(24); cap int := public.cfg_n('xchg_month_cap')::int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_src not in ('ext','site') then raise exception 'Source inconnue'; end if;
  if p_units is null or p_units < 1 then raise exception 'Quantité invalide'; end if;
  perform public.rate_ok('xchg', 30, 3600);
  if coalesce((select ext or site from public.panel_flags where user_id = auth.uid()), false) then raise exception 'Échange refusé : le panneau administrateur de Romanomoney a déjà été ouvert'; end if;
  if public.xchg_month_used(auth.uid()) + p_units > cap then raise exception 'Limite mensuelle : % échanges par mois', cap; end if;
  insert into public.xchg(user_id, src, units, nonce) values (auth.uid(), p_src, p_units, nonce);
  return nonce;
end $$;
create or replace function public.xchg_commit(p_nonce text)
returns numeric language plpgsql security definer set search_path = public as $$
declare x public.xchg; g numeric;
begin
  select * into x from public.xchg where nonce = p_nonce and user_id = auth.uid() for update;
  if not found or x.status <> 'open' then raise exception 'Échange introuvable'; end if;
  if coalesce((select ext or site from public.panel_flags where user_id = auth.uid()), false) then update public.xchg set status = 'cancelled' where id = x.id; raise exception 'Échange refusé'; end if;
  update public.xchg set status = 'done', done_at = now() where id = x.id;
  g := x.units * public.cfg_n('xchg_unit_tokens');
  return public.tok_add(auth.uid(), g, 'échange Romanomoney (' || x.units || ' x 1,60e1615)');
end $$;
create or replace function public.xchg_cancel(p_nonce text)
returns void language sql security definer set search_path = public as $$
  update public.xchg set status = 'cancelled' where nonce = p_nonce and user_id = auth.uid() and status = 'open' $$;

drop function if exists public.wallet_me();
create or replace function public.wallet_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare ds timestamptz;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  insert into public.daily_claims(user_id, day) values (auth.uid(), public.staff_today()) on conflict do nothing;
  perform public.badges_check(auth.uid());
  select last_at into ds from public.daily_state where user_id = auth.uid();
  return jsonb_build_object('balance', (select balance from public.wallets where user_id = auth.uid()),
    'daily_ready', ds is null or ds <= now() - interval '12 hours', 'daily_next', case when ds is null then null else ds + interval '12 hours' end,
    'refs', (select count(*) from public.referrals where referrer_id = auth.uid() and paid),
    'log', coalesce((select jsonb_agg(jsonb_build_object('delta', delta, 'reason', reason, 'at', at) order by id desc) from (select * from public.token_log where user_id = auth.uid() order by id desc limit 60) l), '[]'::jsonb));
end $$;

-- ---------- administration (administrateur et plus) ----------
drop function if exists public.admin_tokens(text, int, text);
create or replace function public.admin_tokens(p_username text, p_amount numeric, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 or p_amount <> round(p_amount, 1) then raise exception 'Montant invalide'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Raison obligatoire (demande d’indemnisation ou erreur)'; end if;
  v := public.staff_id_of(p_username);
  if p_amount < 0 and coalesce((select balance from public.wallets where user_id = v), 0) + p_amount < 0 then raise exception 'Solde insuffisant pour ce retrait'; end if;
  perform public.log_admin(case when p_amount > 0 then 'jetons_donnes' else 'jetons_retires' end, p_username, jsonb_build_object('montant', p_amount, 'raison', p_reason));
  return public.tok_add(v, p_amount, 'administration : ' || left(p_reason, 150), auth.uid());
end $$;
create or replace function public.admin_badge(p_username text, p_code text, p_give boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if not exists(select 1 from public.badge_defs where code = p_code) then raise exception 'Badge introuvable'; end if;
  if p_code = 'moderateur' then raise exception 'Le badge Modérateur est automatique'; end if;
  v := public.staff_id_of(p_username);
  if p_give then perform public.badge_grant(v, p_code, auth.uid());
  else delete from public.user_badges where user_id = v and code = p_code; update public.profile_ext set badges = array_remove(badges, p_code) where user_id = v; end if;
  perform public.log_admin(case when p_give then 'badge_donne' else 'badge_retire' end, p_username, jsonb_build_object('badge', p_code));
end $$;
create or replace function public.admin_item(p_username text, p_code text, p_give boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if not exists(select 1 from public.shop_items where code = p_code and kind <> 'credit') then raise exception 'Article introuvable'; end if;
  v := public.staff_id_of(p_username);
  if p_give then insert into public.inventory(user_id, code, source) values (v, p_code, 'administration') on conflict do nothing;
  else delete from public.inventory where user_id = v and code = p_code; end if;
  perform public.log_admin(case when p_give then 'article_donne' else 'article_retire' end, p_username, jsonb_build_object('article', p_code));
end $$;
create or replace function public.admin_wallet(p_username text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  v := public.staff_id_of(p_username);
  return jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = v), 0),
    'items', coalesce((select jsonb_agg(code) from public.inventory where user_id = v), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(code) from public.user_badges where user_id = v), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('delta', delta, 'reason', reason, 'at', at) order by id desc) from (select * from public.token_log where user_id = v order by id desc limit 30) l), '[]'::jsonb));
end $$;

-- ---------- droits : rien pour anon sauf la page d'invitation ----------
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
    and p.proname in ('game_win','daily_claim','quests_list','quest_event','quest_claim','bug_report','bug_list','bug_review','referral_code_me','referral_claim','referral_status_me','contest_list','contest_decide',
      'badge_union','badge_request','badge_requests_list','badge_request_decide','badges_equip','cosmetic_set','rename_me','shop_buy','shop_list','inventory_me','profile_full','cosmetics_of','pin_set','pins_me','has_item',
      'credits_list','emoji_premium_list','panel_flag','xchg_info','xchg_begin','xchg_commit','xchg_cancel','wallet_me','admin_tokens','admin_badge','admin_item','admin_wallet','referral_preview','referral_contest_anon','referral_contest_me','badge_json')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.proname = 'badge_json' then continue; end if;
    execute format('grant execute on function %s to authenticated', f.sig);
    if f.proname in ('referral_preview','referral_contest_anon') then execute format('grant execute on function %s to anon', f.sig); end if;
  end loop;
end $$;

-- ---------- F) Sécurité : profils verrouillés, droits minimaux, fonctions réservées aux connectés ----------
-- le nom, la date de création et l'identité d'un profil ne se modifient plus depuis le navigateur
create or replace function public.trg_profile_guard() returns trigger language plpgsql as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then new.created_at := now(); return new; end if;
  if new.id <> old.id then raise exception 'Identité non modifiable'; end if;
  new.created_at := old.created_at;
  if new.username is distinct from old.username then raise exception 'Le nom se change dans la boutique (jetons)'; end if;
  return new;
end $$;
drop trigger if exists profile_guard on public.profiles;
create trigger profile_guard before insert or update on public.profiles for each row execute function public.trg_profile_guard();
do $$ begin
  if not exists(select 1 from pg_constraint where conname = 'rmn_code_size') then
    alter table public.romanomoney_saves add constraint rmn_code_size check (char_length(code) < 400000) not valid;
  end if;
end $$;

-- droits sur les tables : rien pour anon, écriture directe uniquement là où une politique la prévoit
do $$ declare t record; begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p') loop
    execute format('revoke all on public.%I from anon', t.relname);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated', t.relname);
    execute format('alter table public.%I enable row level security', t.relname);
  end loop;
  revoke all on all sequences in schema public from anon;
  revoke insert, update, delete on public.admin_logs from authenticated;
end $$;
grant insert on public.messages to authenticated;
grant insert on public.user_keys to authenticated;
grant insert on public.romanomoney_saves to authenticated;
grant update on public.romanomoney_saves to authenticated;
grant insert on public.profiles to authenticated;
grant update (nickname, avatar_url, bio, last_seen, purity, purity_at) on public.profiles to authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke execute on functions from public;

-- fonctions : réservées aux utilisateurs connectés (sauf la page d'invitation du parrainage)
do $$ declare f record; begin
  for f in select p.oid, p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    if f.proname in ('referral_preview', 'referral_contest_anon') then execute format('grant execute on function %s to anon', f.sig); end if;
  end loop;
end $$;
