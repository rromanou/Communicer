-- ============================================================================
-- Communicer! — Patch « équipe 2 » (additif, relançable)
-- Test de connaissances obligatoire même après nomination, rétrogradations décidées par le chef/commandant,
-- première semaine exemptée, pauses (dispenses) de 1 à 6 semaines, avertissement au mini-test raté.
-- À exécuter après patch_temps_partiel.sql et patch_chats.sql.
-- ============================================================================
alter table public.site_staff add column if not exists suspended boolean not null default false;
alter table public.site_staff add column if not exists quiz_only boolean not null default false;

create table if not exists public.staff_demotions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  from_role text not null, reason text not null,
  status text not null default 'pending' check (status in ('pending','demoted','refused')),
  decided_by uuid references public.profiles(id) on delete set null, decided_at timestamptz, note text,
  created_at timestamptz not null default now()
);
create unique index if not exists staff_demotions_one on public.staff_demotions (user_id) where status = 'pending';
alter table public.staff_demotions enable row level security; revoke all on public.staff_demotions from anon, authenticated;

create table if not exists public.staff_pauses (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  weeks int not null check (weeks between 1 and 6), reason text not null,
  status text not null default 'pending' check (status in ('pending','active','refused','ended')),
  from_at timestamptz, until_at timestamptz,
  decided_by uuid references public.profiles(id) on delete set null, decided_at timestamptz, note text,
  created_at timestamptz not null default now()
);
create unique index if not exists staff_pauses_one on public.staff_pauses (user_id) where status in ('pending','active');
alter table public.staff_pauses enable row level security; revoke all on public.staff_pauses from anon, authenticated;

-- une personne suspendue (en attente de décision de rétrogradation) n'a plus aucun pouvoir
create or replace function public.staff_rank_of(p_user uuid) returns int language sql security definer stable set search_path = public as $$
  select coalesce((select case when suspended then 0 else public.staff_rank(role) end from public.site_staff where user_id = p_user), 0)
$$;
create or replace function public._paused(p_user uuid, p_at timestamptz default now()) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.staff_pauses where user_id = p_user and status in ('active','ended') and from_at <= p_at and until_at > p_at)
$$;
revoke all on function public._paused(uuid, timestamptz) from public, anon, authenticated;

-- ---------- rétrogradations : le système propose, le chef (ou le commandant pour un chef) décide ----------
create or replace function public._demotion_open(p_user uuid, p_why text) returns void language plpgsql security definer set search_path = public as $$
declare s public.site_staff; r record; un text := (select username from public.profiles where id = p_user); id bigint;
begin
  select * into s from public.site_staff where user_id = p_user;
  if not found then return; end if;
  insert into public.staff_demotions(user_id, from_role, reason) values (p_user, s.role, left(p_why, 300)) on conflict do nothing returning staff_demotions.id into id;
  if id is null then return; end if;
  update public.site_staff set suspended = true where user_id = p_user;
  perform public.sys_notify(p_user, 'Votre rétrogradation est proposée (' || left(p_why, 200) || '). Vos pouvoirs sont suspendus jusqu’à la décision du chef.');
  for r in select user_id from public.site_staff where (role = 'commander' or (role = 'chief' and s.role <> 'chief')) and not suspended loop
    perform public.sys_notify(r.user_id, 'Rétrogradation à décider : @' || un || ' (' || s.role || ') — ' || left(p_why, 200) || '. Ouvrez Administration > Équipe > Rétrogradations : rétrograder ou refuser. Ses pouvoirs sont suspendus en attendant.');
  end loop;
end $$;
revoke all on function public._demotion_open(uuid, text) from public, anon, authenticated;

create or replace function public.staff_demotions_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
declare me int := public.staff_rank_me();
begin
  if me < 3 then raise exception 'Réservé au chef des administrateurs et au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'user', p.username, 'role', d.from_role, 'reason', d.reason, 'at', d.created_at, 'status', d.status, 'note', d.note) order by (d.status = 'pending') desc, d.id desc)
    from public.staff_demotions d join public.profiles p on p.id = d.user_id where me >= 4 or d.from_role <> 'chief'), '[]'::jsonb);
