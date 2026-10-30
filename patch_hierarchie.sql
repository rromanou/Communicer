-- ============================================================================
-- Communicer! — Patch 9 (additif, relançable) : hiérarchie des administrateurs
-- Commandant > Chef des administrateurs > Administrateur > Administrateur élève
-- (en base : moderator = élève, admin = administrateur, chief = chef, commander = commandant)
-- À exécuter après patch_bots3.sql.
-- ============================================================================

-- ---------- 1) Rôles ----------
do $$ declare c text; begin
  select conname into c from pg_constraint where conrelid = 'public.site_staff'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%moderator%';
  if c is not null then execute format('alter table public.site_staff drop constraint %I', c); end if;
end $$;
alter table public.site_staff add constraint site_staff_role_chk check (role in ('moderator','admin','chief','commander'));
alter table public.site_staff add column if not exists rank_at timestamptz not null default now();
alter table public.site_staff add column if not exists warnings int not null default 0;
alter table public.site_staff add column if not exists deadline timestamptz;
alter table public.site_staff add column if not exists deadline_kind text;      -- 'grad' (45 jours) | 'weekly' (2 heures)
alter table public.site_staff add column if not exists deficit jsonb;           -- ce qu'il reste à faire pendant les 2 heures
alter table public.site_staff add column if not exists beat_at timestamptz;
alter table public.site_staff add column if not exists grad_passed_at timestamptz;
create unique index if not exists site_staff_one_commander on public.site_staff((role)) where role = 'commander';

create or replace function public.staff_rank(p_role text) returns int language sql immutable as $$
  select case p_role when 'moderator' then 1 when 'admin' then 2 when 'chief' then 3 when 'commander' then 4 else 0 end
$$;
create or replace function public.staff_rank_of(p_user uuid) returns int language sql security definer stable set search_path = public as $$
  select coalesce((select public.staff_rank(role) from public.site_staff where user_id = p_user), 0)
$$;
create or replace function public.staff_rank_me() returns int language sql security definer stable set search_path = public as $$
  select public.staff_rank_of(auth.uid())
$$;
create or replace function public.is_staff(p_min text default 'moderator') returns boolean language sql security definer stable set search_path = public as $$
  select public.staff_rank_me() >= public.staff_rank(p_min)
$$;
update public.site_staff set role = 'commander' where user_id = (select id from public.profiles where username = 'rhum') and not exists(select 1 from public.site_staff where role = 'commander');

create table if not exists public.staff_blacklist (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  reason text not null, at timestamptz not null default now(), by_id uuid references public.profiles(id) on delete set null
);
alter table public.staff_blacklist enable row level security;

create table if not exists public.staff_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  target_role text not null check (target_role in ('admin','chief')),
  status text not null default 'pending' check (status in ('pending','accepted','refused')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz, note text
);
alter table public.staff_requests enable row level security;
create table if not exists public.staff_quiz (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('grad','weekly')),
  status text not null default 'open' check (status in ('open','passed','failed','violation')),
  started_at timestamptz not null default now(), beat_at timestamptz not null default now(), ended_at timestamptz,
  week date, plan jsonb not null default '[]'::jsonb, score int, reason text
);
alter table public.staff_quiz enable row level security;

create or replace function public.staff_today() returns date language sql stable as $$ select (now() at time zone 'America/Toronto')::date $$;
create or replace function public.staff_week(p_d date default public.staff_today()) returns date language sql stable as $$ select date_trunc('week', p_d::timestamp)::date $$;
create or replace function public.norm_txt(t text) returns text language sql immutable as $$
  select translate(lower(coalesce(t,'')), 'àâäçéèêëîïôöùûüÿœ', 'aaaceeeeiioouuuyo')
$$;

-- ---------- 2) Bannissements : règles par rang ----------
create or replace function public.ban_state(p_user uuid default auth.uid())
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare b public.site_bans; v_ip text := public.req_ip(); v_rank int := public.staff_rank_of(p_user);
begin
  if v_rank >= 3 then return jsonb_build_object('banned', false); end if;          -- chef et commandant : jamais bannis
  select * into b from public.site_bans sb
   where sb.lifted_at is null and (sb.until is null or sb.until > now())
     and (sb.user_id = p_user or (sb.ip is not null and sb.ip = v_ip and v_rank < 2))   -- les administrateurs ne sont pas touchés par les bans d'IP
   order by (sb.until is null) desc, sb.until desc limit 1;
  if not found then return jsonb_build_object('banned', false); end if;
  return jsonb_build_object('banned', true, 'until', b.until, 'reason', b.reason, 'ip_ban', b.user_id is null);
end $$;

create or replace function public.staff_ban(p_username text, p_ip text, p_secs numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid; v_ip text := nullif(trim(coalesce(p_ip,'')), ''); me int := public.staff_rank_me(); tr int := 0;
begin
  if me < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  if v_ip is not null and me < 3 then raise exception 'Seul le chef des administrateurs peut bannir une adresse IP'; end if;
  if nullif(trim(coalesce(p_username,'')),'') is not null then
    select id into v from public.profiles where username = lower(regexp_replace(trim(p_username), '^@', ''));
    if v is null then raise exception 'Utilisateur introuvable'; end if;
    if v = auth.uid() then raise exception 'Vous ne pouvez pas vous bannir'; end if;
    tr := public.staff_rank_of(v);
    if tr >= 4 then raise exception 'Le commandant ne peut pas être banni'; end if;
    if tr >= me then raise exception 'Vous ne pouvez pas bannir un rang égal ou supérieur au vôtre'; end if;
  elsif v_ip is null then raise exception 'Indiquez un utilisateur ou une IP';
  end if;
  if p_secs is null or p_secs < 0 then raise exception 'Durée invalide'; end if;
  insert into public.site_bans(user_id, ip, until, reason, by_id) values (v, v_ip, case when p_secs = 0 then null else now() + make_interval(secs => p_secs::double precision) end, left(p_reason, 300), auth.uid());
  perform public.log_admin(case when v is not null and v_ip is not null then 'ban_user_ip' when v is not null then 'ban_user' else 'ban_ip' end,
    coalesce(p_username, '(IP)'), jsonb_build_object('secs', p_secs, 'reason', p_reason, 'ip', case when me >= 3 then v_ip end));
end $$;

create or replace function public.staff_ban_user_ips(p_username text, p_secs numeric, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
declare v uuid; r record; n int := 0; me int := public.staff_rank_me();
begin
  if me < 3 then raise exception 'Seul le chef des administrateurs peut bannir des adresses IP'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(p_username), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  if v = auth.uid() or public.staff_rank_of(v) >= me then raise exception 'Cible protégée'; end if;
  for r in select distinct ip from public.user_ips where user_id = v loop
    insert into public.site_bans(ip, until, reason, by_id) values (r.ip, case when p_secs = 0 then null else now() + make_interval(secs => p_secs::double precision) end, left(coalesce(p_reason,''), 300), auth.uid());
    n := n + 1;
  end loop;
  perform public.log_admin('ban_ips_utilisateur', p_username, jsonb_build_object('n', n, 'secs', p_secs, 'reason', p_reason));
  return n;
end $$;

create or replace function public.staff_unban(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare b public.site_bans; me int := public.staff_rank_me();
begin
  if me < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select * into b from public.site_bans where id = p_id and lifted_at is null;
  if not found then raise exception 'Bannissement introuvable'; end if;
  if b.ip is not null and me < 3 then raise exception 'Seul le chef des administrateurs peut lever un bannissement d’adresse IP'; end if;
  update public.site_bans set lifted_at = now(), lifted_by = auth.uid() where id = p_id;
  perform public.log_admin('deban', '#' || p_id::text, jsonb_build_object('ip', b.ip is not null));
end $$;

create or replace function public.staff_ban_list()
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare me int := public.staff_rank_me();
begin
  if me < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'user', (select username from public.profiles where id = b.user_id),
     'ip', case when me >= 3 then b.ip end, 'ip_ban', b.ip is not null, 'until', b.until,
     'reason', b.reason, 'by', (select username from public.profiles where id = b.by_id), 'created_at', b.created_at,
     'active', b.lifted_at is null and (b.until is null or b.until > now()), 'lifted_at', b.lifted_at) order by b.id desc) from public.site_bans b), '[]'::jsonb);
