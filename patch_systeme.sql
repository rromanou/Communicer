-- Communicer! — patch comptes @system et @staff, annonces, support (additif). Dépend de patch_sanctions.sql.
-- ---------- comptes officiels (sans mot de passe tant que le commandant n'a pas généré de code) ----------
do $$
declare r record; v_inst uuid := coalesce((select id from auth.instances limit 1), '00000000-0000-0000-0000-000000000000');
begin
  for r in select * from (values ('aaaaaaaa-0000-4000-8000-000000000001'::uuid, 'system'), ('aaaaaaaa-0000-4000-8000-000000000002'::uuid, 'staff')) t(id, u) loop
    if not exists (select 1 from auth.users where id = r.id) then
      insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
        values (r.id, v_inst, 'authenticated', 'authenticated', r.u || '@communicer.app', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());
      begin
        insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
          values (gen_random_uuid(), r.id, r.id::text, jsonb_build_object('sub', r.id::text, 'email', r.u || '@communicer.app'), 'email', now(), now(), now());
      exception when others then raise notice 'identité non créée : %', sqlerrm; end;
    end if;
    insert into public.profiles(id, username) values (r.id, r.u) on conflict (id) do nothing;
    insert into public.site_staff(user_id, role) values (r.id, 'admin') on conflict (user_id) do nothing;
  end loop;
end $$;

-- ---------- annonces mondiales : stockées une seule fois ----------
create table if not exists public.world_messages (
  id bigint generated always as identity primary key,
  body text not null check (char_length(body) between 1 and 2000),
  to_all boolean not null default false, to_users uuid[] not null default '{}',
  by_name text not null default 'system', at timestamptz not null default now()
);
create index if not exists world_users_gin on public.world_messages using gin (to_users);
create table if not exists public.world_reads (user_id uuid primary key references public.profiles(id) on delete cascade, last_id bigint not null default 0);
alter table public.world_messages enable row level security; alter table public.world_reads enable row level security;
revoke all on public.world_messages, public.world_reads from anon, authenticated;

create or replace function public.sys_notify(p_user uuid, p_body text) returns void language sql security definer set search_path = public as $$
  insert into public.world_messages(body, to_users) values (left(p_body, 2000), array[p_user])
$$;
revoke all on function public.sys_notify(uuid, text) from public, anon, authenticated;

create or replace function public.trg_casier_notify() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.sys_notify(new.user_id, case new.kind
    when 'warn' then 'Avertissement : ' || new.reason
    when 'sanction' then 'Sanction : ' || new.reason
    when 'ban_temp' then 'Bannissement temporaire : ' || new.reason
    when 'ban_perm' then 'Bannissement permanent : ' || new.reason
    when 'ban_erase' then 'Compte supprimé : ' || new.reason
    when 'rights' then 'Droit retiré : ' || new.reason
    else 'Profil modifié : ' || new.reason end
    || coalesce(E'\n' || new.message, '') || E'\nVotre casier est visible dans Paramètres.');
  return new;
end $$;
drop trigger if exists casier_notify on public.casier;
create trigger casier_notify after insert on public.casier for each row execute function public.trg_casier_notify();

create or replace function public.trg_tok_notify() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.reason ~* '^(administration|parrainage|bogue|achat|contestation)' then
    perform public.sys_notify(new.user_id, 'Jetons : ' || case when new.delta > 0 then '+' else '' end || new.delta::text || ' (' || new.reason || ')');
  end if;
  return new;
end $$;
do $$ begin
  if to_regclass('public.token_log') is not null then
    drop trigger if exists tok_notify on public.token_log;
    create trigger tok_notify after insert on public.token_log for each row execute function public.trg_tok_notify();
  end if;
end $$;

create or replace function public.world_post(p_users text[], p_body text) returns int language plpgsql security definer set search_path = public as $$
declare ids uuid[]; n int;
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  perform public.rate_ok('world:' || auth.uid()::text, 20, 3600);
  if char_length(trim(coalesce(p_body,''))) < 1 then raise exception 'Message vide'; end if;
  if p_users is null or cardinality(p_users) = 0 then
    insert into public.world_messages(body, to_all, by_name) values (left(trim(p_body), 2000), true, (select username from public.profiles where id = auth.uid()));
    perform public.log_admin('annonce_mondiale', 'tous', jsonb_build_object('n', char_length(p_body)));
    return -1;
  end if;
  select array_agg(id) into ids from public.profiles where username = any(select lower(regexp_replace(trim(x), '^@', '')) from unnest(p_users) x);
  n := coalesce(cardinality(ids), 0);
  if n = 0 then raise exception 'Aucun destinataire trouvé'; end if;
  insert into public.world_messages(body, to_users, by_name) values (left(trim(p_body), 2000), ids, (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('annonce_ciblee', array_to_string(p_users, ','), jsonb_build_object('n', n));
  return n;
end $$;

create or replace function public.world_list(p_before bigint default null) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare since timestamptz; last bigint;
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  select greatest(created_at, 'epoch') into since from public.profiles where id = auth.uid();
  select coalesce(last_id, 0) into last from public.world_reads where user_id = auth.uid();
  return jsonb_build_object('last', coalesce(last, 0), 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'body', body, 'by', by_name, 'at', at, 'all', to_all) order by id desc)
    from (select * from public.world_messages w where (w.to_all and w.at >= since or auth.uid() = any(w.to_users)) and (p_before is null or w.id < p_before) order by id desc limit 50) x), '[]'::jsonb));
