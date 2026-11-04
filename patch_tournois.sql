-- ============================================================================
-- Communicer! — Patch « tournois, e-Sport, cadres payants, surnoms » (additif, relançable)
-- À exécuter après patch_outils.sql, patch_droits.sql, patch_cadres.sql, patch_correctifs.sql, patch_hierarchie.sql.
-- ============================================================================

-- ---------- conversations fermées ----------
alter table public.conversations add column if not exists closed boolean not null default false;
create or replace function public.trg_conv_closed() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sender_id is not null and new.sender_id <> 'aaaaaaaa-0000-4000-8000-000000000001'::uuid and exists(select 1 from public.conversations where id = new.conversation_id and closed) then
    raise exception 'Cette conversation est fermée';
  end if;
  return new;
end $$;
drop trigger if exists aa_conv_closed on public.messages;
create trigger aa_conv_closed before insert on public.messages for each row execute function public.trg_conv_closed();

-- ---------- tournois : colonnes ----------
alter table public.tournaments add column if not exists descr text check (descr is null or char_length(descr) <= 1500);
alter table public.tournaments add column if not exists format text not null default 'single' check (format in ('single','elim','finals'));
alter table public.tournaments add column if not exists games text[] not null default '{}';
alter table public.tournaments add column if not exists visibility text not null default 'public' check (visibility in ('public','private'));
alter table public.tournaments add column if not exists code text;
alter table public.tournaments add column if not exists starts_at timestamptz;
alter table public.tournaments add column if not exists ends_at timestamptz;
alter table public.tournaments add column if not exists sched text not null default 'auto' check (sched in ('auto','manual'));
alter table public.tournaments add column if not exists stake int not null default 0 check (stake between 0 and 1000000);
alter table public.tournaments add column if not exists pool numeric(14,1) not null default 0 check (pool >= 0);
alter table public.tournaments add column if not exists restrictions jsonb not null default '{}'::jsonb;
alter table public.tournaments add column if not exists conv uuid references public.conversations(id) on delete set null;
alter table public.tournaments add column if not exists approval boolean not null default false;
alter table public.tournaments add column if not exists prize_text text check (prize_text is null or char_length(prize_text) <= 300);
create unique index if not exists tournaments_code_uq on public.tournaments(code) where code is not null;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.tournaments'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%' loop
    execute format('alter table public.tournaments drop constraint %I', c);
  end loop;
  alter table public.tournaments add constraint tournaments_status_chk check (status in ('open','running','done','cancelled'));
  alter table public.tournaments drop constraint if exists tournaments_max_n_check;
  alter table public.tournaments add constraint tournaments_max_n_check check (max_n between 2 and 128);
end $$;

alter table public.t_entries add column if not exists status text not null default 'joined' check (status in ('pending','invited','joined','disq','declined'));
alter table public.t_entries add column if not exists team text;
alter table public.t_entries add column if not exists paid int not null default 0;
alter table public.t_entries add column if not exists violations int not null default 0;
alter table public.t_entries add column if not exists reason text;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.t_entries'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' loop
    execute format('alter table public.t_entries drop constraint %I', c);
  end loop;