end $$;

create or replace function public.staff_user_ips(p_username text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(p_username), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  perform public.log_admin('voir_ips', p_username, '{}'::jsonb);
  return coalesce((select jsonb_agg(jsonb_build_object('ip', ip, 'signup', is_signup, 'first', first_seen, 'last', last_seen) order by last_seen desc) from public.user_ips where user_id = v), '[]'::jsonb);
end $$;

-- Exceptions Ciffron : chef des administrateurs et commandant
create or replace function public.ciffron_exception_add(p_code text, p_note text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if not public.is_staff('chief') then raise exception 'Réservé au chef des administrateurs'; end if;
  if char_length(trim(coalesce(p_code,''))) = 0 then raise exception 'Code vide'; end if;
  insert into public.ciffron_exceptions(code, note, added_by) values (p_code, left(coalesce(p_note,''), 500), auth.uid()) returning id into v;
  insert into public.ciffron_exception_log(exception_id, action, code, note, staff_id, staff_name)
  values (v, 'ajout', p_code, p_note, auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('ciffron_exception_ajout', '#' || v::text, jsonb_build_object('code', p_code, 'note', p_note));
  return v;
end $$;
create or replace function public.ciffron_exception_remove(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare e public.ciffron_exceptions;
begin
  if not public.is_staff('chief') then raise exception 'Réservé au chef des administrateurs'; end if;
  update public.ciffron_exceptions set removed_at = now() where id = p_id and removed_at is null returning * into e;
  if not found then raise exception 'Exception introuvable'; end if;
  insert into public.ciffron_exception_log(exception_id, action, code, note, staff_id, staff_name)
  values (p_id, 'retrait', e.code, e.note, auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('ciffron_exception_retrait', '#' || p_id::text, jsonb_build_object('code', e.code));
end $$;
create or replace function public.ciffron_allow_set(p_rule text, p_bot uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff('chief') then raise exception 'Réservé au chef des administrateurs'; end if;
  if p_on then insert into public.ciffron_allow(rule, bot_id) values (p_rule, p_bot) on conflict do nothing;
  else delete from public.ciffron_allow where rule = p_rule and bot_id is not distinct from p_bot; end if;
  perform public.log_admin('ciffron_allow', p_rule, jsonb_build_object('bot', p_bot, 'on', p_on));
end $$;

-- ---------- 3) Activité réelle, journaux consultés ----------
create table if not exists public.staff_activity (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  secs int not null default 0,
  journals int not null default 0,
  primary key (user_id, day)
);
alter table public.staff_activity enable row level security;

create table if not exists public.staff_week_log (   -- semaines déjà évaluées (idempotence)
  user_id uuid not null references public.profiles(id) on delete cascade,
  week date not null, ok boolean not null, detail jsonb, at timestamptz not null default now(),
  primary key (user_id, week)
);
alter table public.staff_week_log enable row level security;
create table if not exists public.staff_weekly_quiz (
  user_id uuid not null references public.profiles(id) on delete cascade,
  week date not null, passed boolean not null default false, attempts int not null default 0, last_day date,
  primary key (user_id, week)
);
alter table public.staff_weekly_quiz enable row level security;

create or replace function public.staff_deficit_dec(p_user uuid, p_key text, p_n numeric)
returns void language plpgsql security definer set search_path = public as $$
declare s public.site_staff; d jsonb;
begin
  select * into s from public.site_staff where user_id = p_user for update;
  if not found or s.deadline_kind is distinct from 'weekly' or s.deficit is null then return; end if;
  d := jsonb_set(s.deficit, array[p_key], to_jsonb(greatest(0, coalesce((s.deficit->>p_key)::numeric, 0) - p_n)));
  if coalesce((d->>'secs')::numeric,0) <= 0 and coalesce((d->>'journals')::numeric,0) <= 0 and coalesce((d->>'quiz')::numeric,0) <= 0 then
    update public.site_staff set deficit = null, deadline = null, deadline_kind = null where user_id = p_user;
    insert into public.admin_logs(staff_id, staff_name, action, target, detail) values (p_user, (select username from public.profiles where id = p_user), 'conditions_remplies', 'delai_2h', '{}'::jsonb);
  else update public.site_staff set deficit = d where user_id = p_user; end if;
end $$;

create or replace function public.staff_beat(p_secs int default 30)
returns void language plpgsql security definer set search_path = public as $$
declare s public.site_staff; v int;
begin
  select * into s from public.site_staff where user_id = auth.uid() for update;
  if not found then return; end if;
  if s.beat_at is not null and now() - s.beat_at < interval '20 seconds' then return; end if;
  v := least(greatest(coalesce(p_secs,0),0), 40, case when s.beat_at is null then 40 else ceil(extract(epoch from now() - s.beat_at))::int + 2 end);
  update public.site_staff set beat_at = now() where user_id = auth.uid();
  if v <= 0 then return; end if;
  insert into public.staff_activity(user_id, day, secs) values (auth.uid(), public.staff_today(), v)
  on conflict (user_id, day) do update set secs = public.staff_activity.secs + v;
  perform public.staff_deficit_dec(auth.uid(), 'secs', v);
end $$;

create or replace function public.staff_note_journal()
returns void language plpgsql security definer set search_path = public as $$
declare had int;
begin
  if public.staff_rank_me() < 1 then return; end if;
  select journals into had from public.staff_activity where user_id = auth.uid() and day = public.staff_today();
  insert into public.staff_activity(user_id, day, journals) values (auth.uid(), public.staff_today(), 1)
  on conflict (user_id, day) do update set journals = 1;
  if coalesce(had,0) = 0 then perform public.staff_deficit_dec(auth.uid(), 'journals', 1); end if;
end $$;

create or replace function public.staff_logs(p_limit int default 200)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_staff('moderator') then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select id, staff_name, action, target, detail, created_at from public.admin_logs order by id desc limit least(coalesce(p_limit,200), 1000)) l), '[]'::jsonb);
end $$;

-- ---------- 4) Parrainages (table minimale ; le lot « jetons » la complétera) ----------
create table if not exists public.referrals (
  id bigint generated always as identity primary key,
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  referred_id uuid not null unique references public.profiles(id) on delete cascade,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.referrals enable row level security;

-- ---------- 5) Progression ----------
create or replace function public.staff_streak(p_user uuid, p_min int)
returns int language plpgsql security definer stable set search_path = public as $$
declare d date := public.staff_today(); n int := 0;
begin
  if not exists(select 1 from public.staff_activity where user_id = p_user and day = d and secs >= p_min) then d := d - 1; end if;
  while n < 400 and exists(select 1 from public.staff_activity where user_id = p_user and day = d and secs >= p_min) loop n := n + 1; d := d - 1; end loop;
  return n;
end $$;

create or replace function public.staff_week_stats(p_user uuid, p_week date default public.staff_week())
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare r int := public.staff_rank_of(p_user); need_m int; need_j int; need_q boolean; mins numeric; jr int; q boolean; stale int := 0;
begin
  need_m := case r when 1 then 35 when 2 then 42 when 3 then 56 else 0 end;
  need_j := case r when 1 then 1 when 2 then 2 when 3 then 7 else 0 end;
  need_q := r >= 2 and r < 4;
  select coalesce(sum(secs),0)/60.0, coalesce(sum(least(journals,1)),0) into mins, jr from public.staff_activity where user_id = p_user and day >= p_week and day < p_week + 7;
  q := coalesce((select passed from public.staff_weekly_quiz where user_id = p_user and week = p_week), false);
  if r = 3 then select count(*) into stale from public.staff_requests where status = 'pending' and target_role = 'admin' and created_at < least(now(), (p_week + 7)::timestamp) - interval '7 days'; end if;
  return jsonb_build_object('rank', r, 'week', p_week, 'mins', round(mins, 1), 'need_mins', need_m, 'journals', jr, 'need_journals', need_j,
    'quiz', q, 'need_quiz', need_q, 'stale_requests', stale,
    'ok', mins >= need_m and jr >= need_j and (not need_q or q) and stale = 0);
end $$;

create or replace function public.staff_grad_criteria(p_user uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare refs int; tot bigint; s7 int; s30 int; age_ok boolean; gp timestamptz;
begin
  select count(*) into refs from public.referrals where referrer_id = p_user and approved;
  select coalesce(sum(a.secs),0) into tot from public.staff_activity a where a.user_id = p_user;
  s7 := public.staff_streak(p_user, 60); s30 := public.staff_streak(p_user, 300);
  age_ok := (select created_at from public.profiles where id = p_user) <= now() - interval '14 days';
  select grad_passed_at into gp from public.site_staff where user_id = p_user;
  return jsonb_build_object('refs', refs, 'need_refs', 10, 'secs', tot, 'need_secs', 3600, 'streak7', s7, 'need_streak7', 7,
    'streak30', s30, 'need_streak30', 30, 'age_ok', age_ok, 'quiz', gp is not null,
    'ready', refs >= 10 and tot >= 3600 and s7 >= 7 and s30 >= 30 and age_ok);
end $$;

create or replace function public.staff_progress()
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare s public.site_staff; r int; out jsonb; pend public.staff_requests;
begin
  select * into s from public.site_staff where user_id = auth.uid();
  if not found then raise exception 'Réservé à l’équipe d’administration'; end if;
  r := public.staff_rank(s.role);
  select * into pend from public.staff_requests where user_id = auth.uid() and status = 'pending' order by id desc limit 1;
  out := jsonb_build_object('role', s.role, 'rank', r, 'warnings', s.warnings, 'max_warnings', case when r = 1 then 1 else 2 end,
     'deadline', s.deadline, 'deadline_kind', s.deadline_kind, 'deficit', s.deficit, 'since', s.rank_at,
     'week', public.staff_week_stats(auth.uid()), 'pending_request', case when pend.id is null then null else jsonb_build_object('id', pend.id, 'target', pend.target_role, 'at', pend.created_at) end);
  if r = 1 then
    out := out || jsonb_build_object('grad', public.staff_grad_criteria(auth.uid()), 'grad_deadline', s.rank_at + interval '45 days');
  elsif r = 2 then
    out := out || jsonb_build_object('chief', jsonb_build_object('days', floor(extract(epoch from now() - s.rank_at)/86400), 'need_days', 90,
        'refs', (select count(*) from public.referrals where referrer_id = auth.uid() and approved), 'need_refs', 25));
  end if;
  return out;
end $$;

-- ---------- 6) Changements de rang (interne) et groupe des administrateurs ----------
create table if not exists public.staff_group (id int primary key default 1 check (id = 1), conversation_id uuid references public.conversations(id) on delete set null);
alter table public.staff_group enable row level security;

create or replace function public.staff_group_sync() returns void language plpgsql security definer set search_path = public as $$
declare g uuid; r record; owner uuid;
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
  delete from public.conversation_members where conversation_id = g and user_id not in (select user_id from public.site_staff);
end $$;

-- p_role null = retrait total
create or replace function public.staff_apply_role(p_user uuid, p_role text, p_why text, p_black boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare uname text := (select username from public.profiles where id = p_user); old text := (select role from public.site_staff where user_id = p_user);
begin
  if p_role is null then
    delete from public.site_staff where user_id = p_user;
    update public.staff_quiz set status = 'violation' where user_id = p_user and status = 'open';
    update public.staff_requests set status = 'refused', decided_at = now(), note = 'rôle retiré' where user_id = p_user and status = 'pending';
    if p_black then insert into public.staff_blacklist(user_id, reason, by_id) values (p_user, left(coalesce(p_why,''),300), auth.uid()) on conflict (user_id) do update set reason = excluded.reason, at = now(); end if;
  else
    if exists(select 1 from public.staff_blacklist where user_id = p_user) then raise exception 'Cette personne est sur liste noire et ne peut plus devenir administrateur'; end if;
    insert into public.site_staff(user_id, role) values (p_user, p_role)
    on conflict (user_id) do update set role = excluded.role, rank_at = now(), warnings = 0, deadline = null, deadline_kind = null, deficit = null;
    if p_role = 'moderator' then update public.site_staff set deadline = now() + interval '45 days', deadline_kind = 'grad', grad_passed_at = null where user_id = p_user; end if;
  end if;
  insert into public.admin_logs(staff_id, staff_name, action, target, detail) values (coalesce(auth.uid(), p_user), coalesce((select username from public.profiles where id = auth.uid()), 'système'),
    case when p_role is null then case when p_black then 'licenciement' else 'retrait_role' end else 'changement_role' end, uname, jsonb_build_object('de', old, 'vers', p_role, 'raison', p_why));
  perform public.staff_group_sync();
end $$;
revoke all on function public.staff_apply_role(uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.staff_deficit_dec(uuid, text, numeric) from public, anon, authenticated;
revoke all on function public.staff_group_sync() from public, anon, authenticated;

-- Pénalité : élève 1 avertissement puis retrait ; administrateur/chef 2 avertissements (le 2e donne 2 h) puis descente
create or replace function public.staff_penalize(p_user uuid, p_why text, p_deficit jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare s public.site_staff; r int;
begin
  select * into s from public.site_staff where user_id = p_user for update;
  if not found then return; end if;
  r := public.staff_rank(s.role);
  if r >= 4 then return; end if;
  if r = 1 then
    if s.warnings >= 1 then perform public.staff_apply_role(p_user, null, 'derank : ' || p_why); return; end if;
    update public.site_staff set warnings = 1 where user_id = p_user;
  else
    if s.warnings >= 2 then perform public.staff_apply_role(p_user, case r when 3 then 'admin' else 'moderator' end, 'derank : ' || p_why); return; end if;
    update public.site_staff set warnings = warnings + 1 where user_id = p_user;
    if s.warnings + 1 = 2 then
      update public.site_staff set deadline = now() + interval '2 hours', deadline_kind = 'weekly', deficit = coalesce(p_deficit, '{"secs":0,"journals":0,"quiz":1}'::jsonb) where user_id = p_user;
    end if;
  end if;
  insert into public.admin_logs(staff_id, staff_name, action, target, detail) values (p_user, (select username from public.profiles where id = p_user), 'avertissement', (select username from public.profiles where id = p_user), jsonb_build_object('raison', p_why));
end $$;
revoke all on function public.staff_penalize(uuid, text, jsonb) from public, anon, authenticated;

-- ---------- 7) Gestion des rangs ----------
create or replace function public.staff_id_of(p_username text) returns uuid language plpgsql security definer stable set search_path = public as $$
declare v uuid;
begin select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if; return v; end $$;
revoke all on function public.staff_id_of(text) from public, anon, authenticated;

create or replace function public.staff_rank_user(p_username text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username); me int := public.staff_rank_me(); tr int := public.staff_rank_of(v);
begin
  if me < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  if v = auth.uid() then raise exception 'Vous ne pouvez pas changer votre propre rang'; end if;
  if p_role = 'student' then
    if tr <> 0 then raise exception 'Cette personne a déjà un rôle'; end if;
    perform public.staff_apply_role(v, 'moderator', 'rank manuel');
  elsif p_role = 'admin' then
    if tr <> 1 then raise exception 'Seul un administrateur élève peut devenir administrateur'; end if;
    perform public.staff_apply_role(v, 'admin', 'rank manuel');
  elsif p_role = 'chief' then
    if me < 4 then raise exception 'Seul le commandant nomme les chefs des administrateurs'; end if;
    if tr <> 2 then raise exception 'Seul un administrateur peut devenir chef'; end if;
    perform public.staff_apply_role(v, 'chief', 'nomination par le commandant');
  else raise exception 'Rang inconnu'; end if;
end $$;

create or replace function public.staff_cede(p_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username);
begin
  if public.staff_rank_me() <> 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  if public.staff_rank_of(v) <> 2 then raise exception 'La place ne peut être cédée qu’à un administrateur'; end if;
  perform public.staff_apply_role(v, 'chief', 'cession de place');
  perform public.staff_apply_role(auth.uid(), 'admin', 'cession de place');
end $$;

create or replace function public.staff_derank(p_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username); tr int := public.staff_rank_of(v);
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if tr = 0 then raise exception 'Cette personne n’a pas de rôle'; end if;
  if tr >= 4 then raise exception 'Le commandant ne peut pas être modifié'; end if;
  perform public.staff_apply_role(v, case tr when 3 then 'admin' when 2 then 'moderator' else null end, 'derank par le commandant');
end $$;

create or replace function public.staff_fire(p_username text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username); tr int := public.staff_rank_of(v);
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if tr >= 4 then raise exception 'Le commandant ne peut pas être modifié'; end if;
  perform public.staff_apply_role(v, null, coalesce(nullif(trim(p_reason),''), 'licenciement'), true);
end $$;

create or replace function public.staff_warn(p_username text, p_reason text, p_remove boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username);
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if public.staff_rank_of(v) not between 1 and 3 then raise exception 'Cette personne ne peut pas recevoir d’avertissement'; end if;
  if p_remove then
    update public.site_staff set warnings = greatest(0, warnings - 1), deadline = case when warnings - 1 < 2 then null else deadline end, deadline_kind = case when warnings - 1 < 2 then null else deadline_kind end,
      deficit = case when warnings - 1 < 2 then null else deficit end where user_id = v;
    perform public.log_admin('avertissement_retire', p_username, jsonb_build_object('raison', p_reason));
  else
    if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
    perform public.staff_penalize(v, 'manuel : ' || p_reason);
  end if;
end $$;

create or replace function public.staff_overview()
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs et au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user', p.username, 'role', s.role, 'since', s.rank_at, 'warnings', s.warnings, 'deadline', s.deadline, 'deadline_kind', s.deadline_kind,
      'week', public.staff_week_stats(s.user_id)) order by public.staff_rank(s.role) desc, p.username)
    from public.site_staff s join public.profiles p on p.id = s.user_id), '[]'::jsonb);
