-- ============================================================================
-- Communicer! — Patch « chats » (additif, relançable)
-- @system : vraie conversation (annonces seulement) ; @staff : demandes de support = conversations réclamables ;
-- une seule discussion publique modérée par les administrateurs ; 100 caractères max et anti-répétition.
-- À exécuter après patch_systeme.sql, patch_apparence.sql, patch_droits.sql, patch_bans.sql.
-- ============================================================================
alter table public.conversations add column if not exists hub text;
alter table public.conversations add column if not exists hub_user uuid references public.profiles(id) on delete cascade;
create unique index if not exists conv_hub_system_uq on public.conversations (hub_user) where hub = 'system';
create unique index if not exists conv_hub_public_uq on public.conversations ((hub)) where hub = 'public';
create index if not exists messages_sender_time on public.messages (sender_id, created_at desc);
alter table public.support_tickets add column if not exists conv uuid references public.conversations(id) on delete set null;
create table if not exists public.public_chat_left (user_id uuid primary key references public.profiles(id) on delete cascade, at timestamptz not null default now());
alter table public.public_chat_left enable row level security; revoke all on public.public_chat_left from anon, authenticated;

create or replace function public._is_official(u uuid) returns boolean language sql immutable as $$
  select u in ('aaaaaaaa-0000-4000-8000-000000000001'::uuid, 'aaaaaaaa-0000-4000-8000-000000000002'::uuid)
$$;
create or replace function public._conv_hub(c uuid) returns text language sql security definer stable set search_path = public as $$
  select hub from public.conversations where id = c
$$;
revoke all on function public._is_official(uuid), public._conv_hub(uuid) from public, anon, authenticated;

-- créer des groupes / ajouter : les conversations « hub » créées par le système ne sont pas concernées par ces droits
create or replace function public.trg_rt_conv() returns trigger language plpgsql security definer set search_path = public as $$
begin if new.kind = 'group' and new.hub is null then perform public._need_right(auth.uid(), 'create_groups'); end if; return new; end $$;

-- les personnes bannies ou restreintes peuvent toujours écrire dans leurs demandes de support (contestation)
create or replace function public.trg_msg_ban_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sender_id is not null and new.kind <> 'system' and public._conv_hub(new.conversation_id) is distinct from 'ticket' and (public.ban_state(new.sender_id) ->> 'banned')::boolean then
    raise exception 'Compte suspendu';
  end if;
  return new;
end $$;
create or replace function public.trg_msg_ban() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public._conv_hub(new.conversation_id) is distinct from 'ticket' and (public.ban_state(new.sender_id)->>'banned')::boolean then raise exception 'Compte suspendu'; end if;
  return new;
end $$;
create or replace function public.trg_rt_messages() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sender_id is null or new.sender_id is distinct from auth.uid() or new.kind = 'system' or public._conv_hub(new.conversation_id) = 'ticket' then return new; end if;
  perform public._need_right(new.sender_id, 'send_messages', new.conversation_id);
  if new.kind in ('image','voice','drawing') or new.media_path is not null then perform public._need_right(new.sender_id, 'upload_files', new.conversation_id); end if;
  if new.kind = 'text' and new.body ~ '(^|[^A-Za-z0-9_])@[a-z0-9_]{3,20}' then perform public._need_right(new.sender_id, 'mention', new.conversation_id); end if;
  return new;
end $$;