end $$;
alter table public.t_matches add column if not exists game text;
alter table public.t_matches add column if not exists at timestamptz;
alter table public.t_matches add column if not exists status text not null default 'scheduled' check (status in ('scheduled','invited','live','disputed','done','void'));
alter table public.t_matches add column if not exists join_by timestamptz;
alter table public.t_matches add column if not exists a_ok boolean not null default false;
alter table public.t_matches add column if not exists b_ok boolean not null default false;
alter table public.t_matches add column if not exists a_rep uuid;
alter table public.t_matches add column if not exists b_rep uuid;
alter table public.t_matches add column if not exists how text;
alter table public.t_matches add column if not exists note text;
create table if not exists public.t_scores (tid bigint not null references public.tournaments(id) on delete cascade, ref uuid not null, place int not null check (place between 1 and 999), note text, primary key (tid, ref));
create table if not exists public.t_team_invites (tid bigint not null references public.tournaments(id) on delete cascade, team_conv uuid not null references public.conversations(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')), at timestamptz not null default now(), primary key (tid, team_conv));
alter table public.t_scores enable row level security; alter table public.t_team_invites enable row level security;
revoke all on public.t_scores, public.t_team_invites from anon, authenticated;

-- ---------- utilitaires ----------
create or replace function public._ev_boss(p_tid bigint) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.tournaments where id = p_tid and creator = auth.uid()) or public.staff_rank_me() >= 4 $$;
create or replace function public._ev_name(p_user uuid) returns text language sql security definer stable set search_path = public as $$
  select coalesce(username, '?') from public.profiles where id = p_user $$;
revoke all on function public._ev_boss(bigint), public._ev_name(uuid) from public, anon, authenticated;

create or replace function public._ev_enter(p_tid bigint, p_user uuid, p_status text, p_team text default null) returns text language plpgsql security definer set search_path = public as $$
declare t public.tournaments; lbl text := '@' || public._ev_name(p_user) || case when p_team is not null then ' (équipe)' else '' end;
begin
  select * into t from public.tournaments where id = p_tid;
  if t.stake > 0 and p_status = 'joined' then
    if coalesce((select balance from public.wallets where user_id = p_user), 0) < t.stake then return 'funds'; end if;
    perform public.tok_add(p_user, -t.stake, 'mise du tournoi « ' || t.name || ' »', null);
    update public.tournaments set pool = pool + t.stake where id = p_tid;
  end if;
  insert into public.t_entries(tid, ref, kind, label, status, team, paid) values (p_tid, p_user, 'user', lbl, p_status, p_team, case when p_status = 'joined' then t.stake else 0 end)
  on conflict (tid, ref) do update set status = excluded.status, label = excluded.label, team = excluded.team, paid = excluded.paid;
  if p_status = 'joined' and t.conv is not null then
    insert into public.conversation_members(conversation_id, user_id, role) values (t.conv, p_user, 'member') on conflict do nothing;
  end if;
  return 'ok';
end $$;
revoke all on function public._ev_enter(bigint, uuid, text, text) from public, anon, authenticated;

create or replace function public._ev_say(p_tid bigint, p_text text) returns void language plpgsql security definer set search_path = public as $$
declare c uuid := (select conv from public.tournaments where id = p_tid);
begin
  if c is not null then insert into public.messages(conversation_id, sender_id, kind, body) values (c, 'aaaaaaaa-0000-4000-8000-000000000001', 'text', left(p_text, 2000)); end if;
exception when others then null;
end $$;
revoke all on function public._ev_say(bigint, text) from public, anon, authenticated;

-- ---------- création ----------
create or replace function public.ev_create(p_name text, p_descr text, p_format text, p_games text[], p_visibility text, p_sched text, p_starts timestamptz, p_ends timestamptz,
  p_max int, p_stake int, p_approval boolean, p_restrictions jsonb, p_prize text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare id bigint; cd text; cv uuid; n text := btrim(coalesce(p_name,''));
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public._need_right(auth.uid(), 'tournaments');
  if not (public._owns('tournaments') or public.staff_rank_me() >= 2) then raise exception 'Achetez d’abord « Tournois » dans la boutique'; end if;
  perform public.rate_ok('evc', 6, 3600);
  if char_length(n) not between 2 and 60 then raise exception 'Nom de 2 à 60 caractères'; end if;
  if p_format not in ('single','elim','finals') then raise exception 'Format inconnu'; end if;
  if coalesce(cardinality(p_games), 0) not between 1 and 12 then raise exception 'Choisissez de 1 à 12 jeux'; end if;
  if p_visibility not in ('public','private') or p_sched not in ('auto','manual') then raise exception 'Réglage inconnu'; end if;
  if p_starts is null or p_ends is null or p_starts <= now() or p_ends <= p_starts or p_ends > p_starts + interval '30 days' then raise exception 'Définissez un début futur et une fin (30 jours au maximum)'; end if;
  if p_max is null or p_max not between 2 and 128 then raise exception 'Entre 2 et 128 participants'; end if;
  if p_stake is null or p_stake < 0 or p_stake > 1000000 then raise exception 'Mise invalide'; end if;
  loop
    cd := public.rand_str(6, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789');
    exit when not exists(select 1 from public.tournaments where code = cd);
  end loop;
  insert into public.conversations(kind, mode, name, created_by) values ('group', 'clear', left('Tournoi · ' || n, 60), auth.uid()) returning conversations.id into cv;
  insert into public.conversation_members(conversation_id, user_id, role) values (cv, auth.uid(), 'admin');
  insert into public.tournaments(name, descr, format, games, visibility, sched, starts_at, ends_at, max_n, stake, approval, restrictions, prize_text, creator, code, conv, game)
  values (n, nullif(btrim(coalesce(p_descr,'')), ''), p_format, p_games, p_visibility, p_sched, p_starts, p_ends, p_max, p_stake, coalesce(p_approval, false),
          coalesce(p_restrictions, '{}'::jsonb), nullif(btrim(coalesce(p_prize,'')), ''), auth.uid(), cd, cv, p_games[1]) returning tournaments.id into id;
  return jsonb_build_object('id', id, 'code', cd);
end $$;

create or replace function public.ev_edit(p_id bigint, p_descr text, p_prize text, p_restrictions jsonb, p_games text[], p_starts timestamptz, p_ends timestamptz) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found or not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if t.status <> 'open' then raise exception 'Modifiable avant le lancement seulement'; end if;
  if coalesce(cardinality(p_games), 0) not between 1 and 12 then raise exception 'Choisissez de 1 à 12 jeux'; end if;
  if p_starts is null or p_ends is null or p_ends <= p_starts or p_ends > p_starts + interval '30 days' then raise exception 'Dates invalides'; end if;
  update public.tournaments set descr = nullif(btrim(coalesce(p_descr,'')), ''), prize_text = nullif(btrim(coalesce(p_prize,'')), ''), restrictions = coalesce(p_restrictions, '{}'::jsonb),
    games = p_games, game = p_games[1], starts_at = p_starts, ends_at = p_ends where id = p_id;
end $$;

-- ---------- lecture ----------
create or replace function public.ev_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'status', t.status, 'format', t.format, 'visibility', t.visibility, 'stake', t.stake,
      'starts_at', t.starts_at, 'ends_at', t.ends_at, 'n', (select count(*) from public.t_entries e where e.tid = t.id and e.status = 'joined'), 'max', t.max_n,
      'mine', t.creator = auth.uid(), 'in', exists(select 1 from public.t_entries e where e.tid = t.id and e.ref = auth.uid() and e.status in ('joined','pending','invited')),
      'by', public._ev_name(t.creator)) order by (t.status in ('open','running')) desc, t.starts_at desc nulls last, t.id desc)
    from (select * from public.tournaments x where x.status <> 'cancelled' and (x.visibility = 'public' or x.creator = auth.uid()
          or exists(select 1 from public.t_entries e where e.tid = x.id and e.ref = auth.uid())) order by x.id desc limit 100) t), '[]'::jsonb);
end $$;