end $$;

create or replace function public.staff_public_roles()
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_object_agg(p.username, s.role), '{}'::jsonb) from public.site_staff s join public.profiles p on p.id = s.user_id
$$;

-- ---------- 8) Demandes de promotion (décidées par un humain) ----------

create or replace function public.staff_words(t text) returns int language sql immutable as $$
  select coalesce(array_length(regexp_split_to_array(trim(coalesce(t,'')), '\s+'), 1), 0) * (case when trim(coalesce(t,'')) = '' then 0 else 1 end)
$$;

create or replace function public.staff_request_create(p_target text, p_payload jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare s public.site_staff; c jsonb; v bigint;
begin
  select * into s from public.site_staff where user_id = auth.uid();
  if not found then raise exception 'Réservé à l’équipe d’administration'; end if;
  if exists(select 1 from public.staff_requests where user_id = auth.uid() and status = 'pending') then raise exception 'Une demande est déjà en attente'; end if;
  if p_target = 'admin' then
    if s.role <> 'moderator' then raise exception 'Réservé aux administrateurs élèves'; end if;
    c := public.staff_grad_criteria(auth.uid());
    if not (c->>'ready')::boolean then raise exception 'Toutes les conditions de passage ne sont pas remplies'; end if;
    if s.grad_passed_at is null then raise exception 'Le test de connaissances doit d’abord être réussi'; end if;
    p_payload := '{}'::jsonb;
  elsif p_target = 'chief' then
    if s.role <> 'admin' then raise exception 'Réservé aux administrateurs'; end if;
    if s.rank_at > now() - interval '90 days' then raise exception 'Il faut être administrateur depuis plus de 90 jours'; end if;
    if (select count(*) from public.referrals where referrer_id = auth.uid() and approved) < 25 then raise exception 'Il faut 25 personnes parrainées (approuvées)'; end if;
    if public.staff_words(p_payload->>'justification') < 500 then raise exception 'La justification doit faire au moins 500 mots'; end if;
    if public.staff_words(p_payload->>'powers') < 30 then raise exception 'Expliquez les pouvoirs d’un administrateur et ceux d’un chef'; end if;
    if coalesce((p_payload->>'oath')::boolean, false) is not true then raise exception 'Le serment est obligatoire'; end if;
    if public.staff_words(p_payload->>'cmm') < 60 then raise exception 'Le texte expliquant le CMM doit faire au moins 60 mots'; end if;
    p_payload := jsonb_build_object('justification', left(p_payload->>'justification', 20000), 'powers', left(p_payload->>'powers', 8000), 'oath', true, 'cmm', left(p_payload->>'cmm', 8000));
  else raise exception 'Demande inconnue'; end if;
  insert into public.staff_requests(user_id, target_role, payload) values (auth.uid(), p_target, p_payload) returning id into v;
  perform public.log_admin('demande_promotion', (select username from public.profiles where id = auth.uid()), jsonb_build_object('vers', p_target, 'numero', v));
  return v;
end $$;

create or replace function public.staff_requests_list()
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare me int := public.staff_rank_me();
begin
  if me < 1 then raise exception 'Réservé à l’équipe d’administration'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'user', p.username, 'target', r.target_role, 'status', r.status, 'created_at', r.created_at, 'decided_at', r.decided_at, 'note', r.note,
      'by', (select username from public.profiles where id = r.decided_by),
      'payload', case when me >= 4 or (me >= 3 and r.target_role = 'admin') then r.payload else null end,
      'criteria', case when r.target_role = 'admin' and me >= 3 then public.staff_grad_criteria(r.user_id) end,
      'days', floor(extract(epoch from now() - r.created_at)/86400)) order by (r.status = 'pending') desc, r.id desc)
    from public.staff_requests r join public.profiles p on p.id = r.user_id
    where (me >= 4) or (me >= 3 and r.target_role = 'admin') or r.user_id = auth.uid()), '[]'::jsonb);