end $$;
create or replace function public.staff_demotion_decide(p_id bigint, p_demote boolean, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare d public.staff_demotions; me int := public.staff_rank_me(); to_role text;
begin
  select * into d from public.staff_demotions where id = p_id for update;
  if not found or d.status <> 'pending' then raise exception 'Demande introuvable ou déjà traitée'; end if;
  if me < 3 or (d.from_role = 'chief' and me < 4) then raise exception 'Vous ne pouvez pas décider de cette rétrogradation'; end if;
  if d.user_id = auth.uid() then raise exception 'Vous ne pouvez pas décider de votre propre rétrogradation'; end if;
  if not p_demote and char_length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Indiquez la raison du refus'; end if;
  update public.staff_demotions set status = case when p_demote then 'demoted' else 'refused' end, decided_by = auth.uid(), decided_at = now(), note = left(p_note, 300) where id = p_id;
  update public.site_staff set suspended = false where user_id = d.user_id;
  if p_demote then
    to_role := case d.from_role when 'chief' then 'admin' when 'admin' then 'moderator' else null end;
    perform public.staff_apply_role(d.user_id, to_role, 'rétrogradation décidée : ' || d.reason);
    perform public.sys_notify(d.user_id, 'Votre rétrogradation a été confirmée.' || coalesce(' Note : ' || nullif(p_note, ''), ''));
  else
    update public.site_staff set warnings = 0, deadline = null, deadline_kind = null, deficit = null where user_id = d.user_id;
    perform public.sys_notify(d.user_id, 'Votre rétrogradation a été refusée : vos pouvoirs sont rétablis. ' || coalesce('Note : ' || nullif(p_note, ''), ''));
  end if;
  perform public.log_admin(case when p_demote then 'retrogradation' else 'retrogradation_refusee' end, (select username from public.profiles where id = d.user_id), jsonb_build_object('numero', p_id, 'note', p_note));
end $$;
revoke all on function public.staff_demotions_list(), public.staff_demotion_decide(bigint, boolean, text) from public, anon;
grant execute on function public.staff_demotions_list(), public.staff_demotion_decide(bigint, boolean, text) to authenticated;


drop function if exists public.staff_penalize(uuid, text, jsonb);
create or replace function public.staff_penalize(p_user uuid, p_why text, p_deficit jsonb default null, p_strict boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare s public.site_staff; r int;
begin
  select * into s from public.site_staff where user_id = p_user for update;
  if not found then return; end if;
  r := public.staff_rank(s.role);
  if r >= 4 or s.suspended or public._paused(p_user) then return; end if;
  if r = 1 then
    if s.warnings >= 1 then perform public._demotion_open(p_user, p_why); return; end if;
    update public.site_staff set warnings = 1 where user_id = p_user;
  else
    if s.warnings >= (case when p_strict then 1 else 2 end) then perform public._demotion_open(p_user, p_why); return; end if;
    update public.site_staff set warnings = warnings + 1 where user_id = p_user;
    if s.warnings + 1 = 2 then
      update public.site_staff set deadline = now() + interval '2 hours', deadline_kind = 'weekly', deficit = coalesce(p_deficit, '{"secs":0,"journals":0,"quiz":1}'::jsonb) where user_id = p_user;
    end if;
  end if;
  insert into public.admin_logs(staff_id, staff_name, action, target, detail) values (p_user, (select username from public.profiles where id = p_user), 'avertissement', (select username from public.profiles where id = p_user), jsonb_build_object('raison', p_why));
end $$;
revoke all on function public.staff_penalize(uuid, text, jsonb, boolean) from public, anon, authenticated;

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
    on conflict (user_id) do update set role = excluded.role, rank_at = now(), warnings = 0, deadline = null, deadline_kind = null, deficit = null, suspended = false, quiz_only = false;
    if p_role = 'moderator' then update public.site_staff set deadline = now() + interval '45 days', deadline_kind = 'grad', grad_passed_at = null where user_id = p_user; end if;
    if p_role = 'pt_student' then update public.site_staff set deadline = now() + interval '9 days', deadline_kind = 'grad', grad_passed_at = null where user_id = p_user; end if;
    if p_role = 'pt_admin' then update public.site_staff set grad_passed_at = null where user_id = p_user; end if;
  end if;
  insert into public.admin_logs(staff_id, staff_name, action, target, detail) values (coalesce(auth.uid(), p_user), coalesce((select username from public.profiles where id = auth.uid()), 'système'),
    case when p_role is null then case when p_black then 'licenciement' else 'retrait_role' end else 'changement_role' end, uname, jsonb_build_object('de', old, 'vers', p_role, 'raison', p_why));
  perform public.staff_group_sync();
end $$;
revoke all on function public.staff_apply_role(uuid, text, text, boolean) from public, anon, authenticated;

create or replace function public.staff_rank_user(p_username text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username); me int := public.staff_rank_me(); tr int := public.staff_rank_of(v); tro text := public.staff_role_of(v);
begin
  if me < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  if v = auth.uid() then raise exception 'Vous ne pouvez pas changer votre propre rang'; end if;
  if p_role = 'parttime' then
    if tr <> 0 then raise exception 'Cette personne a déjà un rôle'; end if;
    perform public.staff_apply_role(v, 'pt_student', 'rank manuel');
  elsif p_role = 'pt_admin' then
    if tro is distinct from 'pt_student' then raise exception 'Seul un élève administrateur à temps partiel peut devenir administrateur à temps partiel'; end if;
    perform public.staff_apply_role(v, 'pt_admin', 'rank manuel');
  elsif p_role = 'student' then
    if tro is distinct from 'pt_admin' and not (tr = 0 and me >= 4) then raise exception 'Seul un administrateur à temps partiel peut devenir administrateur élève'; end if;
    perform public.staff_apply_role(v, 'moderator', 'rank manuel');
  elsif p_role = 'admin' then
    if tro is distinct from 'moderator' then raise exception 'Seul un administrateur élève peut devenir administrateur'; end if;
    if (select grad_passed_at from public.site_staff where user_id = v) is null then
      update public.site_staff set quiz_only = true where user_id = v;
      perform public.sys_notify(v, 'Vous êtes proposé comme administrateur. Les conditions de passage sont levées, mais vous devez encore réussir le test de connaissances (Administration > Progression).');
      perform public.log_admin('nomination_test_requis', p_username, '{}'::jsonb);
      return;
    end if;
    perform public.staff_apply_role(v, 'admin', 'rank manuel');
  elsif p_role = 'chief' then
    if me < 4 then raise exception 'Seul le commandant nomme les chefs des administrateurs'; end if;
    if tr <> 2 then raise exception 'Seul un administrateur peut devenir chef'; end if;
    perform public.staff_apply_role(v, 'chief', 'nomination par le commandant');
  else raise exception 'Rang inconnu'; end if;
end $$;

create or replace function public.staff_quiz_start(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.site_staff; plan jsonb := '[]'::jsonb; out jsonb := '[]'::jsonb; v bigint; r record; topics text[] := array['libon','vlafi','panel','libon','vlafi']; i int; pick public.staff_qbank; perm int[]; wk date := public.staff_week(); rot int;
begin
  perform public.staff_quiz_sweep();
  select * into s from public.site_staff where user_id = auth.uid();
  if not found then raise exception 'Réservé à l’équipe d’administration'; end if;
  if exists(select 1 from public.staff_quiz where user_id = auth.uid() and status = 'open') then raise exception 'Un test est déjà ouvert'; end if;
  if p_kind = 'grad' then
    if s.role not in ('moderator','pt_student') then raise exception 'Réservé aux élèves administrateurs'; end if;
    if not s.quiz_only and not (public.staff_grad_criteria(auth.uid())->>'ready')::boolean then raise exception 'Les conditions de passage ne sont pas toutes remplies'; end if;
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
    if pass then
      update public.site_staff set grad_passed_at = now() where user_id = auth.uid();
      if public.staff_role_of(auth.uid()) = 'pt_student' then perform public.staff_apply_role(auth.uid(), 'pt_admin', 'test de graduation réussi');
      elsif (select quiz_only from public.site_staff where user_id = auth.uid()) then perform public.staff_apply_role(auth.uid(), 'admin', 'nomination après test réussi'); end if;
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
    else perform public.staff_penalize(auth.uid(), 'mini-test hebdomadaire échoué (' || sc || '/5)', null, true); end if;
    return jsonb_build_object('status', case when pass then 'passed' else 'failed' end, 'score', sc, 'total', n);
  end if;
end $$;

create or replace function public.staff_week_stats(p_user uuid, p_week date default public.staff_week())
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare r int := public.staff_rank_of(p_user); ro text := public.staff_role_of(p_user); cap int; ex boolean := false; pz timestamptz; ra timestamptz; need_m int; need_j int; need_q boolean; mins numeric; jr int; q boolean; stale int := 0;
begin
  need_m := case when ro in ('pt_student','pt_admin') then 26 else case r when 1 then 35 when 2 then 42 when 3 then 56 else 0 end end;
  cap := case ro when 'pt_student' then 2 else 1 end;
  need_j := case ro when 'pt_student' then 10 when 'pt_admin' then 6 else case r when 1 then 1 when 2 then 2 when 3 then 7 else 0 end end;
  need_q := r >= 2 and r < 4;
  select rank_at into ra from public.site_staff where user_id = p_user;
  ex := r >= 2 and ra is not null and p_week < public.staff_week(ra::date) + 7;
  select until_at into pz from public.staff_pauses where user_id = p_user and status in ('active','ended') and from_at < (p_week + 7)::timestamp and until_at > p_week::timestamp order by id desc limit 1;
  select coalesce(sum(secs),0)/60.0, coalesce(sum(least(journals,cap)),0) into mins, jr from public.staff_activity where user_id = p_user and day >= p_week and day < p_week + 7;
  q := coalesce((select passed from public.staff_weekly_quiz where user_id = p_user and week = p_week), false);
  if r = 3 then select count(*) into stale from public.staff_requests where status = 'pending' and target_role = 'admin' and created_at < least(now(), (p_week + 7)::timestamp) - interval '7 days'; end if;
  return jsonb_build_object('rank', r, 'role', ro, 'jmax_day', cap, 'week', p_week, 'mins', round(mins, 1), 'need_mins', need_m, 'journals', jr, 'need_journals', need_j,
    'quiz', q, 'need_quiz', need_q, 'stale_requests', stale,
    'exempt', ex, 'paused_until', pz, 'ok', ex or pz is not null or (mins >= need_m and jr >= need_j and (not need_q or q) and stale = 0));
end $$;

create or replace function public.staff_enforce() returns int language plpgsql security definer set search_path = public as $$
declare s record; wk date := public.staff_week() - 7; st jsonb; n int := 0; d jsonb; stale boolean;
begin
  perform public.staff_quiz_sweep();
  -- échéances : 45 jours (élève) et 2 heures (avertissement)
  for s in select * from public.site_staff where deadline is not null and deadline < now() loop
    if s.deadline_kind = 'grad' and s.role in ('moderator','pt_student') then perform public.staff_apply_role(s.user_id, null, case s.role when 'pt_student' then 'délai de 9 jours dépassé' else 'délai de 45 jours dépassé' end, true); n := n + 1;
    elsif s.deadline_kind = 'weekly' then perform public.staff_apply_role(s.user_id, null, 'conditions non remplies dans les 2 heures', true); n := n + 1;
    else update public.site_staff set deadline = null, deadline_kind = null where user_id = s.user_id; end if;
  end loop;
  -- évaluation de la semaine écoulée
  for s in select * from public.site_staff where role in ('pt_student','pt_admin','moderator','admin','chief') and rank_at < wk::timestamp + interval '1 day'
           and not suspended and (public.staff_rank(role) < 2 or wk >= public.staff_week(rank_at::date) + 7)
           and not exists(select 1 from public.staff_week_log w where w.user_id = site_staff.user_id and w.week = wk) loop
    st := public.staff_week_stats(s.user_id, wk);
    insert into public.staff_week_log(user_id, week, ok, detail) values (s.user_id, wk, (st->>'ok')::boolean, st) on conflict do nothing;
    if public._paused(s.user_id, (wk + 3)::timestamptz) then continue; end if;
    if not (st->>'ok')::boolean then
      d := jsonb_build_object('secs', 0, 'journals', 0, 'quiz', case when (st->>'need_quiz')::boolean and not (st->>'quiz')::boolean then 1 else 0 end);
      perform public.staff_penalize(s.user_id, 'exigences hebdomadaires non remplies (semaine du ' || wk || ')', d);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.staff_enforce() from public, anon, authenticated;

create or replace function public.staff_progress()
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare s public.site_staff; r int; out jsonb; pend public.staff_requests;
begin
  select * into s from public.site_staff where user_id = auth.uid();
  if not found then raise exception 'Réservé à l’équipe d’administration'; end if;
  r := public.staff_rank(s.role);
  select * into pend from public.staff_requests where user_id = auth.uid() and status = 'pending' order by id desc limit 1;
  out := jsonb_build_object('role', s.role, 'rank', r, 'warnings', s.warnings, 'max_warnings', case when r = 1 then 1 else 2 end, 'part_time', s.role in ('pt_student','pt_admin'), 'suspended', s.suspended, 'quiz_only', s.quiz_only,
     'pause', (select jsonb_build_object('id', id, 'status', status, 'weeks', weeks, 'until', until_at) from public.staff_pauses where user_id = auth.uid() and status in ('pending','active') and (status = 'pending' or until_at > now()) order by id desc limit 1),
     'deadline', s.deadline, 'deadline_kind', s.deadline_kind, 'deficit', s.deficit, 'since', s.rank_at,
     'week', public.staff_week_stats(auth.uid()), 'pending_request', case when pend.id is null then null else jsonb_build_object('id', pend.id, 'target', pend.target_role, 'at', pend.created_at) end);
  if s.role = 'pt_student' then
    out := out || jsonb_build_object('grad', public.staff_grad_criteria(auth.uid()), 'grad_deadline', s.rank_at + interval '9 days', 'next_role', 'pt_admin');
  elsif s.role = 'pt_admin' then
    out := out || jsonb_build_object('grad', public.staff_grad_criteria(auth.uid()), 'next_role', 'moderator');
  elsif r = 1 then
    out := out || jsonb_build_object('grad', public.staff_grad_criteria(auth.uid()), 'grad_deadline', s.rank_at + interval '45 days', 'next_role', 'admin');
  elsif r = 2 then
    out := out || jsonb_build_object('chief', jsonb_build_object('days', floor(extract(epoch from now() - s.rank_at)/86400), 'need_days', 90,
        'refs', (select count(*) from public.referrals where referrer_id = auth.uid() and approved), 'need_refs', 25));
  end if;
  return out;
end $$;


create or replace function public.pause_request(p_weeks int, p_reason text) returns bigint language plpgsql security definer set search_path = public as $$
declare r int := public.staff_rank_me(); v bigint; un text := (select username from public.profiles where id = auth.uid()); w record;
begin
  if r < 2 or r > 3 then raise exception 'Seuls les administrateurs et chefs peuvent demander une dispense'; end if;
  if p_weeks is null or p_weeks not between 1 and 6 then raise exception 'La dispense dure de 1 à 6 semaines'; end if;
  if char_length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Indiquez la raison'; end if;
  if exists(select 1 from public.staff_pauses where user_id = auth.uid() and (status = 'pending' or (status = 'active' and until_at > now()))) then raise exception 'Une dispense est déjà en cours ou en attente'; end if;
  update public.staff_pauses set status = 'ended' where user_id = auth.uid() and status = 'active';
  insert into public.staff_pauses(user_id, weeks, reason) values (auth.uid(), p_weeks, left(trim(p_reason), 300)) returning id into v;
  for w in select user_id from public.site_staff where ((role = 'chief' and r = 2) or role = 'commander') and not suspended loop
    perform public.sys_notify(w.user_id, '@' || un || ' demande une dispense de ' || p_weeks || ' semaine(s) : ' || left(trim(p_reason), 200) || '. Décision dans Administration > Équipe > Dispenses.');
  end loop;
  return v;
end $$;
create or replace function public.pause_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
declare me int := public.staff_rank_me();
begin
  if me < 3 then raise exception 'Réservé au chef des administrateurs et au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'user', p.username, 'role', s.role, 'weeks', q.weeks, 'reason', q.reason, 'status', q.status, 'at', q.created_at, 'until', q.until_at) order by (q.status = 'pending') desc, q.id desc)
    from public.staff_pauses q join public.profiles p on p.id = q.user_id left join public.site_staff s on s.user_id = q.user_id
    where q.status in ('pending','active') and (me >= 4 or s.role <> 'chief')), '[]'::jsonb);
end $$;
create or replace function public.pause_decide(p_id bigint, p_accept boolean, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare q public.staff_pauses; me int := public.staff_rank_me(); tr int;
begin
  select * into q from public.staff_pauses where id = p_id for update;
  if not found or q.status <> 'pending' then raise exception 'Demande introuvable ou déjà traitée'; end if;
  tr := public.staff_rank_of(q.user_id);
  if q.user_id = auth.uid() then raise exception 'Vous ne pouvez pas décider de votre propre dispense'; end if;
  if me < 3 or (tr >= 3 and me < 4) then raise exception 'Vous ne pouvez pas décider de cette demande'; end if;
  if p_accept then
    update public.staff_pauses set status = 'active', from_at = now(), until_at = now() + (q.weeks * 7) * interval '1 day', decided_by = auth.uid(), decided_at = now(), note = left(p_note, 300) where id = p_id;
    update public.site_staff set deadline = null, deadline_kind = null, deficit = null where user_id = q.user_id;
    perform public.sys_notify(q.user_id, 'Votre dispense de ' || q.weeks || ' semaine(s) est acceptée : les obligations hebdomadaires sont suspendues. Vous pouvez la terminer plus tôt dans Administration > Progression.');
  else
    update public.staff_pauses set status = 'refused', decided_by = auth.uid(), decided_at = now(), note = left(p_note, 300) where id = p_id;
    perform public.sys_notify(q.user_id, 'Votre demande de dispense a été refusée.' || coalesce(' Note : ' || nullif(p_note, ''), ''));
  end if;
  perform public.log_admin(case when p_accept then 'dispense_acceptee' else 'dispense_refusee' end, (select username from public.profiles where id = q.user_id), jsonb_build_object('semaines', q.weeks));
end $$;
create or replace function public.pause_end() returns void language plpgsql security definer set search_path = public as $$
begin
  update public.staff_pauses set status = 'ended', until_at = least(until_at, now()) where user_id = auth.uid() and status = 'active';
  if not found then raise exception 'Aucune dispense en cours'; end if;
end $$;
revoke all on function public.pause_request(int, text), public.pause_list(), public.pause_decide(bigint, boolean, text), public.pause_end() from public, anon;
grant execute on function public.pause_request(int, text), public.pause_list(), public.pause_decide(bigint, boolean, text), public.pause_end() to authenticated;

