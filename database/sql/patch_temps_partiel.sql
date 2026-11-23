-- ============================================================================
-- Communicer! — Patch « temps partiel » (additif, relançable)
-- Nouveaux rôles : élève administrateur à temps partiel (pt_student) puis administrateur à temps partiel (pt_admin),
-- avant administrateur élève (moderator). Le commandant n'a plus de limite de badges.
-- À exécuter après patch_hierarchie.sql (et les patchs suivants).
-- ============================================================================
do $$ declare c text; begin
  select conname into c from pg_constraint where conrelid = 'public.site_staff'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%commander%';
  if c is not null then execute format('alter table public.site_staff drop constraint %I', c); end if;
  select conname into c from pg_constraint where conrelid = 'public.staff_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%target_role%';
  if c is not null then execute format('alter table public.staff_requests drop constraint %I', c); end if;
end $$;
alter table public.site_staff drop constraint if exists site_staff_role_chk;
alter table public.site_staff add constraint site_staff_role_chk check (role in ('pt_student','pt_admin','moderator','admin','chief','commander'));
alter table public.staff_requests drop constraint if exists staff_requests_target_role_chk;
alter table public.staff_requests add constraint staff_requests_target_role_chk check (target_role in ('moderator','admin','chief'));

-- les deux rôles à temps partiel ont l'accès de base d'un élève (rang 1) ; les règles propres se lisent par le rôle
create or replace function public.staff_rank(p_role text) returns int language sql immutable as $$
  select case p_role when 'pt_student' then 1 when 'pt_admin' then 1 when 'moderator' then 1 when 'admin' then 2 when 'chief' then 3 when 'commander' then 4 else 0 end
$$;
create or replace function public.staff_role_of(p_user uuid) returns text language sql security definer stable set search_path = public as $$
  select role from public.site_staff where user_id = p_user
$$;
revoke all on function public.staff_role_of(uuid) from public, anon, authenticated;


create or replace function public.staff_note_journal()
returns void language plpgsql security definer set search_path = public as $$
declare had int := 0; cap int; r text;
begin
  if public.staff_rank_me() < 1 then return; end if;
  r := public.staff_role_of(auth.uid());
  cap := case r when 'pt_student' then 2 else 1 end;       -- élève à temps partiel : 2 ouvertures par jour au maximum
  select journals into had from public.staff_activity where user_id = auth.uid() and day = public.staff_today();
  had := coalesce(had, 0);
  if had >= cap then return; end if;
  insert into public.staff_activity(user_id, day, journals) values (auth.uid(), public.staff_today(), 1)
  on conflict (user_id, day) do update set journals = least(cap, public.staff_activity.journals + 1);
  perform public.staff_deficit_dec(auth.uid(), 'journals', 1);
end $$;


create or replace function public.staff_week_stats(p_user uuid, p_week date default public.staff_week())
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare r int := public.staff_rank_of(p_user); ro text := public.staff_role_of(p_user); cap int; need_m int; need_j int; need_q boolean; mins numeric; jr int; q boolean; stale int := 0;
begin
  need_m := case when ro in ('pt_student','pt_admin') then 26 else case r when 1 then 35 when 2 then 42 when 3 then 56 else 0 end end;
  cap := case ro when 'pt_student' then 2 else 1 end;
  need_j := case ro when 'pt_student' then 10 when 'pt_admin' then 6 else case r when 1 then 1 when 2 then 2 when 3 then 7 else 0 end end;
  need_q := r >= 2 and r < 4;
  select coalesce(sum(secs),0)/60.0, coalesce(sum(least(journals,cap)),0) into mins, jr from public.staff_activity where user_id = p_user and day >= p_week and day < p_week + 7;
  q := coalesce((select passed from public.staff_weekly_quiz where user_id = p_user and week = p_week), false);
  if r = 3 then select count(*) into stale from public.staff_requests where status = 'pending' and target_role = 'admin' and created_at < least(now(), (p_week + 7)::timestamp) - interval '7 days'; end if;
  return jsonb_build_object('rank', r, 'role', ro, 'jmax_day', cap, 'week', p_week, 'mins', round(mins, 1), 'need_mins', need_m, 'journals', jr, 'need_journals', need_j,
    'quiz', q, 'need_quiz', need_q, 'stale_requests', stale,
    'ok', mins >= need_m and jr >= need_j and (not need_q or q) and stale = 0);
end $$;