end $$;

create or replace function public.staff_request_decide(p_id bigint, p_accept boolean, p_note text default null, p_ai boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare r public.staff_requests; me int := public.staff_rank_me();
begin
  select * into r from public.staff_requests where id = p_id for update;
  if not found then raise exception 'Demande introuvable'; end if;
  if r.status <> 'pending' then raise exception 'Demande déjà traitée'; end if;
  if r.target_role = 'chief' and me < 4 then raise exception 'Seul le commandant décide des demandes de chef'; end if;
  if r.target_role = 'admin' and me < 3 then raise exception 'Seul le chef des administrateurs décide de cette demande'; end if;
  if r.user_id = auth.uid() then raise exception 'Vous ne pouvez pas traiter votre propre demande'; end if;
  if not p_accept and char_length(trim(coalesce(p_note,''))) < 5 then raise exception 'Indiquez la raison du refus'; end if;
  update public.staff_requests set status = case when p_accept then 'accepted' else 'refused' end, decided_by = auth.uid(), decided_at = now(), note = left(p_note, 500) where id = p_id;
  if p_ai and r.target_role = 'chief' and me >= 4 then
    perform public.staff_apply_role(r.user_id, null, 'texte généré par IA détecté', true);
  elsif p_accept then
    perform public.staff_apply_role(r.user_id, case r.target_role when 'admin' then 'admin' else 'chief' end, 'demande n° ' || p_id);
  end if;
  perform public.log_admin(case when p_accept then 'promotion_acceptee' else 'promotion_refusee' end, (select username from public.profiles where id = r.user_id), jsonb_build_object('numero', p_id, 'vers', r.target_role, 'note', p_note));
end $$;

-- ---------- 9) Quiz (graduation et hebdomadaire) ----------
create table if not exists public.staff_grad_q (num int primary key, q text not null, kw jsonb not null);
create table if not exists public.staff_qbank (id int primary key, topic text not null check (topic in ('libon','vlafi','panel')), q text not null, opts jsonb not null, ans int not null);
alter table public.staff_grad_q enable row level security;
alter table public.staff_qbank enable row level security;