create or replace function public.ev_get(p_id bigint) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare t public.tournaments; boss boolean; me public.t_entries;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into t from public.tournaments where id = p_id;
  if not found then raise exception 'Tournoi introuvable'; end if;
  boss := public._ev_boss(p_id);
  select * into me from public.t_entries where tid = p_id and ref = auth.uid();
  if t.visibility = 'private' and not boss and me.ref is null then raise exception 'Tournoi privé : utilisez son code'; end if;
  return jsonb_build_object('id', t.id, 'name', t.name, 'descr', t.descr, 'format', t.format, 'games', t.games, 'visibility', t.visibility, 'sched', t.sched, 'status', t.status,
    'starts_at', t.starts_at, 'ends_at', t.ends_at, 'max', t.max_n, 'stake', t.stake, 'pool', t.pool, 'approval', t.approval, 'restrictions', t.restrictions, 'prize', t.prize_text,
    'by', public._ev_name(t.creator), 'boss', boss, 'code', case when boss or me.status = 'joined' then t.code end, 'conv', case when boss or me.status = 'joined' then t.conv end,
    'me', case when me.ref is null then null else jsonb_build_object('status', me.status, 'reason', me.reason) end,
    'entries', coalesce((select jsonb_agg(jsonb_build_object('user', public._ev_name(e.ref), 'label', e.label, 'status', e.status, 'team', e.team, 'reason', e.reason) order by e.label)
        from public.t_entries e where e.tid = p_id and (boss or e.status in ('joined','disq'))), '[]'::jsonb),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'rnd', m.rnd, 'slot', m.slot, 'a', m.a_label, 'b', m.b_label, 'a_user', public._ev_name(m.a_ref), 'b_user', public._ev_name(m.b_ref),
        'winner', case when m.winner_ref is null then null else public._ev_name(m.winner_ref) end, 'game', m.game, 'at', m.at, 'status', m.status, 'join_by', m.join_by, 'a_ok', m.a_ok, 'b_ok', m.b_ok, 'how', m.how, 'note', m.note,
        'mine', m.a_ref = auth.uid() or m.b_ref = auth.uid()) order by m.rnd, m.slot) from public.t_matches m where m.tid = p_id), '[]'::jsonb),
    'scores', coalesce((select jsonb_agg(jsonb_build_object('user', public._ev_name(s.ref), 'place', s.place, 'note', s.note) order by s.place) from public.t_scores s where s.tid = p_id), '[]'::jsonb),
    'team_invites', case when boss then coalesce((select jsonb_agg(jsonb_build_object('team', x.name, 'status', i.status)) from public.t_team_invites i join public.esport_teams x on x.conv = i.team_conv where i.tid = p_id), '[]'::jsonb) else '[]'::jsonb end,
    'winner', t.winner);
end $$;