create or replace function public.staff_grad_criteria(p_user uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare ro text := public.staff_role_of(p_user); refs int; tot bigint; s7 int; s30 int; age_ok boolean; gp timestamptz; nr int; ns int; nst int; ok boolean;
begin
  select count(*) into refs from public.referrals where referrer_id = p_user and approved;
  select coalesce(sum(a.secs),0) into tot from public.staff_activity a where a.user_id = p_user;
  select grad_passed_at into gp from public.site_staff where user_id = p_user;
  if ro in ('pt_student','pt_admin') then
    nr := case ro when 'pt_student' then 2 else 3 end; ns := case ro when 'pt_student' then 3600 else 7200 end; nst := case ro when 'pt_student' then 7 else 5 end;
    s7 := public.staff_streak(p_user, 120);
    ok := refs >= nr and tot >= ns and s7 >= nst;
    return jsonb_build_object('refs', refs, 'need_refs', nr, 'secs', tot, 'need_secs', ns, 'streak7', s7, 'need_streak7', nst,
      'streak30', 0, 'need_streak30', 0, 'age_ok', true, 'quiz', gp is not null, 'need_quiz', ro = 'pt_student', 'role', ro,
      'ready', ok);
  end if;
  s7 := public.staff_streak(p_user, 60); s30 := public.staff_streak(p_user, 300);
  age_ok := (select created_at from public.profiles where id = p_user) <= now() - interval '14 days';
  return jsonb_build_object('refs', refs, 'need_refs', 10, 'secs', tot, 'need_secs', 3600, 'streak7', s7, 'need_streak7', 7,
    'streak30', s30, 'need_streak30', 30, 'age_ok', age_ok, 'quiz', gp is not null, 'need_quiz', true, 'role', ro,
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
  out := jsonb_build_object('role', s.role, 'rank', r, 'warnings', s.warnings, 'max_warnings', case when r = 1 then 1 else 2 end, 'part_time', s.role in ('pt_student','pt_admin'),
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
    perform public.staff_apply_role(v, 'admin', 'rank manuel');
  elsif p_role = 'chief' then
    if me < 4 then raise exception 'Seul le commandant nomme les chefs des administrateurs'; end if;
    if tr <> 2 then raise exception 'Seul un administrateur peut devenir chef'; end if;
    perform public.staff_apply_role(v, 'chief', 'nomination par le commandant');
  else raise exception 'Rang inconnu'; end if;
end $$;

create or replace function public.staff_derank(p_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.staff_id_of(p_username); tr int := public.staff_rank_of(v); tro text := public.staff_role_of(v);
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if tr = 0 then raise exception 'Cette personne n’a pas de rôle'; end if;
  if tr >= 4 then raise exception 'Le commandant ne peut pas être modifié'; end if;
  perform public.staff_apply_role(v, case tro when 'chief' then 'admin' when 'admin' then 'moderator' when 'moderator' then 'pt_admin' when 'pt_admin' then 'pt_student' else null end, 'derank par le commandant');
end $$;

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
  elsif p_target = 'moderator' then
    if s.role <> 'pt_admin' then raise exception 'Réservé aux administrateurs à temps partiel'; end if;
    c := public.staff_grad_criteria(auth.uid());
    if not (c->>'ready')::boolean then raise exception 'Toutes les conditions de passage ne sont pas remplies'; end if;
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
      'payload', case when me >= 4 or (me >= 3 and r.target_role in ('admin','moderator')) then r.payload else null end,
      'criteria', case when r.target_role in ('admin','moderator') and me >= 3 then public.staff_grad_criteria(r.user_id) end,
      'days', floor(extract(epoch from now() - r.created_at)/86400)) order by (r.status = 'pending') desc, r.id desc)
    from public.staff_requests r join public.profiles p on p.id = r.user_id
    where (me >= 4) or (me >= 3 and r.target_role in ('admin','moderator')) or r.user_id = auth.uid()), '[]'::jsonb);
end $$;

create or replace function public.staff_request_decide(p_id bigint, p_accept boolean, p_note text default null, p_ai boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare r public.staff_requests; me int := public.staff_rank_me();
begin
  select * into r from public.staff_requests where id = p_id for update;
  if not found then raise exception 'Demande introuvable'; end if;
  if r.status <> 'pending' then raise exception 'Demande déjà traitée'; end if;
  if r.target_role = 'chief' and me < 4 then raise exception 'Seul le commandant décide des demandes de chef'; end if;
  if r.target_role in ('admin','moderator') and me < 3 then raise exception 'Seul le chef des administrateurs décide de cette demande'; end if;
  if r.user_id = auth.uid() then raise exception 'Vous ne pouvez pas traiter votre propre demande'; end if;
  if not p_accept and char_length(trim(coalesce(p_note,''))) < 5 then raise exception 'Indiquez la raison du refus'; end if;
  update public.staff_requests set status = case when p_accept then 'accepted' else 'refused' end, decided_by = auth.uid(), decided_at = now(), note = left(p_note, 500) where id = p_id;
  if p_ai and r.target_role = 'chief' and me >= 4 then
    perform public.staff_apply_role(r.user_id, null, 'texte généré par IA détecté', true);
  elsif p_accept then
    perform public.staff_apply_role(r.user_id, case r.target_role when 'admin' then 'admin' when 'moderator' then 'moderator' else 'chief' end, 'demande n° ' || p_id);
  end if;
  perform public.log_admin(case when p_accept then 'promotion_acceptee' else 'promotion_refusee' end, (select username from public.profiles where id = r.user_id), jsonb_build_object('numero', p_id, 'vers', r.target_role, 'note', p_note));
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
      if public.staff_role_of(auth.uid()) = 'pt_student' then perform public.staff_apply_role(auth.uid(), 'pt_admin', 'test de graduation réussi'); end if;
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
  if public.staff_rank_me() >= 4 then slots := 1000; end if;
  if coalesce(array_length(arr, 1), 0) > slots then raise exception 'Seulement % badges affichables', slots; end if;
  insert into public.profile_ext(user_id, badges) values (auth.uid(), arr) on conflict (user_id) do update set badges = excluded.badges;
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
    'slots', case when public.staff_rank_me() >= 4 then 1000 else 4 + case when exists(select 1 from public.inventory where user_id = auth.uid() and code = 'badge_slot5') then 1 else 0 end end);
end $$;