-- ---------- @system : conversation réelle, annonces seulement ----------
create or replace function public._sys_conv(p_user uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare c uuid; s constant uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
begin
  if p_user is null or public._is_official(p_user) then return null; end if;
  select id into c from public.conversations where hub = 'system' and hub_user = p_user;
  if c is not null then return c; end if;
  begin
    insert into public.conversations(kind, mode, created_by, hub, hub_user) values ('direct', 'clear', s, 'system', p_user) returning id into c;
    insert into public.conversation_members(conversation_id, user_id, role) values (c, s, 'member'), (c, p_user, 'member');
  exception when unique_violation then select id into c from public.conversations where hub = 'system' and hub_user = p_user;
  end;
  return c;
end $$;
revoke all on function public._sys_conv(uuid) from public, anon, authenticated;

create or replace function public.sys_notify(p_user uuid, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare c uuid := public._sys_conv(p_user);
begin
  if c is null then return; end if;
  insert into public.messages(conversation_id, sender_id, kind, body) values (c, 'aaaaaaaa-0000-4000-8000-000000000001', 'text', left(p_body, 20000));
end $$;
revoke all on function public.sys_notify(uuid, text) from public, anon, authenticated;

-- la conversation @system se crée à la connexion ; les anciennes annonces y sont recopiées (sans les achats)
create or replace function public.ensure_system_chat() returns uuid language plpgsql security definer set search_path = public as $$
declare c uuid; fresh boolean; since timestamptz; r record;
begin
  if auth.uid() is null then return null; end if;
  select id into c from public.conversations where hub = 'system' and hub_user = auth.uid();
  fresh := c is null;
  c := public._sys_conv(auth.uid());
  if c is null then return null; end if;
  if fresh and to_regclass('public.world_messages') is not null then
    select created_at into since from public.profiles where id = auth.uid();
    for r in select body, at from public.world_messages w where (w.to_all and w.at >= since or auth.uid() = any(w.to_users)) and w.body !~* '\(achat' order by w.id desc limit 100 loop
      insert into public.messages(conversation_id, sender_id, kind, body, created_at) values (c, 'aaaaaaaa-0000-4000-8000-000000000001', 'text', r.body, r.at);
    end loop;
  end if;
  return c;
end $$;
revoke all on function public.ensure_system_chat() from public, anon;
grant execute on function public.ensure_system_chat() to authenticated;

-- les achats ne sont plus annoncés par @system
create or replace function public.trg_tok_notify() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.reason ~* '^(administration|parrainage|bogue|contestation)' then
    perform public.sys_notify(new.user_id, 'Jetons : ' || case when new.delta > 0 then '+' else '' end || new.delta::text || ' (' || new.reason || ')');
  end if;
  return new;
end $$;

-- annonces : sans limite de longueur (limite technique des messages : 20 000 caractères)
create or replace function public.world_post(p_users text[], p_body text) returns int language plpgsql security definer set search_path = public as $$
declare ids uuid[]; n int := 0; u uuid; b text := trim(coalesce(p_body, ''));
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  perform public.rate_ok('world:' || auth.uid()::text, 20, 3600);
  if char_length(b) < 1 then raise exception 'Message vide'; end if;
  if char_length(b) > 20000 then raise exception 'Annonce trop longue (20 000 caractères au maximum)'; end if;
  if p_users is null or cardinality(p_users) = 0 then
    for u in select id from public.profiles where not public._is_official(id) loop
      perform public.sys_notify(u, b); n := n + 1;
    end loop;
    perform public.log_admin('annonce_mondiale', 'tous', jsonb_build_object('n', n, 'len', char_length(b)));
    return -1;
  end if;
  select array_agg(id) into ids from public.profiles where username = any(select lower(regexp_replace(trim(x), '^@', '')) from unnest(p_users) x);
  if coalesce(cardinality(ids), 0) = 0 then raise exception 'Aucun destinataire trouvé'; end if;
  foreach u in array ids loop perform public.sys_notify(u, b); n := n + 1; end loop;
  perform public.log_admin('annonce_ciblee', array_to_string(p_users, ','), jsonb_build_object('n', n));
  return n;
end $$;

-- ---------- garde-fous des messages ----------
create or replace function public.trg_msg_limits() returns trigger language plpgsql security definer set search_path = public as $$
declare cv record; b text; n int;
begin
  if new.kind is distinct from 'text' or new.body is null then return new; end if;
  if new.sender_id is distinct from auth.uid() or public._is_official(new.sender_id) then return new; end if;
  select kind, mode, hub into cv from public.conversations where id = new.conversation_id;
  if cv.hub = 'system' and new.sender_id is distinct from 'aaaaaaaa-0000-4000-8000-000000000001' then raise exception 'Vous ne pouvez pas répondre à @system : utilisez @staff pour écrire à l’équipe'; end if;
  if cv.hub = 'ticket' and exists(select 1 from public.support_tickets t where t.conv = new.conversation_id and t.status = 'closed') then raise exception 'Cette demande est fermée'; end if;
  if cv.hub in ('system','ticket') or cv.kind = 'self' or cv.mode = 'e2e' then return new; end if;
  if char_length(new.body) > 100 then raise exception 'Message trop long (100 caractères maximum)'; end if;
  b := lower(btrim(regexp_replace(new.body, '\s+', ' ', 'g')));
  select count(*) into n from public.messages m where m.sender_id = new.sender_id and m.kind = 'text' and m.created_at > now() - interval '5 minutes'
     and lower(btrim(regexp_replace(coalesce(m.body, ''), '\s+', ' ', 'g'))) = b;
  if n >= 2 then
    perform public.sys_notify(new.sender_id, 'Avertissement : vous avez envoyé trois fois le même message en moins de 5 minutes. Le dernier message n’a pas été envoyé. Évitez de répéter vos messages.');
    return null;
  end if;
  return new;
end $$;
drop trigger if exists msg_limits on public.messages;
create trigger msg_limits before insert on public.messages for each row execute function public.trg_msg_limits();

-- appelé par le client pour les conversations chiffrées (le serveur ne voit pas le contenu)
create or replace function public.spam_notice() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  perform public.rate_ok('spam:' || auth.uid()::text, 6, 3600);
  perform public.sys_notify(auth.uid(), 'Avertissement : vous avez envoyé trois fois le même message en moins de 5 minutes. Le dernier message n’a pas été envoyé. Évitez de répéter vos messages.');
end $$;
revoke all on function public.spam_notice() from public, anon; grant execute on function public.spam_notice() to authenticated;

-- ---------- @staff : les demandes sont des conversations ----------
create or replace function public.support_create(p_subject text, p_body text, p_about text default null) returns text language plpgsql security definer set search_path = public as $$
declare t public.support_tickets; c uuid;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('support:' || auth.uid()::text, 5, 3600);
  if char_length(trim(coalesce(p_subject,''))) < 3 then raise exception 'Choisissez un sujet'; end if;
  if char_length(trim(coalesce(p_body,''))) < 10 then raise exception 'Décrivez votre demande (10 caractères minimum)'; end if;
  insert into public.support_tickets(user_id, user_name, subject, about) values (auth.uid(), (select username from public.profiles where id = auth.uid()), left(trim(p_subject), 80),
    nullif(lower(regexp_replace(trim(coalesce(p_about,'')), '^@', '')), '')) returning * into t;
  insert into public.conversations(kind, mode, name, created_by, hub, hub_user) values ('group', 'clear', t.ref || ' · ' || t.subject, auth.uid(), 'ticket', auth.uid()) returning id into c;
  insert into public.conversation_members(conversation_id, user_id, role) values (c, auth.uid(), 'member');
  update public.support_tickets set conv = c where id = t.id;
  insert into public.messages(conversation_id, sender_id, kind, body) values (c, auth.uid(), 'text', left(trim(p_body), 4000));
  return t.ref;
end $$;

create or replace function public.support_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('ref', ref, 'subject', subject, 'status', status, 'at', created_at, 'conv', conv,
    'last', (select max(created_at) from public.messages m where m.conversation_id = t.conv)) order by id desc), '[]'::jsonb)
  from public.support_tickets t where user_id = auth.uid()