-- lien /event?cd=CODE (6 caractères) : aperçu pour rejoindre
create or replace function public.ev_by_code(p_code text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare t public.tournaments;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into t from public.tournaments where code = btrim(p_code) and status <> 'cancelled';
  if not found then raise exception 'Code de tournoi invalide'; end if;
  return jsonb_build_object('id', t.id, 'name', t.name, 'descr', t.descr, 'format', t.format, 'status', t.status, 'stake', t.stake, 'visibility', t.visibility, 'approval', t.approval,
    'starts_at', t.starts_at, 'ends_at', t.ends_at, 'by', public._ev_name(t.creator), 'n', (select count(*) from public.t_entries e where e.tid = t.id and e.status = 'joined'), 'max', t.max_n,
    'in', exists(select 1 from public.t_entries e where e.tid = t.id and e.ref = auth.uid() and e.status in ('joined','pending')));
end $$;

-- ---------- inscriptions ----------
create or replace function public.ev_join(p_id bigint, p_code text default null) returns text language plpgsql security definer set search_path = public as $$
declare t public.tournaments; e public.t_entries; r text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('evj', 30, 3600);
  select * into t from public.tournaments where id = p_id for update;
  if not found or t.status <> 'open' then raise exception 'Inscriptions fermées'; end if;
  if t.creator = auth.uid() then raise exception 'L’organisateur ne joue pas dans son tournoi'; end if;
  select * into e from public.t_entries where tid = p_id and ref = auth.uid();
  if t.visibility = 'private' and coalesce(p_code, '') <> t.code and e.status is distinct from 'invited' then raise exception 'Tournoi privé : code requis'; end if;
  if e.status in ('joined','pending') then raise exception 'Déjà inscrit'; end if;
  if e.status = 'disq' then raise exception 'Vous avez été disqualifié'; end if;
  if (select count(*) from public.t_entries where tid = p_id and status in ('joined','pending')) >= t.max_n then raise exception 'Tournoi complet'; end if;
  if t.approval and e.status is distinct from 'invited' then
    insert into public.t_entries(tid, ref, kind, label, status) values (p_id, auth.uid(), 'user', '@' || public._ev_name(auth.uid()), 'pending')
      on conflict (tid, ref) do update set status = 'pending';
    perform public.sys_notify(t.creator, '@' || public._ev_name(auth.uid()) || ' demande à rejoindre « ' || t.name || ' ». Validez dans Tournois.');
    return 'pending';
  end if;
  r := public._ev_enter(p_id, auth.uid(), 'joined');
  if r = 'funds' then raise exception 'Jetons insuffisants pour la mise (% jetons)', t.stake; end if;
  perform public._ev_say(p_id, '@' || public._ev_name(auth.uid()) || ' a rejoint le tournoi.');
  return 'joined';
end $$;

create or replace function public.ev_leave(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; e public.t_entries;
begin
  select * into t from public.tournaments where id = p_id for update;
  select * into e from public.t_entries where tid = p_id and ref = auth.uid();
  if not found or t.status <> 'open' then raise exception 'Désinscription impossible'; end if;
  if e.paid > 0 then perform public.tok_add(auth.uid(), e.paid, 'remboursement de la mise (« ' || t.name || ' »)', null); update public.tournaments set pool = greatest(0, pool - e.paid) where id = p_id; end if;
  delete from public.t_entries where tid = p_id and ref = auth.uid();
  delete from public.conversation_members where conversation_id = t.conv and user_id = auth.uid();
end $$;

create or replace function public.ev_approve(p_id bigint, p_username text, p_ok boolean) returns void language plpgsql security definer set search_path = public as $$
declare u uuid; r text; t public.tournaments;
begin
  if not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  select * into t from public.tournaments where id = p_id;
  select id into u from public.profiles where username = lower(regexp_replace(btrim(p_username), '^@', ''));
  if u is null or not exists(select 1 from public.t_entries where tid = p_id and ref = u and status = 'pending') then raise exception 'Demande introuvable'; end if;
  if not p_ok then update public.t_entries set status = 'declined' where tid = p_id and ref = u; perform public.sys_notify(u, 'Votre inscription à « ' || t.name || ' » a été refusée.'); return; end if;
  if (select count(*) from public.t_entries where tid = p_id and status = 'joined') >= t.max_n then raise exception 'Tournoi complet'; end if;
  r := public._ev_enter(p_id, u, 'joined');
  if r = 'funds' then raise exception 'Cette personne n’a pas assez de jetons pour la mise'; end if;
  perform public.sys_notify(u, 'Votre inscription à « ' || t.name || ' » est validée.');
end $$;

-- invitations de l'organisateur (personnes précises) : acceptation par la personne
create or replace function public.ev_invite(p_id bigint, p_users text[]) returns int language plpgsql security definer set search_path = public as $$
declare t public.tournaments; u text; uid uuid; n int := 0;
begin
  select * into t from public.tournaments where id = p_id;
  if not found or not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if t.status <> 'open' then raise exception 'Invitations avant le lancement seulement'; end if;
  perform public.rate_ok('evi', 20, 3600);
  foreach u in array coalesce(p_users, '{}') loop
    select id into uid from public.profiles where username = lower(regexp_replace(btrim(u), '^@', ''));
    if uid is null then raise exception 'Utilisateur introuvable : %', u; end if;
    if uid = t.creator or exists(select 1 from public.t_entries where tid = p_id and ref = uid and status in ('joined','pending','disq')) then continue; end if;
    insert into public.t_entries(tid, ref, kind, label, status) values (p_id, uid, 'user', '@' || public._ev_name(uid), 'invited') on conflict (tid, ref) do update set status = 'invited';
    perform public.sys_notify(uid, '@' || public._ev_name(t.creator) || ' vous invite au tournoi « ' || t.name || ' »' || case when t.stake > 0 then ' (mise : ' || t.stake || ' jetons)' else '' end || '. Ouvrez Tournois pour répondre.');
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.ev_invite_answer(p_id bigint, p_accept boolean) returns text language plpgsql security definer set search_path = public as $$
declare t public.tournaments; r text;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found or t.status <> 'open' then raise exception 'Invitation expirée'; end if;
  if not exists(select 1 from public.t_entries where tid = p_id and ref = auth.uid() and status = 'invited') then raise exception 'Aucune invitation'; end if;
  if not p_accept then update public.t_entries set status = 'declined' where tid = p_id and ref = auth.uid(); return 'declined'; end if;
  if (select count(*) from public.t_entries where tid = p_id and status = 'joined') >= t.max_n then raise exception 'Tournoi complet'; end if;
  r := public._ev_enter(p_id, auth.uid(), 'joined');
  if r = 'funds' then raise exception 'Jetons insuffisants pour la mise (% jetons)', t.stake; end if;
  return 'joined';
end $$;
create or replace function public.ev_my_invites() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'stake', t.stake, 'by', public._ev_name(t.creator))), '[]'::jsonb)
  from public.t_entries e join public.tournaments t on t.id = e.tid where e.ref = auth.uid() and e.status = 'invited' and t.status = 'open' $$;

-- équipes e-Sport : le gérant accepte ou non ; tous les membres deviennent participants « @username (équipe) »
create or replace function public.ev_team_invite(p_id bigint, p_team text) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; x public.esport_teams;
begin
  select * into t from public.tournaments where id = p_id;
  if not found or not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if t.status <> 'open' then raise exception 'Invitations avant le lancement seulement'; end if;
  select * into x from public.esport_teams where lower(name) = lower(btrim(p_team));
  if not found then raise exception 'Équipe e-Sport introuvable'; end if;
  insert into public.t_team_invites(tid, team_conv, status) values (p_id, x.conv, 'pending') on conflict (tid, team_conv) do update set status = 'pending', at = now();
  if x.owner is not null then perform public.sys_notify(x.owner, 'Votre équipe « ' || x.name || ' » est invitée au tournoi « ' || t.name || ' ». Répondez dans Tournois.'); end if;
end $$;
create or replace function public.ev_team_invites_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('tid', t.id, 'name', t.name, 'team', x.name, 'stake', t.stake)), '[]'::jsonb)
  from public.t_team_invites i join public.esport_teams x on x.conv = i.team_conv join public.tournaments t on t.id = i.tid
  where i.status = 'pending' and x.owner = auth.uid() and t.status = 'open' $$;