insert into public.staff_grad_q(num, q, kw) values
 (1, 'Où se trouve le panneau admin ?', '[[["parametre"],["developpeur"]]]'),
 (2, 'Faut-il avoir le mode développeur toujours activé en tant qu’administrateur ?', '[[["oui"]]]'),
 (3, 'Comment s’appelle l’anti-exploit ?', '[[["ciffron"]]]'),
 (4, 'Pourquoi pourrais-tu ouvrir le code source d’un bot ?', '[[["ciffron","flag","detect","signal"],["faux positif","faux-positif","verifier","correct","legitim","erron","erreur"]]]'),
 (5, 'Qu’est-ce qu’un élève administrateur fait ?', '[[["journa","log"],["ciffron","analys"],["ligne"]]]'),
 (6, 'Qu’est-ce qu’un administrateur fait ?', '[[["eleve"],["ban"],["jeton"]]]'),
 (7, 'Qu’est-ce que le chef administrateur fait ?', '[[["ban"],["ip"],["exception"]]]'),
 (8, 'La commande !fpause de LibonBOT sert à quoi ?', '[[["bouton"],["pause"]]]'),
 (9, 'Pour le langage de programmation CMM, les fonctions peuvent-elles être asynchrones ?', '[[["oui"]]]'),
 (10, 'Comment gérer les erreurs en CMM ?', '[[["essayer"],["erreur"]],[["contexte","ctx"],["argument"]]]'),
 (11, 'Comment éviter le spam ?', '[[["source","code"],["ciffron","signalement","flag"]]]'),
 (12, 'Un bot peut-il effectuer des actions de modération ?', '[[["permission"],["serveur"]]]'),
 (13, 'Qui contrôle les administrateurs ?', '[[["commandant"]]]'),
 (14, 'Que dois-je faire hebdomadairement en tant qu’administrateur ?', '[[["42"],["quiz","test"],["journa"]]]'),
 (15, 'Pourquoi devrais-je modifier les jetons de quelqu’un ?', '[[["demande"],["indemnis","erreur","perte"]]]')
on conflict (num) do update set q = excluded.q, kw = excluded.kw;