$$;

create or replace function public.support_say(p_ref text, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  select * into t from public.support_tickets where ref = p_ref;
  if not found or t.status = 'closed' or t.conv is null then raise exception 'Demande fermée ou introuvable'; end if;
  if not exists(select 1 from public.conversation_members where conversation_id = t.conv and user_id = auth.uid()) then raise exception 'Seule la personne qui a réclamé cette demande peut écrire'; end if;
  insert into public.messages(conversation_id, sender_id, kind, body) values (t.conv, auth.uid(), 'text', left(trim(p_body), 4000));
end $$;

create or replace function public.support_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 1 then raise exception 'Réservé au personnel'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('ref', t.ref, 'subject', t.subject, 'user', t.user_name, 'about', t.about, 'status', t.status, 'at', t.created_at, 'conv', t.conv,
      'claimed_by', (select username from public.profiles where id = t.claimed_by), 'student', (select username from public.profiles where id = coalesce(t.student_id, t.student_req)),
      'student_pending', t.student_id is null and t.student_req is not null, 'mine', auth.uid() in (t.claimed_by, t.student_id), 'req_mine', t.student_req = auth.uid(),
      'first', (select left(body, 300) from public.messages m where m.conversation_id = t.conv order by id limit 1)) order by (t.status = 'open') desc, t.id desc)
    from (select * from public.support_tickets where status <> 'closed' order by id desc limit 100) t), '[]'::jsonb);