end $$;
create or replace function public.world_unread() returns int language sql security definer stable set search_path = public as $$
  select count(*)::int from public.world_messages w, public.profiles p
   where p.id = auth.uid() and (w.to_all and w.at >= p.created_at or auth.uid() = any(w.to_users))
     and w.id > coalesce((select last_id from public.world_reads where user_id = auth.uid()), 0)
$$;
create or replace function public.world_mark_read() returns void language sql security definer set search_path = public as $$
  insert into public.world_reads(user_id, last_id) select auth.uid(), coalesce(max(id), 0) from public.world_messages where auth.uid() is not null
  on conflict (user_id) do update set last_id = excluded.last_id
$$;

-- ---------- support @staff ----------
create table if not exists public.support_tickets (
  id bigint generated always as identity primary key, ref text unique,
  user_id uuid not null references public.profiles(id) on delete cascade, user_name text not null,
  subject text not null, about text, status text not null default 'open' check (status in ('open','claimed','closed')),
  student_req uuid references public.profiles(id) on delete set null, student_id uuid references public.profiles(id) on delete set null,
  claimed_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(), closed_at timestamptz
);
create table if not exists public.support_msgs (
  id bigint generated always as identity primary key, ticket_id bigint not null references public.support_tickets(id) on delete cascade,
  from_id uuid references public.profiles(id) on delete set null, from_staff boolean not null default false, body text not null check (char_length(body) between 1 and 4000), at timestamptz not null default now()
);
create index if not exists support_msgs_t on public.support_msgs(ticket_id, id);
create or replace function public.trg_ticket_ref() returns trigger language plpgsql as $$ begin new.ref := 'T-' || lpad(new.id::text, 6, '0'); return new; end $$;
drop trigger if exists ticket_ref on public.support_tickets;
create trigger ticket_ref before insert on public.support_tickets for each row execute function public.trg_ticket_ref();
alter table public.support_tickets enable row level security; alter table public.support_msgs enable row level security;
revoke all on public.support_tickets, public.support_msgs from anon, authenticated;

create or replace function public.support_create(p_subject text, p_body text, p_about text default null) returns text language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('support:' || auth.uid()::text, 5, 3600);
  if char_length(trim(coalesce(p_subject,''))) < 3 then raise exception 'Choisissez un sujet'; end if;
  if char_length(trim(coalesce(p_body,''))) < 10 then raise exception 'Décrivez votre demande (10 caractères minimum)'; end if;
  insert into public.support_tickets(user_id, user_name, subject, about) values (auth.uid(), (select username from public.profiles where id = auth.uid()), left(trim(p_subject), 80),
    nullif(lower(regexp_replace(trim(coalesce(p_about,'')), '^@', '')), '')) returning * into t;
  insert into public.support_msgs(ticket_id, from_id, body) values (t.id, auth.uid(), left(trim(p_body), 4000));
  return t.ref;
end $$;

create or replace function public.support_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('ref', ref, 'subject', subject, 'status', status, 'at', created_at, 'last', (select max(at) from public.support_msgs m where m.ticket_id = t.id)) order by id desc), '[]'::jsonb)
  from public.support_tickets t where user_id = auth.uid()
$$;

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
    'can_close', t.status = 'claimed' and (auth.uid() = t.claimed_by or me >= 4),
    'msgs', coalesce((select jsonb_agg(jsonb_build_object('staff', m.from_staff, 'who', case when m.from_staff then 'Staff' else null end, 'body', m.body, 'at', m.at) order by m.id) from public.support_msgs m where m.ticket_id = t.id), '[]'::jsonb));
end $$;