insert into public.staff_qbank(id, topic, q, opts, ans) values
 (1,'libon','Quel préfixe utilise LibonBOT ?','["!","vl/","/","@"]',0),
 (2,'libon','Que fait la commande !fpause ?','["Active le bouton de pause pour tout le monde","Bannit une personne","Vide la discussion","Renomme le groupe"]',0),
 (3,'libon','Quelle est la durée maximale d’une pause avec !pause ?','["10 secondes","60 secondes","5 minutes","Illimitée"]',1),
 (4,'libon','À quoi sert !mp ?','["À envoyer un message privé qui est ensuite retiré du fil","À bannir quelqu’un","À ajouter un ami","À mettre en pause"]',0),
 (5,'libon','Que fait !bypass o ?','["Débloque tous les jeux dans le groupe","Bannit un utilisateur","Vide le chat","Retire les bots"]',0),
 (6,'libon','Qui peut utiliser les commandes de LibonBOT dans un groupe ?','["Les administrateurs du groupe et ceux qui ont reçu le droit","Tout le monde","Seulement le créateur du site","Seulement les modérateurs du site"]',0),
 (7,'libon','Que fait !del msgn:5 ?','["Supprime les 5 derniers messages","Supprime le message n° 5","Retire 5 membres","Supprime 5 jeux"]',0),
 (8,'libon','Que fait !inv call ?','["Réinvite tout le groupe dans l’appel ou le jeu en cours","Ferme l’appel","Bannit les absents","Envoie un message privé"]',0),
 (9,'libon','Que fait !clear ?','["Vide toute la discussion","Efface son propre message","Ferme l’appel","Retire le bot"]',0),
 (10,'vlafi','Quel préfixe utilise VlafiBOT ?','["vl/","!","/","@"]',0),
 (11,'vlafi','Quelle commande fait jouer une musique ?','["vl/play","vl/join","vl/speed","vl/quit"]',0),
 (12,'vlafi','Que fait vl/join ?','["Fait entrer VlafiBOT dans l’appel en cours","Ajoute un ami","Lance un jeu","Bannit le bot"]',0),
 (13,'vlafi','Quelle plage accepte vl/speed ?','["0,1 à 3","1 à 10","0 à 1","Aucune limite"]',0),
 (14,'vlafi','Combien de musiques propose vl/play au choix ?','["8","3","20","1"]',0),
 (15,'vlafi','VlafiBOT peut-il jouer de la musique sans être dans un appel ?','["Non, il doit avoir rejoint l’appel","Oui, toujours","Seulement en privé","Seulement pour les administrateurs"]',0),
 (16,'vlafi','Quelle permission permet à VlafiBOT de jouer du son ?','["audio.play","msg.send","group.manage","bypass"]',0),
 (17,'vlafi','Sur quoi agit vl/volume ?','["Le volume du son joué dans la salle","Le volume du micro de chacun","La luminosité","Rien"]',0),
 (18,'panel','Où se trouve le panneau d’administration ?','["Paramètres, catégorie Développeur","Dans la liste des amis","Dans la fenêtre des jeux","Dans le profil d’un autre"]',0),
 (19,'panel','Que peut voir un élève administrateur du code d’un bot signalé ?','["Seulement 6 lignes avant et après la ligne signalée","Tout le code","Rien du tout","Les clés API"]',0),
 (20,'panel','Qui peut bannir une adresse IP ?','["Le chef des administrateurs et le commandant","Tous les administrateurs","Les élèves","N’importe qui"]',0),
 (21,'panel','Qui peut voir les IP de connexion d’une personne ?','["Le chef des administrateurs et le commandant","Les administrateurs","Les élèves","Personne"]',0),
 (22,'panel','Combien de temps a-t-on pour remplir les conditions après un 2e avertissement ?','["2 heures","24 heures","7 jours","Aucun délai"]',0),
 (23,'panel','Combien de jours un élève administrateur a-t-il pour devenir administrateur ?','["45 jours","7 jours","90 jours","Aucune limite"]',0),
 (24,'panel','Un simple administrateur peut-il voir les adresses IP ?','["Non, jamais","Oui, toujours","Seulement des bannis","Seulement la sienne"]',0),
 (25,'panel','Qui peut ajouter une exception à Ciffron ?','["Le chef des administrateurs et le commandant","Tout le monde","Les élèves","Les développeurs de bots"]',0),
 (26,'panel','Le journal des administrateurs est-il modifiable ?','["Non, il est immuable","Oui par le chef","Oui par le commandant","Oui après 30 jours"]',0),
 (27,'panel','Que fait « Refuser » sur une détection Ciffron ?','["Rend les lignes protégées : la détection était un faux positif","Supprime le bot","Bannit le développeur","Ne fait rien"]',0)
on conflict (id) do update set q = excluded.q, opts = excluded.opts, ans = excluded.ans, topic = excluded.topic;

create or replace function public.staff_quiz_sweep() returns void language plpgsql security definer set search_path = public as $$
declare q record;
begin
  for q in select * from public.staff_quiz where status = 'open' and (beat_at < now() - interval '45 seconds' or started_at < now() - case kind when 'grad' then interval '90 minutes' else interval '30 minutes' end) loop
    perform public.staff_quiz_fail(q.id, 'quiz abandonné ou expiré');
  end loop;
end $$;
revoke all on function public.staff_quiz_sweep() from public, anon, authenticated;