end $$;

create or replace function public.support_claim(p_ref text, p_with_student boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets; sid uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Seuls les administrateurs et plus peuvent réclamer une demande'; end if;
  select * into t from public.support_tickets where ref = p_ref for update;
  if not found or t.status <> 'open' then raise exception 'Cette demande a déjà été réclamée'; end if;
  sid := case when p_with_student then t.student_req end;
  update public.support_tickets set status = 'claimed', claimed_by = auth.uid(), student_id = sid where id = t.id;
  if t.conv is not null then
    insert into public.conversation_members(conversation_id, user_id, role) values (t.conv, auth.uid(), 'admin') on conflict (conversation_id, user_id) do nothing;
    if sid is not null then insert into public.conversation_members(conversation_id, user_id, role) values (t.conv, sid, 'member') on conflict (conversation_id, user_id) do nothing; end if;
    insert into public.messages(conversation_id, sender_id, kind, body) values (t.conv, auth.uid(), 'system', 'Demande ' || t.ref || ' prise en charge par @' || (select username from public.profiles where id = auth.uid()) || '.');
  end if;
  perform public.log_admin('support_reclame', p_ref, jsonb_build_object('student', p_with_student));
end $$;

create or replace function public.support_close(p_ref text) returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  select * into t from public.support_tickets where ref = p_ref for update;
  if not found or t.status <> 'claimed' then raise exception 'Demande introuvable ou non réclamée'; end if;
  if not (auth.uid() = t.claimed_by or public.staff_rank_me() >= 4) then raise exception 'Seule la personne qui supervise peut fermer cette demande'; end if;
  if t.conv is not null then insert into public.messages(conversation_id, sender_id, kind, body) values (t.conv, auth.uid(), 'system', 'Demande ' || t.ref || ' fermée.'); end if;
  update public.support_tickets set status = 'closed', closed_at = now() where id = t.id;
  perform public.log_admin('support_ferme', p_ref, '{}'::jsonb);
end $$;

-- consulter une demande non réclamée sans y écrire (personnel) : messages en lecture seule
create or replace function public.support_peek(p_ref text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare t public.support_tickets;
begin
  if public.staff_rank_me() < 1 then raise exception 'Réservé au personnel'; end if;
  select * into t from public.support_tickets where ref = p_ref;
  if not found then raise exception 'Demande introuvable'; end if;
  return jsonb_build_object('ref', t.ref, 'subject', t.subject, 'user', t.user_name, 'about', t.about, 'status', t.status,
    'msgs', coalesce((select jsonb_agg(jsonb_build_object('who', (select username from public.profiles where id = m.sender_id), 'body', m.body, 'at', m.created_at) order by m.id)
      from public.messages m where m.conversation_id = t.conv and m.kind = 'text'), '[]'::jsonb));
end $$;
revoke all on function public.support_peek(text) from public, anon; grant execute on function public.support_peek(text) to authenticated;

-- anciennes demandes ouvertes : converties en conversations
do $$ declare t record; c uuid; m record; begin
  for t in select * from public.support_tickets where conv is null and status <> 'closed' loop
    insert into public.conversations(kind, mode, name, created_by, hub, hub_user) values ('group', 'clear', t.ref || ' · ' || t.subject, t.user_id, 'ticket', t.user_id) returning id into c;
    insert into public.conversation_members(conversation_id, user_id, role) values (c, t.user_id, 'member');
    if t.claimed_by is not null then insert into public.conversation_members(conversation_id, user_id, role) values (c, t.claimed_by, 'admin') on conflict do nothing; end if;
    if t.student_id is not null then insert into public.conversation_members(conversation_id, user_id, role) values (c, t.student_id, 'member') on conflict do nothing; end if;
    for m in select * from public.support_msgs where ticket_id = t.id order by id loop
      insert into public.messages(conversation_id, sender_id, kind, body, created_at) values (c, coalesce(m.from_id, t.user_id), 'text', m.body, m.at);
    end loop;
    update public.support_tickets set conv = c where id = t.id;
  end loop;
end $$;

-- ---------- une seule discussion publique, modérée par les administrateurs du site ----------
update public.conversations set is_public = false where hub is distinct from 'public' and is_public;
do $$ declare c uuid; o uuid; begin
  if not exists(select 1 from public.conversations where hub = 'public') then
    select user_id into o from public.site_staff where role = 'commander' limit 1;
    if o is null then select id into o from public.profiles order by created_at limit 1; end if;
    if o is not null then insert into public.conversations(kind, mode, name, created_by, hub, is_public) values ('group', 'clear', 'Discussion publique', o, 'public', true); end if;
  end if;
end $$;

create or replace function public.ensure_public_chat(p_force boolean default false) returns uuid language plpgsql security definer set search_path = public as $$
declare c uuid; r int := public.staff_rank_me();
begin
  if auth.uid() is null then return null; end if;
  select id into c from public.conversations where hub = 'public';
  if c is null then return null; end if;
  if p_force then delete from public.public_chat_left where user_id = auth.uid(); end if;
  if exists(select 1 from public.public_chat_left where user_id = auth.uid()) and r < 2 then return c; end if;
  if public._is_official(auth.uid()) then return c; end if;
  insert into public.conversation_members(conversation_id, user_id, role) values (c, auth.uid(), case when r >= 2 then 'admin' else 'member' end)
  on conflict (conversation_id, user_id) do update set role = excluded.role;
  return c;
end $$;
revoke all on function public.ensure_public_chat(boolean) from public, anon; grant execute on function public.ensure_public_chat(boolean) to authenticated;

create or replace function public.trg_public_left() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public._conv_hub(old.conversation_id) = 'public' then insert into public.public_chat_left(user_id) values (old.user_id) on conflict do nothing; end if;
  return old;
end $$;
drop trigger if exists public_left on public.conversation_members;
create trigger public_left after delete on public.conversation_members for each row execute function public.trg_public_left();

create or replace function public.public_set(p_conv uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin raise exception 'Il n’existe qu’une seule discussion publique, modérée par les administrateurs du site'; end $$;
create or replace function public.public_list() returns table(id uuid, name text, members bigint, joined boolean) language sql security definer stable set search_path = public as $$
  select c.id, c.name, (select count(*) from public.conversation_members m where m.conversation_id = c.id), exists(select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = auth.uid())
  from public.conversations c where c.hub = 'public'
$$;
create or replace function public.public_join(p_conv uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform public.ensure_public_chat(true); end $$;