create or replace function public.ev_team_answer(p_id bigint, p_team text, p_accept boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.tournaments; x public.esport_teams; m record; skipped int := 0; added int := 0; room int;
begin
  select * into t from public.tournaments where id = p_id for update;
  select * into x from public.esport_teams where lower(name) = lower(btrim(p_team)) and owner = auth.uid();
  if not found or not exists(select 1 from public.t_team_invites where tid = p_id and team_conv = x.conv and status = 'pending') then raise exception 'Invitation introuvable'; end if;
  if t.status <> 'open' then raise exception 'Inscriptions fermées'; end if;
  if not p_accept then update public.t_team_invites set status = 'declined' where tid = p_id and team_conv = x.conv; return jsonb_build_object('added', 0, 'skipped', 0); end if;
  for m in select user_id from public.conversation_members where conversation_id = x.conv and user_id <> t.creator loop
    select t.max_n - count(*) into room from public.t_entries where tid = p_id and status in ('joined','pending');
    if room <= 0 or public._ev_enter(p_id, m.user_id, 'joined', x.name) <> 'ok' then skipped := skipped + 1; else added := added + 1; end if;
  end loop;
  update public.t_team_invites set status = 'accepted' where tid = p_id and team_conv = x.conv;
  perform public._ev_say(p_id, 'L’équipe « ' || x.name || ' » rejoint le tournoi (' || added || ' membre(s)).');
  return jsonb_build_object('added', added, 'skipped', skipped);
end $$;

-- ---------- lancement : tableau et horaire ----------
create or replace function public._ev_push(p_match bigint) returns void language plpgsql security definer set search_path = public as $$
declare m public.t_matches; lbl text; maxr int; t public.tournaments;
begin
  select * into m from public.t_matches where id = p_match;
  select * into t from public.tournaments where id = m.tid;
  lbl := case when m.winner_ref = m.a_ref then m.a_label else m.b_label end;
  select max(rnd) into maxr from public.t_matches where tid = m.tid and note is distinct from 'petite finale';
  if m.note = 'petite finale' then
    if not exists(select 1 from public.t_matches where tid = m.tid and winner_ref is null and status <> 'void') then perform public._ev_finish_now(m.tid); end if;
    return;
  end if;
  if m.rnd >= maxr then
    update public.tournaments set winner = lbl where id = m.tid;
    if not exists(select 1 from public.t_matches where tid = m.tid and winner_ref is null and status <> 'void') then perform public._ev_finish_now(m.tid); end if;
    return;
  end if;
  if m.slot % 2 = 1 then update public.t_matches set a_ref = m.winner_ref, a_label = lbl where tid = m.tid and rnd = m.rnd + 1 and slot = (m.slot + 1) / 2 and note is distinct from 'petite finale';
  else update public.t_matches set b_ref = m.winner_ref, b_label = lbl where tid = m.tid and rnd = m.rnd + 1 and slot = (m.slot + 1) / 2 and note is distinct from 'petite finale'; end if;
  -- petite finale : les perdants des demi-finales
  if t.format = 'finals' and m.rnd = maxr - 1 and maxr >= 2 then
    update public.t_matches set a_ref = case when m.slot = 1 then (case when m.winner_ref = m.a_ref then m.b_ref else m.a_ref end) else a_ref end,
      a_label = case when m.slot = 1 then (case when m.winner_ref = m.a_ref then m.b_label else m.a_label end) else a_label end,
      b_ref = case when m.slot = 2 then (case when m.winner_ref = m.a_ref then m.b_ref else m.a_ref end) else b_ref end,
      b_label = case when m.slot = 2 then (case when m.winner_ref = m.a_ref then m.b_label else m.a_label end) else b_label end
    where tid = m.tid and note = 'petite finale';
  end if;
end $$;
revoke all on function public._ev_push(bigint) from public, anon, authenticated;

create or replace function public._ev_finish_now(p_tid bigint) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments;
begin
  select * into t from public.tournaments where id = p_tid for update;
  if t.status = 'done' then return; end if;
  update public.tournaments set status = 'done' where id = p_tid;
  perform public._ev_say(p_tid, 'Tournoi terminé' || coalesce(' — vainqueur : ' || t.winner, '') || '. Cette conversation est maintenant fermée.');
  if t.conv is not null then update public.conversations set closed = true where id = t.conv; end if;
end $$;
revoke all on function public._ev_finish_now(bigint) from public, anon, authenticated;

create or replace function public.ev_start(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; n int; sz int := 2; rounds int := 1; r int; s int; arr uuid[]; lbl text[]; e record; slotlen interval; g int := 0; mid bigint; gm text;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found or not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if t.status <> 'open' then raise exception 'Tournoi déjà lancé'; end if;
  select count(*) into n from public.t_entries where tid = p_id and status = 'joined';
  if n < 2 then raise exception 'Il faut au moins 2 participants'; end if;
  update public.t_entries set status = 'declined' where tid = p_id and status in ('pending','invited');
  if t.format = 'single' then
    update public.tournaments set status = 'running' where id = p_id;
    perform public._ev_say(p_id, 'Tournoi lancé (partie unique : ' || t.games[1] || '). L’organisateur saisit le classement final.');
    return;
  end if;
  while sz < n loop sz := sz * 2; rounds := rounds + 1; end loop;
  select array_agg(ref), array_agg(label) into arr, lbl from (select ref, label from public.t_entries where tid = p_id and status = 'joined' order by random()) q;
  slotlen := (coalesce(t.ends_at, now() + interval '1 day') - greatest(coalesce(t.starts_at, now()), now())) / rounds;
  for r in 1..rounds loop
    for s in 1..(sz / (2 ^ r)::int) loop
      g := g + 1; gm := t.games[1 + (g - 1) % cardinality(t.games)];
      insert into public.t_matches(tid, rnd, slot, game, at, status) values (p_id, r, s, gm,
        case when t.sched = 'auto' then greatest(coalesce(t.starts_at, now()), now()) + slotlen * (r - 1) end, 'scheduled');
    end loop;
  end loop;
  if t.format = 'finals' and rounds >= 2 then
    insert into public.t_matches(tid, rnd, slot, game, at, status, note) values (p_id, rounds, 2, t.games[1 + (g) % cardinality(t.games)],
      case when t.sched = 'auto' then greatest(coalesce(t.starts_at, now()), now()) + slotlen * (rounds - 1) end, 'scheduled', 'petite finale');
  end if;
  for s in 1..(sz / 2) loop
    update public.t_matches set a_ref = arr[s], a_label = lbl[s], b_ref = arr[sz + 1 - s], b_label = lbl[sz + 1 - s] where tid = p_id and rnd = 1 and slot = s and note is null;
  end loop;
  update public.tournaments set status = 'running' where id = p_id;
  for e in select id from public.t_matches where tid = p_id and rnd = 1 and note is null and (a_ref is null or b_ref is null) and not (a_ref is null and b_ref is null) loop
    update public.t_matches set winner_ref = coalesce(a_ref, b_ref), status = 'done', how = 'bye' where id = e.id;
    perform public._ev_push(e.id);
  end loop;
  perform public._ev_say(p_id, 'Tournoi lancé (' || n || ' participants, ' || rounds || ' tour(s)). Les invitations aux matchs sont envoyées à l’heure prévue.');
end $$;

-- ---------- horloge : invitations aux matchs (120 s), forfaits, fin du temps ----------
create or replace function public.ev_tick(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; m record; loser uuid; win uuid;
begin
  select * into t from public.tournaments where id = p_id;
  if not found or t.status <> 'running' then return; end if;
  -- matchs à l'heure : invitation
  for m in select * from public.t_matches where tid = p_id and status = 'scheduled' and at is not null and at <= now() and a_ref is not null and b_ref is not null and winner_ref is null for update loop
    update public.t_matches set status = 'invited', join_by = now() + interval '120 seconds', a_ok = false, b_ok = false where id = m.id;
    perform public.sys_notify(m.a_ref, 'Match « ' || t.name || ' » : ' || m.a_label || ' contre ' || m.b_label || ' (' || m.game || '). Vous avez 120 secondes pour rejoindre : ouvrez Tournois.');
    perform public.sys_notify(m.b_ref, 'Match « ' || t.name || ' » : ' || m.a_label || ' contre ' || m.b_label || ' (' || m.game || '). Vous avez 120 secondes pour rejoindre : ouvrez Tournois.');
    perform public._ev_say(p_id, 'Match ' || m.a_label || ' contre ' || m.b_label || ' (' || m.game || ') : 120 secondes pour rejoindre.');
  end loop;
  -- délai dépassé : disqualification de celui qui n'est pas venu
  for m in select * from public.t_matches where tid = p_id and status = 'invited' and join_by < now() for update loop
    if m.a_ok and not m.b_ok then win := m.a_ref; loser := m.b_ref;
    elsif m.b_ok and not m.a_ok then win := m.b_ref; loser := m.a_ref;
    else win := null; end if;
    if win is null then
      update public.t_matches set status = 'void', note = 'Aucun joueur présent : l’organisateur décide' where id = m.id;
      perform public.sys_notify(t.creator, 'Match sans joueur présent dans « ' || t.name || ' » : décidez du résultat dans Tournois.');
    else
      update public.t_entries set status = 'disq', reason = 'Absent du match (120 s)' where tid = p_id and ref = loser;
      update public.t_matches set winner_ref = win, status = 'done', how = 'forfait' where id = m.id;
      perform public._ev_push(m.id);
      perform public._ev_say(p_id, public._ev_name(loser) || ' est disqualifié (120 secondes écoulées).');
    end if;
  end loop;
  -- fin du temps imparti
  if t.ends_at is not null and t.ends_at < now() - interval '1 hour' then perform public._ev_finish_now(p_id); end if;
end $$;
create or replace function public.ev_mine_live() returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  for r in select distinct tid from public.t_matches where (a_ref = auth.uid() or b_ref = auth.uid()) and status in ('scheduled','invited','live') loop perform public.ev_tick(r.tid); end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('match', m.id, 'tid', m.tid, 'name', t.name, 'game', m.game, 'a', m.a_label, 'b', m.b_label, 'a_user', public._ev_name(m.a_ref), 'b_user', public._ev_name(m.b_ref),
      'status', m.status, 'join_by', m.join_by, 'ack', case when m.a_ref = auth.uid() then m.a_ok else m.b_ok end, 'both', m.a_ok and m.b_ok, 'conv', t.conv, 'restrictions', t.restrictions)
    order by m.id) from public.t_matches m join public.tournaments t on t.id = m.tid
    where (m.a_ref = auth.uid() or m.b_ref = auth.uid()) and m.status in ('invited','live') and t.status = 'running'), '[]'::jsonb);