create or replace function public.support_say(p_ref text, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets; staff boolean;
begin
  select * into t from public.support_tickets where ref = p_ref;
  if not found or t.status = 'closed' then raise exception 'Demande fermée ou introuvable'; end if;
  perform public.rate_ok('supsay:' || auth.uid()::text, 40, 600);
  staff := t.user_id <> auth.uid();
  if staff and not (t.status = 'claimed' and auth.uid() in (t.claimed_by, t.student_id)) then raise exception 'Seule la personne qui a réclamé cette demande peut écrire'; end if;
  insert into public.support_msgs(ticket_id, from_id, from_staff, body) values (t.id, auth.uid(), staff, left(trim(p_body), 4000));
  if staff then perform public.sys_notify(t.user_id, 'Le staff a répondu à votre demande ' || t.ref || '.'); end if;
end $$;

create or replace function public.support_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 1 then raise exception 'Réservé au personnel'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('ref', t.ref, 'subject', t.subject, 'user', t.user_name, 'about', t.about, 'status', t.status, 'at', t.created_at,
      'claimed_by', (select username from public.profiles where id = t.claimed_by), 'student', (select username from public.profiles where id = coalesce(t.student_id, t.student_req)),
      'student_pending', t.student_id is null and t.student_req is not null, 'mine', auth.uid() in (t.claimed_by, t.student_id), 'req_mine', t.student_req = auth.uid()) order by (t.status = 'open') desc, t.id desc)
    from (select * from public.support_tickets where status <> 'closed' order by id desc limit 100) t), '[]'::jsonb);
end $$;
create or replace function public.support_open_count() returns int language sql security definer stable set search_path = public as $$
  select case when public.staff_rank_me() >= 1 then (select count(*)::int from public.support_tickets where status = 'open') else 0 end
$$;

create or replace function public.support_student_req(p_ref text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() <> 1 then raise exception 'Réservé aux administrateurs élèves'; end if;
  update public.support_tickets set student_req = auth.uid() where ref = p_ref and status = 'open' and student_req is null;
  if not found then raise exception 'Cette demande n’est plus disponible'; end if;
end $$;

create or replace function public.support_claim(p_ref text, p_with_student boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  if public.staff_rank_me() < 2 then raise exception 'Seuls les administrateurs et plus peuvent réclamer une demande'; end if;
  select * into t from public.support_tickets where ref = p_ref for update;
  if not found or t.status <> 'open' then raise exception 'Cette demande a déjà été réclamée'; end if;
  update public.support_tickets set status = 'claimed', claimed_by = auth.uid(), student_id = case when p_with_student then t.student_req end where id = t.id;
  perform public.log_admin('support_reclame', p_ref, jsonb_build_object('student', p_with_student));
end $$;

create or replace function public.support_close(p_ref text) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  select * into t from public.support_tickets where ref = p_ref for update;
  if not found or t.status <> 'claimed' then raise exception 'Demande introuvable ou non réclamée'; end if;
  if not (auth.uid() = t.claimed_by or public.staff_rank_me() >= 4) then raise exception 'Seule la personne qui supervise peut fermer cette demande'; end if;
  update public.support_tickets set status = 'closed', closed_at = now() where id = t.id;
  perform public.sys_notify(t.user_id, 'Votre demande ' || t.ref || ' a été fermée par le staff.');
  perform public.log_admin('support_ferme', p_ref, '{}'::jsonb);
end $$;

-- ---------- connexion aux comptes officiels par code long (généré par le commandant) ----------
create or replace function public.acct_code_make(p_name text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare code text; v uuid;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_name not in ('system','staff') then raise exception 'Compte inconnu'; end if;
  select id into v from public.profiles where username = p_name;
  code := replace(gen_random_uuid()::text || gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  update auth.users set encrypted_password = extensions.crypt(code, extensions.gen_salt('bf', 12)), updated_at = now() where id = v;
  perform public.log_admin('code_compte_officiel', p_name, '{}'::jsonb);
  return code;
end $$;
create or replace function public.acct_code_clear(p_name text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_name not in ('system','staff') then raise exception 'Compte inconnu'; end if;
  update auth.users set encrypted_password = '', updated_at = now() where id = (select id from public.profiles where username = p_name);
  perform public.log_admin('code_compte_officiel_revoque', p_name, '{}'::jsonb);
end $$;

do $$ declare f text; begin foreach f in array array['world_post(text[],text)','world_list(bigint)','world_unread()','world_mark_read()','support_create(text,text,text)','support_mine()','support_thread(text)','support_say(text,text)','support_list()','support_open_count()','support_student_req(text)','support_claim(text,boolean)','support_close(text)','acct_code_make(text)','acct_code_clear(text)'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