-- violation : licenciement immédiat et liste noire
create or replace function public.staff_quiz_fail(p_id bigint, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare q public.staff_quiz;
begin
  select * into q from public.staff_quiz where id = p_id for update;
  if not found or q.status <> 'open' then return; end if;
  update public.staff_quiz set status = 'violation', ended_at = now(), reason = left(p_reason, 200) where id = p_id;
  if public.staff_rank_of(q.user_id) between 1 and 3 then perform public.staff_apply_role(q.user_id, null, 'quiz : ' || p_reason, true); end if;
end $$;
revoke all on function public.staff_quiz_fail(bigint, text) from public, anon, authenticated;

create or replace function public.staff_quiz_start(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.site_staff; plan jsonb := '[]'::jsonb; out jsonb := '[]'::jsonb; v bigint; r record; topics text[] := array['libon','vlafi','panel','libon','vlafi']; i int; pick public.staff_qbank; perm int[]; wk date := public.staff_week(); rot int;
begin
  perform public.staff_quiz_sweep();
  select * into s from public.site_staff where user_id = auth.uid();
  if not found then raise exception 'Réservé à l’équipe d’administration'; end if;
  if exists(select 1 from public.staff_quiz where user_id = auth.uid() and status = 'open') then raise exception 'Un test est déjà ouvert'; end if;
  if p_kind = 'grad' then
    if s.role <> 'moderator' then raise exception 'Réservé aux administrateurs élèves'; end if;
    if not (public.staff_grad_criteria(auth.uid())->>'ready')::boolean then raise exception 'Les conditions de passage ne sont pas toutes remplies'; end if;
    if s.grad_passed_at is not null then raise exception 'Test déjà réussi : envoyez votre demande de passage'; end if;
    for r in select num, q from public.staff_grad_q order by random() loop
      plan := plan || jsonb_build_object('n', r.num); out := out || jsonb_build_object('n', r.num, 'q', r.q);
    end loop;
  elsif p_kind = 'weekly' then
    if public.staff_rank(s.role) not between 2 and 3 then raise exception 'Réservé aux administrateurs et chefs'; end if;
    if coalesce((select passed from public.staff_weekly_quiz where user_id = auth.uid() and week = wk), false) then raise exception 'Test de la semaine déjà réussi'; end if;
    if exists(select 1 from public.staff_weekly_quiz where user_id = auth.uid() and week = wk and last_day = public.staff_today()) then raise exception 'Un seul essai par jour'; end if;
    rot := (extract(week from now())::int + coalesce((select attempts from public.staff_weekly_quiz where user_id = auth.uid() and week = wk), 0)) % 3;
    for i in 1..5 loop
      select * into pick from public.staff_qbank where topic = topics[((i - 1 + rot) % 5) + 1] and id not in (select (e->>'id')::int from jsonb_array_elements(plan) e) order by random() limit 1;
      select array_agg(x order by random()) into perm from generate_series(0, jsonb_array_length(pick.opts) - 1) x;
      plan := plan || jsonb_build_object('id', pick.id, 'perm', to_jsonb(perm));
      out := out || jsonb_build_object('n', i, 'q', pick.q, 'opts', (select jsonb_agg(pick.opts->p order by ord) from unnest(perm) with ordinality t(p, ord)));
    end loop;
    insert into public.staff_weekly_quiz(user_id, week, attempts, last_day) values (auth.uid(), wk, 1, public.staff_today())
    on conflict (user_id, week) do update set attempts = public.staff_weekly_quiz.attempts + 1, last_day = public.staff_today();
  else raise exception 'Type de test inconnu'; end if;
  insert into public.staff_quiz(user_id, kind, week, plan) values (auth.uid(), p_kind, wk, plan) returning id into v;
  return jsonb_build_object('id', v, 'kind', p_kind, 'questions', out);
end $$;

create or replace function public.staff_quiz_beat(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.staff_quiz;
begin
  perform public.staff_quiz_sweep();
  update public.staff_quiz set beat_at = now() where id = p_id and user_id = auth.uid() and status = 'open' returning * into q;
  return jsonb_build_object('open', q.id is not null);
end $$;

create or replace function public.staff_quiz_violation(p_id bigint, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.staff_quiz where id = p_id and user_id = auth.uid() and status = 'open') then return; end if;
  perform public.staff_quiz_fail(p_id, coalesce(nullif(left(p_reason, 120), ''), 'règle non respectée'));
end $$;

-- graduation : p_answers = [{a: réponse, j: justification}] dans l'ordre reçu ; hebdomadaire : [index choisi, ...]
create or replace function public.staff_quiz_submit(p_id bigint, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.staff_quiz; i int; sc int := 0; n int; a text; j text; opt jsonb; grp jsonb; alt jsonb; okopt boolean; okgrp boolean; k text; txt text; qb public.staff_qbank; g public.staff_grad_q; pass boolean;
begin
  perform public.staff_quiz_sweep();
  select * into q from public.staff_quiz where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Test introuvable'; end if;
  if q.status <> 'open' then return jsonb_build_object('status', q.status, 'reason', q.reason); end if;
  n := jsonb_array_length(q.plan);
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> n then perform public.staff_quiz_fail(p_id, 'réponses incomplètes'); return jsonb_build_object('status', 'violation', 'reason', 'réponses incomplètes'); end if;
  if q.kind = 'grad' then
    for i in 0 .. n - 1 loop
      a := trim(coalesce(p_answers->i->>'a', '')); j := trim(coalesce(p_answers->i->>'j', ''));
      if char_length(a) < 40 then perform public.staff_quiz_fail(p_id, 'réponse de moins de 40 caractères'); return jsonb_build_object('status', 'violation', 'reason', 'Réponse de moins de 40 caractères'); end if;
      if char_length(j) < 15 then perform public.staff_quiz_fail(p_id, 'justification absente'); return jsonb_build_object('status', 'violation', 'reason', 'Justification absente'); end if;
      select * into g from public.staff_grad_q where num = (q.plan->i->>'n')::int;
      txt := public.norm_txt(a || ' ' || j); okopt := false;
      for opt in select * from jsonb_array_elements(g.kw) loop
        okgrp := true;
        for grp in select * from jsonb_array_elements(opt) loop
          if not exists(select 1 from jsonb_array_elements_text(grp) kw where position(public.norm_txt(kw) in txt) > 0) then okgrp := false; exit; end if;
        end loop;
        if okgrp then okopt := true; exit; end if;
      end loop;
      if okopt then sc := sc + 1; end if;
    end loop;
    pass := sc >= 12;
    update public.staff_quiz set status = case when pass then 'passed' else 'failed' end, ended_at = now(), score = sc where id = p_id;
    if pass then update public.site_staff set grad_passed_at = now() where user_id = auth.uid();
    else perform public.staff_apply_role(auth.uid(), null, 'test de graduation échoué (' || sc || '/15)', true); end if;
    return jsonb_build_object('status', case when pass then 'passed' else 'failed' end, 'score', sc, 'total', n);
  else
    for i in 0 .. n - 1 loop
      select * into qb from public.staff_qbank where id = (q.plan->i->>'id')::int;
      if (q.plan->i->'perm'->>((p_answers->>i)::int))::int = qb.ans then sc := sc + 1; end if;
    end loop;
    pass := sc >= 3;
    update public.staff_quiz set status = case when pass then 'passed' else 'failed' end, ended_at = now(), score = sc where id = p_id;
    if pass then
      update public.staff_weekly_quiz set passed = true where user_id = auth.uid() and week = q.week;
      perform public.staff_deficit_dec(auth.uid(), 'quiz', 1);
    else perform public.staff_penalize(auth.uid(), 'mini-test hebdomadaire échoué (' || sc || '/5)'); end if;
    return jsonb_build_object('status', case when pass then 'passed' else 'failed' end, 'score', sc, 'total', n);
  end if;
end $$;

-- ---------- 10) Application des règles (appelée par les clients du personnel + pg_cron si disponible) ----------
create or replace function public.staff_enforce() returns int language plpgsql security definer set search_path = public as $$
declare s record; wk date := public.staff_week() - 7; st jsonb; n int := 0; d jsonb; stale boolean;
begin
  perform public.staff_quiz_sweep();
  -- échéances : 45 jours (élève) et 2 heures (avertissement)
  for s in select * from public.site_staff where deadline is not null and deadline < now() loop
    if s.deadline_kind = 'grad' and s.role = 'moderator' then perform public.staff_apply_role(s.user_id, null, 'délai de 45 jours dépassé', true); n := n + 1;
    elsif s.deadline_kind = 'weekly' then perform public.staff_apply_role(s.user_id, null, 'conditions non remplies dans les 2 heures', true); n := n + 1;
    else update public.site_staff set deadline = null, deadline_kind = null where user_id = s.user_id; end if;
  end loop;
  -- évaluation de la semaine écoulée
  for s in select * from public.site_staff where role in ('moderator','admin','chief') and rank_at < wk::timestamp + interval '1 day'
           and not exists(select 1 from public.staff_week_log w where w.user_id = site_staff.user_id and w.week = wk) loop
    st := public.staff_week_stats(s.user_id, wk);
    insert into public.staff_week_log(user_id, week, ok, detail) values (s.user_id, wk, (st->>'ok')::boolean, st) on conflict do nothing;
    if not (st->>'ok')::boolean then
      d := jsonb_build_object('secs', 0, 'journals', 0, 'quiz', case when (st->>'need_quiz')::boolean and not (st->>'quiz')::boolean then 1 else 0 end);
      perform public.staff_penalize(s.user_id, 'exigences hebdomadaires non remplies (semaine du ' || wk || ')', d);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.staff_enforce() from public, anon, authenticated;
create or replace function public.staff_tick() returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 1 then return; end if;
  perform public.staff_enforce();
  perform public.staff_group_sync();
end $$;

do $$ begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('communicer-staff-enforce', '*/10 * * * *', 'select public.staff_enforce()');
  end if;
exception when others then null;
end $$;

-- ---------- 11) Commandes du groupe Administration (sur tous les groupes) ----------
create or replace function public.staff_group_list(p_q text default null)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('num', c.num, 'name', coalesce(c.name, 'groupe'), 'members', (select count(*) from public.conversation_members m where m.conversation_id = c.id)) order by c.num)
    from (select * from public.conversations where kind = 'group' and (p_q is null or coalesce(name,'') ilike '%' || p_q || '%') order by num desc limit 40) c), '[]'::jsonb);