end $$;

create or replace function public.ev_launch(p_match bigint) returns void language plpgsql security definer set search_path = public as $$
declare m public.t_matches; t public.tournaments;
begin
  select * into m from public.t_matches where id = p_match for update;
  if not found or not public._ev_boss(m.tid) then raise exception 'Réservé à l’organisateur'; end if;
  select * into t from public.tournaments where id = m.tid;
  if t.status <> 'running' or m.a_ref is null or m.b_ref is null or m.status not in ('scheduled','void') or m.winner_ref is not null then raise exception 'Match non lançable'; end if;
  update public.t_matches set status = 'scheduled', at = now() where id = p_match;
  perform public.ev_tick(m.tid);
end $$;
create or replace function public.ev_ack(p_match bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.t_matches;
begin
  select * into m from public.t_matches where id = p_match for update;
  if not found or auth.uid() not in (coalesce(m.a_ref, auth.uid()), coalesce(m.b_ref, auth.uid())) or (m.a_ref is distinct from auth.uid() and m.b_ref is distinct from auth.uid()) then raise exception 'Match introuvable'; end if;
  if m.status <> 'invited' then raise exception 'Ce match n’attend plus de joueurs'; end if;
  if m.join_by < now() then raise exception 'Délai de 120 secondes dépassé'; end if;
  if m.a_ref = auth.uid() then update public.t_matches set a_ok = true where id = p_match; else update public.t_matches set b_ok = true where id = p_match; end if;
  select * into m from public.t_matches where id = p_match;
  if m.a_ok and m.b_ok then update public.t_matches set status = 'live' where id = p_match; end if;
  return jsonb_build_object('live', m.a_ok and m.b_ok);
end $$;

-- ---------- résultats ----------
create or replace function public._ev_decide(p_match bigint, p_win uuid, p_how text) returns void language plpgsql security definer set search_path = public as $$
declare m public.t_matches;
begin
  update public.t_matches set winner_ref = p_win, status = 'done', how = p_how where id = p_match and winner_ref is null returning * into m;
  if found then
    perform public._ev_push(p_match);
    perform public._ev_say(m.tid, 'Résultat : ' || case when p_win = m.a_ref then m.a_label else m.b_label end || ' remporte le match (' || m.game || ').');
  end if;
end $$;
revoke all on function public._ev_decide(bigint, uuid, text) from public, anon, authenticated;

-- les deux joueurs rapportent (automatiquement à la fin de la partie) : accord = résultat ; désaccord = l'organisateur tranche
create or replace function public.ev_report(p_conv uuid, p_winner text) returns text language plpgsql security definer set search_path = public as $$
declare m public.t_matches; w uuid; t public.tournaments;
begin
  select * into t from public.tournaments where conv = p_conv and status = 'running';
  if not found then return 'none'; end if;
  select id into w from public.profiles where username = lower(regexp_replace(btrim(coalesce(p_winner,'')), '^@', ''));
  select * into m from public.t_matches where tid = t.id and status = 'live' and (a_ref = auth.uid() or b_ref = auth.uid()) order by id limit 1 for update;
  if not found or w is null or w not in (m.a_ref, m.b_ref) then return 'none'; end if;
  if m.a_ref = auth.uid() then update public.t_matches set a_rep = w where id = m.id; else update public.t_matches set b_rep = w where id = m.id; end if;
  select * into m from public.t_matches where id = m.id;
  if m.a_rep is not null and m.b_rep is not null then
    if m.a_rep = m.b_rep then perform public._ev_decide(m.id, m.a_rep, 'auto'); return 'done';
    else update public.t_matches set status = 'disputed' where id = m.id; perform public.sys_notify(t.creator, 'Résultats contradictoires dans « ' || t.name || ' » : tranchez dans Tournois.'); return 'disputed'; end if;
  end if;
  return 'waiting';
end $$;
create or replace function public.ev_result(p_match bigint, p_winner text, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare m public.t_matches; w uuid;
begin
  select * into m from public.t_matches where id = p_match for update;
  if not found or not public._ev_boss(m.tid) then raise exception 'Réservé à l’organisateur'; end if;
  select id into w from public.profiles where username = lower(regexp_replace(btrim(coalesce(p_winner,'')), '^@', ''));
  if w is null or w not in (coalesce(m.a_ref, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(m.b_ref, '00000000-0000-0000-0000-000000000000'::uuid)) then raise exception 'Vainqueur invalide'; end if;
  if m.winner_ref is not null then raise exception 'Match déjà joué'; end if;
  update public.t_matches set note = left(p_note, 200) where id = p_match;
  perform public._ev_decide(p_match, w, 'organisateur');
end $$;
-- partie unique : classement saisi par l'organisateur
create or replace function public.ev_place(p_id bigint, p_username text, p_place int, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  select id into u from public.profiles where username = lower(regexp_replace(btrim(coalesce(p_username,'')), '^@', ''));
  if u is null or not exists(select 1 from public.t_entries where tid = p_id and ref = u and status = 'joined') then raise exception 'Participant introuvable'; end if;
  if p_place is null or p_place < 1 or p_place > 999 then raise exception 'Place invalide'; end if;
  insert into public.t_scores(tid, ref, place, note) values (p_id, u, p_place, left(p_note, 100)) on conflict (tid, ref) do update set place = excluded.place, note = excluded.note;
  if p_place = 1 then update public.tournaments set winner = '@' || p_username where id = p_id; end if;
end $$;
create or replace function public.ev_disq(p_id bigint, p_username text, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid; m record; t public.tournaments;
begin
  if not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if char_length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'Indiquez la raison'; end if;
  select id into u from public.profiles where username = lower(regexp_replace(btrim(coalesce(p_username,'')), '^@', ''));
  select * into t from public.tournaments where id = p_id;
  if u is null or not exists(select 1 from public.t_entries where tid = p_id and ref = u and status = 'joined') then raise exception 'Participant introuvable'; end if;
  update public.t_entries set status = 'disq', reason = left(p_reason, 200) where tid = p_id and ref = u;
  for m in select * from public.t_matches where tid = p_id and winner_ref is null and (a_ref = u or b_ref = u) and a_ref is not null and b_ref is not null loop
    perform public._ev_decide(m.id, case when m.a_ref = u then m.b_ref else m.a_ref end, 'forfait');
  end loop;
  perform public.sys_notify(u, 'Vous avez été disqualifié de « ' || t.name || ' » : ' || left(p_reason, 200));
  perform public._ev_say(p_id, '@' || btrim(p_username) || ' est disqualifié.');
end $$;
-- infraction aux restrictions (réduire l'appel, quitter la fenêtre…) : trois avertissements puis disqualification
create or replace function public.ev_violation(p_conv uuid, p_kind text) returns int language plpgsql security definer set search_path = public as $$
declare t public.tournaments; v int;
begin
  select * into t from public.tournaments where conv = p_conv and status = 'running';
  if not found or not (t.restrictions ? p_kind) then return 0; end if;
  update public.t_entries set violations = violations + 1 where tid = t.id and ref = auth.uid() and status = 'joined' returning violations into v;
  if v is null then return 0; end if;
  if v >= 3 then perform public.ev_disq(t.id, public._ev_name(auth.uid()), 'Restrictions non respectées (' || p_kind || ')'); end if;
  return v;
exception when others then return coalesce(v, 0);
end $$;

-- ---------- argent ----------
create or replace function public.ev_fund(p_id bigint, p_amount int) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found or t.creator is distinct from auth.uid() then raise exception 'Réservé à l’organisateur'; end if;
  if t.status = 'cancelled' then raise exception 'Tournoi annulé'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Montant invalide'; end if;
  perform public.rate_ok('evf', 20, 3600);
  perform public.tok_add(auth.uid(), -p_amount, 'prix ajouté au tournoi « ' || t.name || ' »', null);
  update public.tournaments set pool = pool + p_amount where id = p_id;
end $$;
create or replace function public.ev_payout(p_id bigint, p_username text, p_amount int) returns numeric language plpgsql security definer set search_path = public as $$
declare t public.tournaments; u uuid;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found or not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if t.status = 'cancelled' then raise exception 'Tournoi annulé'; end if;
  if p_amount is null or p_amount < 1 then raise exception 'Montant invalide'; end if;
  if p_amount > t.pool then raise exception 'La cagnotte ne contient que % jetons', t.pool; end if;
  perform public.rate_ok('evp', 40, 3600);
  select id into u from public.profiles where username = lower(regexp_replace(btrim(coalesce(p_username,'')), '^@', ''));
  if u is null then raise exception 'Utilisateur introuvable'; end if;
  update public.tournaments set pool = pool - p_amount where id = p_id;
  perform public.tok_add(u, p_amount, 'gain du tournoi « ' || t.name || ' »', null);
  perform public.sys_notify(u, 'Vous recevez ' || p_amount || ' jetons du tournoi « ' || t.name || ' ».');
  perform public._ev_say(p_id, '@' || btrim(p_username) || ' reçoit ' || p_amount || ' jetons de la cagnotte.');
  return t.pool - p_amount;
end $$;
create or replace function public.ev_finish(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if not exists(select 1 from public.tournaments where id = p_id and status = 'running') then raise exception 'Tournoi non en cours'; end if;
  perform public._ev_finish_now(p_id);
end $$;
create or replace function public.ev_cancel(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; e record; back numeric := 0;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found or not public._ev_boss(p_id) then raise exception 'Réservé à l’organisateur'; end if;
  if t.status in ('done','cancelled') then raise exception 'Tournoi déjà terminé'; end if;
  for e in select ref, paid from public.t_entries where tid = p_id and paid > 0 loop
    perform public.tok_add(e.ref, e.paid, 'remboursement : tournoi « ' || t.name || ' » annulé', null); back := back + e.paid;
  end loop;
  if t.pool - back > 0 then perform public.tok_add(t.creator, t.pool - back, 'prix restitué : tournoi « ' || t.name || ' » annulé', null); end if;
  update public.tournaments set status = 'cancelled', pool = 0 where id = p_id;
  if t.conv is not null then update public.conversations set closed = true where id = t.conv; end if;
end $$;

revoke all on function public.ev_create(text,text,text,text[],text,text,timestamptz,timestamptz,int,int,boolean,jsonb,text), public.ev_edit(bigint,text,text,jsonb,text[],timestamptz,timestamptz),
  public.ev_list(), public.ev_get(bigint), public.ev_by_code(text), public.ev_join(bigint,text), public.ev_leave(bigint), public.ev_approve(bigint,text,boolean), public.ev_invite(bigint,text[]),
  public.ev_invite_answer(bigint,boolean), public.ev_my_invites(), public.ev_team_invite(bigint,text), public.ev_team_invites_mine(), public.ev_team_answer(bigint,text,boolean), public.ev_start(bigint),
  public.ev_tick(bigint), public.ev_mine_live(), public.ev_launch(bigint), public.ev_ack(bigint), public.ev_report(uuid,text), public.ev_result(bigint,text,text), public.ev_place(bigint,text,int,text),
  public.ev_disq(bigint,text,text), public.ev_violation(uuid,text), public.ev_fund(bigint,int), public.ev_payout(bigint,text,int), public.ev_finish(bigint), public.ev_cancel(bigint) from public, anon;
grant execute on function public.ev_create(text,text,text,text[],text,text,timestamptz,timestamptz,int,int,boolean,jsonb,text), public.ev_edit(bigint,text,text,jsonb,text[],timestamptz,timestamptz),
  public.ev_list(), public.ev_get(bigint), public.ev_by_code(text), public.ev_join(bigint,text), public.ev_leave(bigint), public.ev_approve(bigint,text,boolean), public.ev_invite(bigint,text[]),
  public.ev_invite_answer(bigint,boolean), public.ev_my_invites(), public.ev_team_invite(bigint,text), public.ev_team_invites_mine(), public.ev_team_answer(bigint,text,boolean), public.ev_start(bigint),
  public.ev_tick(bigint), public.ev_mine_live(), public.ev_launch(bigint), public.ev_ack(bigint), public.ev_report(uuid,text), public.ev_result(bigint,text,text), public.ev_place(bigint,text,int,text),
  public.ev_disq(bigint,text,text), public.ev_violation(uuid,text), public.ev_fund(bigint,int), public.ev_payout(bigint,text,int), public.ev_finish(bigint), public.ev_cancel(bigint) to authenticated;