end $$;
create or replace function public.staff_group_kick(p_num bigint, p_username text)
returns text language plpgsql security definer set search_path = public as $$
declare c uuid; v uuid := public.staff_id_of(p_username);
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id into c from public.conversations where num = p_num and kind = 'group';
  if c is null then raise exception 'Groupe introuvable'; end if;
  if public.staff_rank_of(v) >= public.staff_rank_me() then raise exception 'Cible protégée'; end if;
  delete from public.conversation_members where conversation_id = c and user_id = v;
  if not found then raise exception 'Cette personne n’est pas dans ce groupe'; end if;
  perform public.log_admin('groupe_retrait', p_username, jsonb_build_object('groupe', p_num));
  return 'Retiré du groupe n° ' || p_num;
end $$;
create or replace function public.staff_group_clear(p_num bigint)
returns text language plpgsql security definer set search_path = public as $$
declare c uuid; n int;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id into c from public.conversations where num = p_num and kind = 'group';
  if c is null then raise exception 'Groupe introuvable'; end if;
  delete from public.messages where conversation_id = c; get diagnostics n = row_count;
  perform public.log_admin('groupe_vidé', '#' || p_num, jsonb_build_object('messages', n));
  return n || ' messages supprimés du groupe n° ' || p_num;
end $$;
create or replace function public.staff_who(p_username text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid := public.staff_id_of(p_username);
begin
  if public.staff_rank_me() < 1 then raise exception 'Accès refusé'; end if;
  return jsonb_build_object('user', p_username, 'role', (select role from public.site_staff where user_id = v), 'warnings', (select warnings from public.site_staff where user_id = v),
    'banned', public.ban_state(v), 'created_at', (select created_at from public.profiles where id = v));
end $$;


-- ---------- 12) Code source : l'élève ne voit que 6 lignes avant/après les lignes signalées ----------
create or replace function public.staff_bot_source(p_bot uuid, p_justification text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bots; v_flag boolean; me int := public.staff_rank_me(); res jsonb;
begin
  if me < 1 then raise exception 'Accès refusé'; end if;
  select * into b from public.bots where id = p_bot;
  if not found then raise exception 'Bot introuvable'; end if;
  v_flag := exists(select 1 from public.ciffron_flags where bot_id = p_bot and status in ('open','appeal','confirmed','final'));
  if me = 1 and not v_flag then raise exception 'Les élèves ne peuvent voir que le code d’un bot signalé'; end if;
  if (me >= 2 and char_length(trim(coalesce(p_justification,''))) < 15) or (me = 1 and false) then
    raise exception 'Une justification (15 caractères minimum) est obligatoire'; end if;
  perform public.log_admin('voir_source', b.name || 'BOT', jsonb_build_object('justification', p_justification, 'via_flag', v_flag, 'fenetre', me = 1));
  res := jsonb_build_object('bot', b.name || 'BOT', 'window', me = 1,
    'protected', (select coalesce(jsonb_agg(jsonb_build_object('file', file, 'hash', line_hash)), '[]'::jsonb) from public.ciffron_protected where bot_id = p_bot));
  if me >= 2 then
    return res || jsonb_build_object('files', (select coalesce(jsonb_agg(jsonb_build_object('path', f.path, 'content', f.content, 'binary', f.data_b64 is not null, 'size', f.size) order by f.path), '[]'::jsonb) from public.bot_files f where f.bot_id = p_bot));
  end if;
  return res || jsonb_build_object('files', coalesce((
    select jsonb_agg(jsonb_build_object('path', f.path, 'binary', false, 'size', f.size, 'content', (
      select string_agg(case when exists(select 1 from public.ciffron_flags cf, jsonb_array_elements(cf.findings) x
              where cf.bot_id = p_bot and cf.status in ('open','appeal','confirmed','final') and x->>'file' = f.path and abs((x->>'line')::int - t.n) <= 6)
            then t.l else '' end, E'\n' order by t.n)
      from unnest(string_to_array(f.content, E'\n')) with ordinality t(l, n))) order by f.path)
    from public.bot_files f where f.bot_id = p_bot and f.data_b64 is null and f.content is not null
      and exists(select 1 from public.ciffron_flags cf, jsonb_array_elements(cf.findings) x where cf.bot_id = p_bot and cf.status in ('open','appeal','confirmed','final') and x->>'file' = f.path)), '[]'::jsonb));
end $$;

grant execute on function public.staff_rank_me(), public.staff_beat(int), public.staff_note_journal(), public.staff_progress(), public.staff_tick(),
  public.staff_rank_user(text, text), public.staff_cede(text), public.staff_derank(text), public.staff_fire(text, text), public.staff_warn(text, text, boolean), public.staff_overview(),
  public.staff_public_roles(), public.staff_request_create(text, jsonb), public.staff_requests_list(), public.staff_request_decide(bigint, boolean, text, boolean),
  public.staff_quiz_start(text), public.staff_quiz_beat(bigint), public.staff_quiz_violation(bigint, text), public.staff_quiz_submit(bigint, jsonb),
  public.staff_user_ips(text), public.staff_group_list(text), public.staff_group_kick(bigint, text), public.staff_group_clear(bigint), public.staff_who(text),
  public.staff_week_stats(uuid, date), public.staff_grad_criteria(uuid) to authenticated;
revoke execute on function public.staff_week_stats(uuid, date), public.staff_grad_criteria(uuid), public.staff_streak(uuid, int) from authenticated, public, anon;
select public.staff_group_sync();
