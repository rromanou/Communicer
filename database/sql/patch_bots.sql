-- ============================================================
-- Patch 6 : plateforme de bots (CMM / ZCM), LibonBOT, Ciffron, rôles staff
-- Additif et relançable. À exécuter après patch_jeux5.sql.
-- ============================================================

-- ---------- Rôles du site (modérateur / administrateur) ----------
create table if not exists public.site_staff (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  role text not null check (role in ('moderator','admin')),
  created_at timestamptz not null default now()
);
alter table public.site_staff enable row level security;

create or replace function public.staff_role() returns text language sql security definer stable set search_path = public as $$
  select role from public.site_staff where user_id = auth.uid()
$$;
create or replace function public.is_staff(p_min text default 'moderator') returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.site_staff s where s.user_id = auth.uid()
    and (s.role = 'admin' or (p_min = 'moderator' and s.role = 'moderator')))
$$;
drop policy if exists staff_self on public.site_staff;
create policy staff_self on public.site_staff for select to authenticated using (user_id = auth.uid());
grant select on public.site_staff to authenticated;

-- @rhum est administrateur et propriétaire des bots officiels
insert into public.site_staff(user_id, role)
  select id, 'admin' from public.profiles where username = 'rhum'
  on conflict (user_id) do nothing;

-- ---------- Journal des administrateurs (immuable) ----------
create table if not exists public.admin_logs (
  id bigint generated always as identity primary key,
  staff_id uuid references public.profiles(id) on delete set null,
  staff_name text not null,
  action text not null,
  target text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.admin_logs enable row level security;
drop policy if exists adminlogs_select on public.admin_logs;
create policy adminlogs_select on public.admin_logs for select to authenticated using (public.is_staff('admin'));
grant select on public.admin_logs to authenticated;
revoke update, delete, truncate on public.admin_logs from authenticated, anon, public;

create or replace function public.log_admin(p_action text, p_target text, p_detail jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.admin_logs(staff_id, staff_name, action, target, detail)
  values (auth.uid(), coalesce((select username from public.profiles where id = auth.uid()), '?'), p_action, p_target, coalesce(p_detail, '{}'::jsonb));
end $$;

-- Immuabilité même pour le propriétaire de la table (sauf superutilisateur)
create or replace function public.trg_immutable() returns trigger language plpgsql as $$
begin raise exception 'Journal immuable'; end $$;
drop trigger if exists admin_logs_imm on public.admin_logs;
create trigger admin_logs_imm before update or delete on public.admin_logs for each row execute function public.trg_immutable();

-- ---------- IP, bannissements du site ----------
create table if not exists public.user_ips (
  user_id uuid not null references public.profiles(id) on delete cascade,
  ip text not null,
  is_signup boolean not null default false,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (user_id, ip)
);
create index if not exists user_ips_ip_idx on public.user_ips(ip);
alter table public.user_ips enable row level security;   -- aucune politique : accès par RPC seulement

create table if not exists public.site_bans (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id) on delete cascade,
  ip text,
  until timestamptz,                   -- null = permanent
  reason text not null default '',
  by_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by uuid references public.profiles(id) on delete set null,
  constraint site_bans_target check (user_id is not null or ip is not null)
);
alter table public.site_bans enable row level security;

create or replace function public.req_ip() returns text language plpgsql stable as $$
declare h jsonb; v text;
begin
  begin h := current_setting('request.headers', true)::jsonb; exception when others then h := null; end;
  if h is null then return null; end if;
  v := coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for',''), ',', 1), h->>'x-real-ip');
  v := nullif(trim(v), '');
  return v;
end $$;

create or replace function public.ban_state(p_user uuid default auth.uid())
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare b public.site_bans; v_ip text := public.req_ip();
begin
  select * into b from public.site_bans sb
   where sb.lifted_at is null and (sb.until is null or sb.until > now())
     and (sb.user_id = p_user or (sb.ip is not null and sb.ip = v_ip))
   order by (sb.until is null) desc, sb.until desc limit 1;
  if not found then return jsonb_build_object('banned', false); end if;
  return jsonb_build_object('banned', true, 'until', b.until, 'reason', b.reason, 'ip_ban', b.user_id is null);
end $$;

create or replace function public.trg_msg_ban() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (public.ban_state(new.sender_id)->>'banned')::boolean then raise exception 'Compte suspendu'; end if;
  return new;
end $$;
drop trigger if exists msg_ban on public.messages;
create trigger msg_ban before insert on public.messages for each row execute function public.trg_msg_ban();

-- ---------- Développeur : mode développeur et blocages ----------
create table if not exists public.dev_status (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  enabled boolean not null default false,
  blocked boolean not null default false,
  blocked_reason text,
  blocked_at timestamptz
);
alter table public.dev_status enable row level security;
drop policy if exists dev_self on public.dev_status;
create policy dev_self on public.dev_status for select to authenticated using (user_id = auth.uid());
grant select on public.dev_status to authenticated;

create table if not exists public.dev_ip_blocks (
  ip text not null,
  flag_id bigint,
  created_at timestamptz not null default now(),
  primary key (ip, flag_id)
);
alter table public.dev_ip_blocks enable row level security;

-- Enregistre l'IP de la session. Renvoie l'état (suspension, droit développeur).
create or replace function public.register_ip()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_ip text := public.req_ip(); v_first boolean;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if v_ip is not null then
    select not exists(select 1 from public.user_ips where user_id = v_me) into v_first;
    insert into public.user_ips(user_id, ip, is_signup) values (v_me, v_ip, v_first)
      on conflict (user_id, ip) do update set last_seen = now();
  end if;
  return public.ban_state(v_me) || jsonb_build_object('dev', public.dev_check(v_me));
end $$;

-- null = autorisé, sinon raison du blocage
create or replace function public.dev_check(p_user uuid default auth.uid())
returns text language plpgsql security definer stable set search_path = public as $$
declare d public.dev_status; v_ip text := public.req_ip();
begin
  select * into d from public.dev_status where user_id = p_user;
  if found and d.blocked then return coalesce(d.blocked_reason, 'Mode développeur bloqué par Ciffron'); end if;
  if v_ip is not null and exists(select 1 from public.dev_ip_blocks where ip = v_ip) then
    return 'Mode développeur bloqué pour cette adresse IP (Ciffron)';
  end if;
  if exists(select 1 from public.user_ips u join public.dev_ip_blocks b on b.ip = u.ip
             where u.user_id = p_user and u.is_signup) then
    return 'Mode développeur bloqué : compte créé depuis une adresse IP bloquée (Ciffron)';
  end if;
  return null;
end $$;

create or replace function public.set_dev_mode(p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_r text;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if p_on then
    if (public.ban_state(v_me)->>'banned')::boolean then raise exception 'Compte suspendu'; end if;
    v_r := public.dev_check(v_me);
    if v_r is not null then raise exception '%', v_r; end if;
  end if;
  insert into public.dev_status(user_id, enabled) values (v_me, p_on)
    on conflict (user_id) do update set enabled = p_on;
  return jsonb_build_object('enabled', p_on);
end $$;

create or replace function public.dev_info()
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare d public.dev_status;
begin
  select * into d from public.dev_status where user_id = auth.uid();
  return jsonb_build_object('enabled', coalesce(d.enabled,false) and public.dev_check() is null,
    'blocked', public.dev_check(), 'staff', public.staff_role());
end $$;

-- ---------- Bots ----------
create table if not exists public.bots (
  id uuid primary key default gen_random_uuid(),
  num bigint generated always as identity,
  name text not null,                     -- sans « BOT » : Vlafi
  username text not null,                 -- vlafibot
  prefix text not null,                   -- vl/
  description text not null default '',
  owner_id uuid references public.profiles(id) on delete set null,
  owner_username text,                    -- pour les bots officiels (résolution différée)
  visibility text not null default 'public' check (visibility in ('public','private')),
  access_key text,                        -- 12 chiffres (privé)
  official boolean not null default false,
  version int not null default 1,
  notes text not null default '',
  perms text[] not null default '{}',
  commands jsonb not null default '[]'::jsonb,   -- [{cmd, usage, desc}]
  status text not null default 'active' check (status in ('active','blocked','deleted')),
  blocked_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bots_name_fmt check (name ~ '^[A-Za-z][A-Za-z0-9]{1,14}$'),
  constraint bots_prefix_fmt check (prefix !~ '[[:space:][:cntrl:]]' and char_length(prefix) between 1 and 24),
  constraint bots_key_fmt check (access_key is null or access_key ~ '^[0-9]{12}$')
);
create unique index if not exists bots_username_uq on public.bots(username);
create unique index if not exists bots_prefix_uq on public.bots(lower(prefix));
alter table public.bots enable row level security;

create or replace function public.bot_is_owner(p_bot uuid) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.bots b where b.id = p_bot and (b.owner_id = auth.uid()
     or (b.owner_username is not null and b.owner_username = (select username from public.profiles where id = auth.uid()))))
$$;

-- Les bots sont lisibles (infos publiques, sans clé privée ni code) par tous les connectés
drop policy if exists bots_select on public.bots;
create policy bots_select on public.bots for select to authenticated using (status <> 'deleted');
revoke select on public.bots from authenticated;
grant select (id, num, name, username, prefix, description, owner_id, owner_username, visibility, official, version, notes, perms, commands, status, blocked_reason, created_at, updated_at)
  on public.bots to authenticated;

create table if not exists public.bot_files (
  bot_id uuid not null references public.bots(id) on delete cascade,
  path text not null,
  content text,                           -- fichiers texte
  data_b64 text,                          -- fichiers binaires
  runtime boolean not null default false, -- écrit par le bot lui-même (journaux serveurs)
  size int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (bot_id, path),
  constraint bot_files_path check (path !~ '(^|/)\.\.(/|$)' and path !~ '^/' and path !~ '//' and char_length(path) between 1 and 200 and path !~ '[\x00-\x1f\\]'),
  constraint bot_files_size check (size <= 12582912)
);
alter table public.bot_files enable row level security;   -- accès par RPC uniquement (le code d'un bot n'est jamais lisible par les autres)

create table if not exists public.conversation_bots (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  bot_id uuid not null references public.bots(id) on delete cascade,
  added_by uuid references public.profiles(id) on delete set null,
  accepted_perms text[] not null default '{}',
  accepted_version int not null default 1,
  pending boolean not null default false,       -- mise à jour en attente de validation
  added_at timestamptz not null default now(),
  primary key (conversation_id, bot_id)
);
alter table public.conversation_bots enable row level security;
drop policy if exists cb_select on public.conversation_bots;
create policy cb_select on public.conversation_bots for select to authenticated using (public.is_member(conversation_id));
grant select on public.conversation_bots to authenticated;

create table if not exists public.bot_requests (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  bot_id uuid not null references public.bots(id) on delete cascade,
  kind text not null check (kind in ('update')),
  version int not null,
  notes text not null default '',
  perms text[] not null default '{}',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  accepted boolean
);
alter table public.bot_requests enable row level security;   -- RPC seulement (visible des administrateurs du groupe)

create table if not exists public.bot_conv_state (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  bot_id uuid not null references public.bots(id) on delete cascade,
  key text not null check (char_length(key) between 1 and 80),
  value jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (conversation_id, bot_id, key)
);
alter table public.bot_conv_state enable row level security;
drop policy if exists bcs_select on public.bot_conv_state;
create policy bcs_select on public.bot_conv_state for select to authenticated using (public.is_member(conversation_id));
grant select on public.bot_conv_state to authenticated;

-- unicité croisée des noms d'utilisateur (profils / bots)
create or replace function public.trg_profile_name_free() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from public.bots where username = new.username and status <> 'deleted') then
    raise exception 'Ce nom d''utilisateur est réservé à un bot';
  end if;
  return new;
end $$;
drop trigger if exists profile_name_free on public.profiles;
create trigger profile_name_free before insert on public.profiles for each row execute function public.trg_profile_name_free();

create or replace function public.trg_profile_after() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.bots set owner_id = new.id where owner_username = new.username and owner_id is null;
  if new.username = 'rhum' then
    insert into public.site_staff(user_id, role) values (new.id, 'admin') on conflict (user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists profile_after on public.profiles;
create trigger profile_after after insert on public.profiles for each row execute function public.trg_profile_after();
update public.bots b set owner_id = p.id from public.profiles p where b.owner_username = p.username and b.owner_id is null;

-- Droits proposés aux bots (liste fermée)
create or replace function public.bot_perm_ok(p text[]) returns boolean language sql immutable as $$
  select p <@ array['msg.send','call.join','audio.play','game.control','group.manage','msg.delete','ui.html','files.write','conv.theme','friends.request','conv.create','bypass','ui.script']
$$;

-- Création d'un bot (développeur)
create or replace function public.bot_create(p_name text, p_prefix text, p_visibility text, p_desc text, p_perms text[], p_commands jsonb)
returns public.bots language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_r text; v_row public.bots; v_un text; v_key text;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  v_r := public.dev_check(v_me); if v_r is not null then raise exception '%', v_r; end if;
  if not coalesce((select enabled from public.dev_status where user_id = v_me), false) then raise exception 'Activez le mode développeur'; end if;
  p_name := regexp_replace(trim(p_name), '(?i)bot$', '');
  if p_name !~ '^[A-Za-z][A-Za-z0-9]{1,14}$' then raise exception 'Nom invalide (lettres et chiffres, 2 à 15 caractères)'; end if;
  v_un := lower(p_name) || 'bot';
  p_prefix := trim(p_prefix);
  if p_prefix !~ '^[^\s]{1,6}$' then raise exception 'Préfixe invalide (1 à 6 caractères sans espace)'; end if;
  if p_visibility not in ('public','private') then raise exception 'Visibilité invalide'; end if;
  if not public.bot_perm_ok(coalesce(p_perms, '{}')) then raise exception 'Permission inconnue'; end if;
  if exists(select 1 from public.bots where username = v_un and status <> 'deleted') or exists(select 1 from public.profiles where username = v_un) then
    raise exception 'Ce nom est déjà pris'; end if;
  if exists(select 1 from public.bots where lower(prefix) = lower(p_prefix) and status <> 'deleted') then
    raise exception 'Ce préfixe de commande est déjà pris'; end if;
  if (select count(*) from public.bots where owner_id = v_me and status <> 'deleted') >= 10 then raise exception 'Maximum 10 bots'; end if;
  if p_visibility = 'private' then v_key := lpad((floor(random()*1e12))::bigint::text, 12, '0'); end if;
  insert into public.bots(name, username, prefix, description, owner_id, visibility, access_key, perms, commands)
  values (p_name, v_un, p_prefix, left(coalesce(p_desc,''), 400), v_me, p_visibility, v_key, coalesce(p_perms,'{}'), coalesce(p_commands,'[]'::jsonb))
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.bot_my_list()
returns table (id uuid, num bigint, name text, username text, prefix text, description text, visibility text, access_key text, official boolean, version int, notes text, perms text[], commands jsonb, status text, blocked_reason text, updated_at timestamptz)
language sql security definer stable set search_path = public as $$
  select b.id, b.num, b.name, b.username, b.prefix, b.description, b.visibility, b.access_key, b.official, b.version, b.notes, b.perms, b.commands, b.status, b.blocked_reason, b.updated_at
    from public.bots b where b.status <> 'deleted' and public.bot_is_owner(b.id) order by b.created_at
$$;

create or replace function public.bot_regen_key(p_bot uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  if (select visibility from public.bots where id = p_bot) <> 'private' then raise exception 'Ce bot est public'; end if;
  v := lpad((floor(random()*1e12))::bigint::text, 12, '0');
  update public.bots set access_key = v where id = p_bot;
  return v;
end $$;

create or replace function public.bot_set_visibility(p_bot uuid, p_visibility text)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  if p_visibility not in ('public','private') then raise exception 'Visibilité invalide'; end if;
  if (select official from public.bots where id = p_bot) then raise exception 'Bot officiel'; end if;
  if p_visibility = 'private' then v := lpad((floor(random()*1e12))::bigint::text, 12, '0'); end if;
  update public.bots set visibility = p_visibility, access_key = v where id = p_bot;
  return v;
end $$;

create or replace function public.bot_delete(p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  if (select official from public.bots where id = p_bot) then raise exception 'Les bots officiels ne peuvent pas être supprimés'; end if;
  update public.bots set status = 'deleted', username = username || '~' || num::text, prefix = prefix || '~' || num::text where id = p_bot;
  delete from public.conversation_bots where bot_id = p_bot;
  delete from public.bot_files where bot_id = p_bot;
end $$;

-- ---------- Répertoire du bot (fichiers) ----------
create or replace function public.bot_dev_ok(p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_r text; b public.bots;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  select * into b from public.bots where id = p_bot;
  if b.status = 'blocked' then raise exception 'Bot bloqué par Ciffron : modification impossible'; end if;
  if b.status = 'deleted' then raise exception 'Bot supprimé'; end if;
  v_r := public.dev_check(auth.uid()); if v_r is not null then raise exception '%', v_r; end if;
  if not coalesce((select enabled from public.dev_status where user_id = auth.uid()), false) then raise exception 'Activez le mode développeur'; end if;
end $$;

create or replace function public.bot_list_files(p_bot uuid)
returns table (path text, size int, is_text boolean, runtime boolean, updated_at timestamptz)
language plpgsql security definer stable set search_path = public as $$
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  return query select f.path, f.size, f.content is not null, f.runtime, f.updated_at from public.bot_files f where f.bot_id = p_bot order by f.path;
end $$;

create or replace function public.bot_get_file(p_bot uuid, p_path text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare f public.bot_files;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  select * into f from public.bot_files where bot_id = p_bot and path = p_path;
  if not found then return null; end if;
  return jsonb_build_object('path', f.path, 'content', f.content, 'data', f.data_b64, 'size', f.size);
end $$;

-- p_files : [{path, content|null, data|null}]
create or replace function public.bot_save_files(p_bot uuid, p_files jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare e jsonb; v_n int := 0; v_size int; v_tot bigint;
begin
  perform public.bot_dev_ok(p_bot);
  if jsonb_typeof(p_files) <> 'array' or jsonb_array_length(p_files) > 200 then raise exception 'Lot de fichiers invalide'; end if;
  for e in select * from jsonb_array_elements(p_files) loop
    if (e->>'content') is not null then v_size := octet_length(e->>'content');
    elsif (e->>'data') is not null then v_size := (length(e->>'data') * 3) / 4;
    else raise exception 'Fichier vide : %', e->>'path'; end if;
    if v_size > 12582912 then raise exception 'Fichier trop gros : %', e->>'path'; end if;
    insert into public.bot_files(bot_id, path, content, data_b64, size, runtime, updated_at)
    values (p_bot, e->>'path', e->>'content', case when (e->>'content') is null then e->>'data' end, v_size, false, now())
    on conflict (bot_id, path) do update set content = excluded.content, data_b64 = excluded.data_b64, size = excluded.size, updated_at = now(), runtime = false;
    v_n := v_n + 1;
  end loop;
  select coalesce(sum(size), 0) into v_tot from public.bot_files where bot_id = p_bot;
  if v_tot > 50331648 then raise exception 'Répertoire trop gros (48 Mo maximum)'; end if;
  update public.bots set updated_at = now() where id = p_bot;
  return v_n;
end $$;

create or replace function public.bot_delete_file(p_bot uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.bot_dev_ok(p_bot);
  delete from public.bot_files where bot_id = p_bot and (path = p_path or path like p_path || '/%');
  update public.bots set updated_at = now() where id = p_bot;
end $$;

create or replace function public.bot_rename_file(p_bot uuid, p_from text, p_to text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.bot_dev_ok(p_bot);
  if p_to !~ '^[^/\\\x00-\x1f][^\\\x00-\x1f]{0,199}$' or p_to ~ '(^|/)\.\.(/|$)' or p_to ~ '//' then raise exception 'Nom invalide'; end if;
  if exists(select 1 from public.bot_files where bot_id = p_bot and path = p_to) then raise exception 'Ce nom existe déjà'; end if;
  update public.bot_files set path = p_to, updated_at = now() where bot_id = p_bot and path = p_from;
end $$;

-- Publication : nouvelle version ; demande de validation aux administrateurs des groupes où le bot est installé
create or replace function public.bot_publish(p_bot uuid, p_notes text, p_perms text[], p_commands jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare b public.bots; v_ver int; r record;
begin
  perform public.bot_dev_ok(p_bot);
  select * into b from public.bots where id = p_bot;
  if not public.bot_perm_ok(coalesce(p_perms,'{}')) then raise exception 'Permission inconnue'; end if;
  v_ver := b.version + 1;
  update public.bots set version = v_ver, notes = left(coalesce(p_notes,''), 1500), perms = coalesce(p_perms, perms),
         commands = coalesce(p_commands, commands), updated_at = now() where id = p_bot;
  if not b.official then
    for r in select conversation_id from public.conversation_bots where bot_id = p_bot loop
      update public.conversation_bots set pending = true where conversation_id = r.conversation_id and bot_id = p_bot;
      delete from public.bot_requests where conversation_id = r.conversation_id and bot_id = p_bot and resolved_at is null;
      insert into public.bot_requests(conversation_id, bot_id, kind, version, notes, perms)
      values (r.conversation_id, p_bot, 'update', v_ver, left(coalesce(p_notes,''), 1500), coalesce(p_perms, b.perms));
    end loop;
  end if;
  return v_ver;
end $$;

-- ---------- Ajout / retrait d'un bot dans une conversation ----------
create or replace function public.conv_is_admin(p_conv uuid, p_user uuid default auth.uid())
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = p_user and role = 'admin')
$$;

-- Recherche d'un bot par nom d'utilisateur (public) ou avec sa clé (privé)
create or replace function public.bot_find(p_username text, p_key text default null)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare b public.bots; v_un text := lower(trim(p_username));
begin
  v_un := regexp_replace(v_un, '^@', '');
  select * into b from public.bots where username = v_un and status <> 'deleted';
  if not found then return null; end if;
  if b.visibility = 'private' and coalesce(p_key, '') <> coalesce(b.access_key, '~') then return null; end if;
  return jsonb_build_object('id', b.id, 'name', b.name, 'username', b.username, 'prefix', b.prefix, 'description', b.description,
    'perms', b.perms, 'commands', b.commands, 'visibility', b.visibility, 'official', b.official, 'version', b.version,
    'status', b.status, 'owner', coalesce((select username from public.profiles where id = b.owner_id), b.owner_username));
end $$;

create or replace function public.bot_add_to_conv(p_conv uuid, p_bot uuid, p_accepted text[])
returns void language plpgsql security definer set search_path = public as $$
declare b public.bots; v_c public.conversations;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not public.conv_is_admin(p_conv) then raise exception 'Seul un administrateur du groupe peut ajouter un bot'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'Les bots se placent dans les groupes'; end if;
  select * into b from public.bots where id = p_bot and status <> 'deleted';
  if not found then raise exception 'Bot introuvable'; end if;
  if b.official then raise exception 'Ce bot est déjà présent dans tous les groupes'; end if;
  if b.status = 'blocked' then raise exception 'Bot bloqué par Ciffron'; end if;
  if (select array(select unnest(b.perms) order by 1)) <> (select array(select unnest(coalesce(p_accepted,'{}')) order by 1)) then
    raise exception 'Toutes les permissions demandées doivent être acceptées'; end if;
  if exists(select 1 from public.conversation_bots where conversation_id = p_conv and bot_id = p_bot) then raise exception 'Bot déjà présent'; end if;
  if exists(select 1 from public.conversation_bots cb join public.bots x on x.id = cb.bot_id where cb.conversation_id = p_conv and lower(x.prefix) = lower(b.prefix)) then
    raise exception 'Un bot avec ce préfixe est déjà présent'; end if;
  insert into public.conversation_bots(conversation_id, bot_id, added_by, accepted_perms, accepted_version)
  values (p_conv, p_bot, auth.uid(), b.perms, b.version);
  if v_c.mode = 'clear' then
    insert into public.messages(conversation_id, sender_id, kind, body) values (p_conv, auth.uid(), 'system', b.name || 'BOT a été ajouté au groupe');
  end if;
end $$;

create or replace function public.bot_remove_from_conv(p_conv uuid, p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if (select official from public.bots where id = p_bot) then raise exception 'LibonBOT ne peut pas être retiré'; end if;
  delete from public.conversation_bots where conversation_id = p_conv and bot_id = p_bot;
  delete from public.bot_requests where conversation_id = p_conv and bot_id = p_bot and resolved_at is null;
  delete from public.bot_conv_state where conversation_id = p_conv and bot_id = p_bot;
end $$;

-- Bots d'une conversation (installés + officiels), sans code
create or replace function public.bot_conv_list(p_conv uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if (select kind from public.conversations where id = p_conv) <> 'group' then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'username', b.username, 'prefix', b.prefix,
      'description', b.description, 'commands', b.commands, 'perms', b.perms, 'official', b.official, 'version', b.version,
      'status', b.status, 'pending', coalesce(cb.pending, false), 'accepted_perms', coalesce(cb.accepted_perms, b.perms),
      'blocked_reason', b.blocked_reason) order by b.official desc, b.created_at)
    from public.bots b left join public.conversation_bots cb on cb.bot_id = b.id and cb.conversation_id = p_conv
    where b.status <> 'deleted' and (b.official or cb.bot_id is not null)), '[]'::jsonb);
end $$;

-- Code d'un bot, uniquement pour exécution dans les conversations où il est installé (jamais affiché)
create or replace function public.bot_bundle(p_bot uuid, p_conv uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare b public.bots;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into b from public.bots where id = p_bot and status = 'active';
  if not found then return null; end if;
  if not b.official then
    if not exists(select 1 from public.conversation_bots where conversation_id = p_conv and bot_id = p_bot and not pending) then return null; end if;
  end if;
  return jsonb_build_object('version', b.version, 'files',
    coalesce((select jsonb_agg(jsonb_build_object('path', f.path, 'content', f.content, 'data', f.data_b64) order by f.path)
              from public.bot_files f where f.bot_id = p_bot and not f.runtime), '[]'::jsonb));
end $$;

-- Demandes en attente pour les administrateurs de groupes
create or replace function public.bot_requests_mine()
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'conversation_id', r.conversation_id, 'bot', b.name || 'BOT',
      'bot_id', b.id, 'version', r.version, 'notes', r.notes, 'perms', r.perms, 'created_at', r.created_at,
      'prev_perms', coalesce(cb.accepted_perms, '{}')) order by r.created_at)
    from public.bot_requests r join public.bots b on b.id = r.bot_id
    left join public.conversation_bots cb on cb.conversation_id = r.conversation_id and cb.bot_id = r.bot_id
    where r.resolved_at is null and public.conv_is_admin(r.conversation_id)), '[]'::jsonb);
end $$;

create or replace function public.bot_request_resolve(p_id bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r public.bot_requests;
begin
  select * into r from public.bot_requests where id = p_id and resolved_at is null;
  if not found then raise exception 'Demande introuvable'; end if;
  if not public.conv_is_admin(r.conversation_id) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  update public.bot_requests set resolved_at = now(), accepted = p_accept where id = p_id;
  if p_accept then
    update public.conversation_bots set pending = false, accepted_version = r.version, accepted_perms = r.perms
     where conversation_id = r.conversation_id and bot_id = r.bot_id;
  else
    delete from public.conversation_bots where conversation_id = r.conversation_id and bot_id = r.bot_id;
    delete from public.bot_conv_state where conversation_id = r.conversation_id and bot_id = r.bot_id;
  end if;
end $$;

-- État partagé d'un bot dans une conversation (clé/valeur)
create or replace function public.bot_state_set(p_conv uuid, p_bot uuid, p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not exists(select 1 from public.bots b left join public.conversation_bots cb on cb.bot_id = b.id and cb.conversation_id = p_conv
                 where b.id = p_bot and b.status = 'active' and (b.official or (cb.bot_id is not null and not cb.pending))) then
    raise exception 'Bot absent de la conversation'; end if;
  if char_length(p_value::text) > 20000 then raise exception 'Valeur trop grande'; end if;
  if (select count(*) from public.bot_conv_state where conversation_id = p_conv and bot_id = p_bot) >= 200
     and not exists(select 1 from public.bot_conv_state where conversation_id = p_conv and bot_id = p_bot and key = p_key) then
    raise exception 'Trop de clés'; end if;
  insert into public.bot_conv_state(conversation_id, bot_id, key, value) values (p_conv, p_bot, p_key, p_value)
  on conflict (conversation_id, bot_id, key) do update set value = excluded.value, updated_at = now();
end $$;

-- ---------- Numéro de message par conversation (visible en mode développeur) ----------
alter table public.messages add column if not exists seq bigint;
create table if not exists public.conversation_seq (conversation_id uuid primary key references public.conversations(id) on delete cascade, n bigint not null default 0);
alter table public.conversation_seq enable row level security;
create or replace function public.trg_msg_seq() returns trigger language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.conversation_seq(conversation_id, n) values (new.conversation_id, 1)
  on conflict (conversation_id) do update set n = public.conversation_seq.n + 1 returning n into v;
  new.seq := v; return new;
end $$;
drop trigger if exists msg_seq on public.messages;
create trigger msg_seq before insert on public.messages for each row execute function public.trg_msg_seq();
do $$ begin
  if exists(select 1 from public.messages where seq is null) then
    with n as (select id, row_number() over (partition by conversation_id order by id) rn from public.messages)
    update public.messages m set seq = n.rn from n where n.id = m.id;
    insert into public.conversation_seq(conversation_id, n) select conversation_id, max(seq) from public.messages group by conversation_id
      on conflict (conversation_id) do update set n = excluded.n;
  end if;
end $$;

-- ---------- LibonBOT : droits, bannissements, journaux ----------
alter table public.conversations add column if not exists libon_id text;
create unique index if not exists conversations_libon_uq on public.conversations(libon_id) where libon_id is not null;

create table if not exists public.conversation_rights (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  granted_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
alter table public.conversation_rights enable row level security;
drop policy if exists cr_select on public.conversation_rights;
create policy cr_select on public.conversation_rights for select to authenticated using (public.is_member(conversation_id));
grant select on public.conversation_rights to authenticated;

create table if not exists public.conversation_bans (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  by_id uuid references public.profiles(id) on delete set null,
  seconds numeric(14,3) not null default 0,       -- 0 = infini
  until timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  lifted_at timestamptz
);
create index if not exists cbans_idx on public.conversation_bans(conversation_id, user_id);
alter table public.conversation_bans enable row level security;
drop policy if exists cbans_select on public.conversation_bans;
create policy cbans_select on public.conversation_bans for select to authenticated using (public.is_member(conversation_id));
grant select on public.conversation_bans to authenticated;

create table if not exists public.conversation_user_log (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  action text not null,
  by_name text,
  detail text,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists culog_idx on public.conversation_user_log(conversation_id, user_id, id);
alter table public.conversation_user_log enable row level security;
drop policy if exists culog_select on public.conversation_user_log;
create policy culog_select on public.conversation_user_log for select to authenticated using (public.is_member(conversation_id));
grant select on public.conversation_user_log to authenticated;

-- Droit d'utiliser les commandes de LibonBOT (administrateur ou droit accordé)
create or replace function public.has_cmd_right(p_conv uuid, p_user uuid default auth.uid())
returns boolean language sql security definer stable set search_path = public as $$
  select public.conv_is_admin(p_conv, p_user) or exists(select 1 from public.conversation_rights where conversation_id = p_conv and user_id = p_user)
$$;

-- Vérification demandée par un autre client (kick / pause signés par un nom d'utilisateur)
create or replace function public.user_has_cmd_right(p_conv uuid, p_username text)
returns boolean language plpgsql security definer stable set search_path = public as $$
declare v uuid;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select id into v from public.profiles where username = lower(p_username);
  if v is null then return false; end if;
  return public.is_member_of(p_conv, v) and public.has_cmd_right(p_conv, v);
end $$;
create or replace function public.is_member_of(p_conv uuid, p_user uuid) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = p_user)
$$;

create or replace function public.libon_server_id(p_conv uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text; v_n int := 0;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select libon_id into v from public.conversations where id = p_conv;
  if v is not null then return v; end if;
  loop
    v := lpad((floor(random()*1e16))::bigint::text, 16, '0');
    begin
      update public.conversations set libon_id = v where id = p_conv and libon_id is null;
      exit;
    exception when unique_violation then v_n := v_n + 1; if v_n > 20 then raise; end if;
    end;
  end loop;
  select libon_id into v from public.conversations where id = p_conv;
  perform public.libon_file_append('servers/srv.txt', v || ' ' || coalesce((select coalesce(name,'groupe') from public.conversations where id = p_conv), 'groupe') );
  return v;
end $$;

-- Écriture dans le répertoire (fichiers d'exécution) du bot officiel LibonBOT
create or replace function public.libon_bot() returns uuid language sql security definer stable set search_path = public as $$
  select id from public.bots where username = 'libonbot' and official limit 1
$$;
create or replace function public.libon_file_append(p_path text, p_line text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.libon_bot();
begin
  if v is null then return; end if;
  insert into public.bot_files(bot_id, path, content, size, runtime) values (v, p_path, p_line || E'\n', octet_length(p_line) + 1, true)
  on conflict (bot_id, path) do update set content = coalesce(public.bot_files.content, '') || excluded.content,
        size = octet_length(coalesce(public.bot_files.content, '') || excluded.content), updated_at = now();
end $$;
create or replace function public.libon_file_rewrite(p_path text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.libon_bot();
begin
  if v is null then return; end if;
  insert into public.bot_files(bot_id, path, content, size, runtime) values (v, p_path, p_text, octet_length(p_text), true)
  on conflict (bot_id, path) do update set content = excluded.content, size = excluded.size, updated_at = now();
end $$;

create or replace function public.libon_log(p_conv uuid, p_user uuid, p_action text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare v_by text := coalesce((select username from public.profiles where id = auth.uid()), '?'); v_sid text; v_un text;
begin
  insert into public.conversation_user_log(conversation_id, user_id, action, by_name, detail) values (p_conv, p_user, p_action, v_by, p_detail);
  select libon_id into v_sid from public.conversations where id = p_conv;
  select username into v_un from public.profiles where id = p_user;
  if v_sid is not null then
    perform public.libon_file_append('servers/' || v_sid || '/user.txt', v_un || ' | ' || p_action || ' | par ' || v_by || ' | ' || coalesce(p_detail,'') || ' | ' || to_char(clock_timestamp(), 'YYYY-MM-DD"T"HH24:MI:SS.MS'));
  end if;
end $$;

-- Reconstruit ban.txt d'un serveur à partir de la table (source de vérité)
create or replace function public.libon_rewrite_bans(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_sid text; v_txt text;
begin
  select libon_id into v_sid from public.conversations where id = p_conv;
  if v_sid is null then return; end if;
  select coalesce(string_agg(p.username || ' | ' || case when b.seconds = 0 then '0' else trim(to_char(b.seconds, 'FM999999999990.000')) end || ' | ' || to_char(b.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS'), E'\n' order by b.id), '')
    into v_txt from public.conversation_bans b join public.profiles p on p.id = b.user_id
   where b.conversation_id = p_conv and b.lifted_at is null and (b.until is null or b.until > now());
  perform public.libon_file_rewrite('servers/' || v_sid || '/ban.txt', v_txt || case when v_txt = '' then '' else E'\n' end);
end $$;

create or replace function public.ban_active(p_conv uuid, p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.conversation_bans where conversation_id = p_conv and user_id = p_user and lifted_at is null and (until is null or until > now()))
$$;

-- add_member : refuse les personnes bannies du groupe (le reste est inchangé)
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p where p.proname = 'add_member' and p.pronamespace = 'public'::regnamespace;
  if v_src is not null and v_src not like '%ban_active%' then
    v_src := replace(v_src, E'  if v_c.kind <> ''group'' then raise exception ''Réservé aux groupes''; end if;',
      E'  if v_c.kind <> ''group'' then raise exception ''Réservé aux groupes''; end if;\n  if exists(select 1 from public.profiles pp where pp.username = v_un and public.ban_active(p_conv, pp.id)) then raise exception ''Cette personne est bannie du groupe''; end if;');
    execute v_src;
  end if;
end $$;

-- Commande LibonBOT exécutée avec les droits de la personne qui l'invoque.
-- p_action : adm | del | rename | droit | ban | deban | cj | banlist | print | delmsg | fpause | bypass | add_check
create or replace function public.libon_do(p_conv uuid, p_action text, p_target text default null, p_arg text default null, p_secs numeric default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid(); v_c public.conversations; v_t uuid; v_tn text := lower(regexp_replace(coalesce(p_target,''), '^@', ''));
  v_sid text; v_rows jsonb; v_msg public.messages; v_b public.conversation_bans; v_mn text;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'LibonBOT agit dans les groupes'; end if;
  if not public.has_cmd_right(p_conv) then raise exception 'Vous n''avez pas le droit d''utiliser les commandes de LibonBOT'; end if;
  v_sid := public.libon_server_id(p_conv);
  select username into v_mn from public.profiles where id = v_me;
  if v_tn <> '' then select id into v_t from public.profiles where username = v_tn; end if;

  if p_action in ('adm','del','droit','ban','deban','cj','add_check') and v_tn = '' then raise exception 'Indiquez un nom d''utilisateur'; end if;
  if p_action in ('adm','del','droit','ban','deban','cj') and v_t is null then raise exception 'Utilisateur introuvable'; end if;

  if p_action = 'add_check' then
    if public.ban_active(p_conv, v_t) then raise exception 'Cette personne est bannie du groupe'; end if;
    if exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = v_t) then raise exception 'Déjà dans le groupe'; end if;
    if not exists(select 1 from public.friendships f where f.status = 'accepted' and ((f.requester = v_me and f.addressee = v_t) or (f.requester = v_t and f.addressee = v_me))) then
      raise exception 'Vous devez être ami(e) avec cette personne pour l''ajouter'; end if;
    perform public.libon_log(p_conv, v_t, 'ajout', null);
    return jsonb_build_object('ok', true);

  elsif p_action = 'del' then
    if not public.is_member_of(p_conv, v_t) then raise exception 'Cette personne n''est pas dans le groupe'; end if;
    if v_t = v_me then raise exception 'Utilisez « Quitter le groupe »'; end if;
    if public.conv_is_admin(p_conv, v_t) and not public.conv_is_admin(p_conv) then raise exception 'Seul un administrateur peut retirer un administrateur'; end if;
    delete from public.conversation_members where conversation_id = p_conv and user_id = v_t;
    delete from public.conversation_keys where conversation_id = p_conv and user_id = v_t;
    delete from public.conversation_rights where conversation_id = p_conv and user_id = v_t;
    perform public.libon_log(p_conv, v_t, 'retrait', null);
    if v_c.mode = 'clear' then insert into public.messages(conversation_id, sender_id, kind, body) values (p_conv, v_me, 'system', '@' || v_tn || ' a été retiré du groupe'); end if;
    return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' a été retiré du groupe');

  elsif p_action = 'adm' then
    if not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs'; end if;
    if not public.is_member_of(p_conv, v_t) then raise exception 'Cette personne n''est pas dans le groupe'; end if;
    if public.conv_is_admin(p_conv, v_t) then
      if (select count(*) from public.conversation_members where conversation_id = p_conv and role = 'admin') < 2 then raise exception 'Il faut au moins un administrateur'; end if;
      update public.conversation_members set role = 'member' where conversation_id = p_conv and user_id = v_t;
      perform public.libon_log(p_conv, v_t, 'admin retiré', null);
      return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' n''est plus administrateur');
    else
      update public.conversation_members set role = 'admin' where conversation_id = p_conv and user_id = v_t;
      perform public.libon_log(p_conv, v_t, 'admin accordé', null);
      return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' est maintenant administrateur');
    end if;

  elsif p_action = 'rename' then
    if char_length(trim(coalesce(p_arg,''))) not between 1 and 40 then raise exception 'Nom invalide (1 à 40 caractères)'; end if;
    update public.conversations set name = trim(p_arg) where id = p_conv;
    return jsonb_build_object('ok', true, 'text', 'Groupe renommé en « ' || trim(p_arg) || ' »');

  elsif p_action = 'droit' then
    if not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs'; end if;
    if not public.is_member_of(p_conv, v_t) then raise exception 'Cette personne n''est pas dans le groupe'; end if;
    if exists(select 1 from public.conversation_rights where conversation_id = p_conv and user_id = v_t) then
      delete from public.conversation_rights where conversation_id = p_conv and user_id = v_t;
      perform public.libon_log(p_conv, v_t, 'droit retiré', null);
      return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' n''a plus le droit d''utiliser les commandes');
    end if;
    insert into public.conversation_rights(conversation_id, user_id, granted_by) values (p_conv, v_t, v_me);
    perform public.libon_log(p_conv, v_t, 'droit accordé', null);
    return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' peut maintenant utiliser les commandes de LibonBOT');

  elsif p_action = 'ban' then
    if v_t = v_me then raise exception 'Vous ne pouvez pas vous bannir'; end if;
    if public.conv_is_admin(p_conv, v_t) and not public.conv_is_admin(p_conv) then raise exception 'Seul un administrateur peut bannir un administrateur'; end if;
    if p_secs < 0 or p_secs > 315360000 then raise exception 'Durée invalide'; end if;
    update public.conversation_bans set lifted_at = clock_timestamp() where conversation_id = p_conv and user_id = v_t and lifted_at is null;
    insert into public.conversation_bans(conversation_id, user_id, by_id, seconds, until)
    values (p_conv, v_t, v_me, p_secs, case when p_secs = 0 then null else clock_timestamp() + make_interval(secs => p_secs::double precision) end)
    returning * into v_b;
    delete from public.conversation_members where conversation_id = p_conv and user_id = v_t;
    delete from public.conversation_keys where conversation_id = p_conv and user_id = v_t;
    delete from public.conversation_rights where conversation_id = p_conv and user_id = v_t;
    perform public.libon_log(p_conv, v_t, 'ban', case when p_secs = 0 then 'infini' else p_secs::text || ' s' end);
    perform public.libon_rewrite_bans(p_conv);
    if v_c.mode = 'clear' then insert into public.messages(conversation_id, sender_id, kind, body) values (p_conv, v_me, 'system', '@' || v_tn || ' a été banni du groupe'); end if;
    return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' est banni ' || case when p_secs = 0 then 'sans limite de temps' else 'pour ' || p_secs::text || ' s' end);

  elsif p_action = 'deban' then
    update public.conversation_bans set lifted_at = clock_timestamp() where conversation_id = p_conv and user_id = v_t and lifted_at is null;
    if not found then raise exception 'Cette personne n''est pas bannie'; end if;
    perform public.libon_log(p_conv, v_t, 'déban', null);
    perform public.libon_rewrite_bans(p_conv);
    return jsonb_build_object('ok', true, 'text', '@' || v_tn || ' n''est plus banni');

  elsif p_action = 'banlist' then
    select coalesce(jsonb_agg(jsonb_build_object('user', p.username, 'seconds', b.seconds, 'until', b.until, 'at', b.created_at) order by b.id), '[]'::jsonb) into v_rows
      from public.conversation_bans b join public.profiles p on p.id = b.user_id
     where b.conversation_id = p_conv and b.lifted_at is null and (b.until is null or b.until > now());
    return jsonb_build_object('ok', true, 'rows', v_rows);

  elsif p_action = 'cj' then
    select coalesce(jsonb_agg(jsonb_build_object('action', l.action, 'by', l.by_name, 'detail', l.detail, 'at', l.created_at) order by l.id), '[]'::jsonb) into v_rows
      from (select * from public.conversation_user_log where conversation_id = p_conv and user_id = v_t order by id desc limit 50) l;
    return jsonb_build_object('ok', true, 'rows', v_rows);

  elsif p_action = 'print' then
    return jsonb_build_object('ok', true, 'server', v_sid, 'name', v_c.name, 'members',
      (select coalesce(jsonb_agg(jsonb_build_object('user', p.username, 'role', m.role, 'right', exists(select 1 from public.conversation_rights r where r.conversation_id = p_conv and r.user_id = m.user_id)) order by p.username), '[]'::jsonb)
         from public.conversation_members m join public.profiles p on p.id = m.user_id where m.conversation_id = p_conv),
      'bots', (select coalesce(jsonb_agg(b.name || 'BOT'), '[]'::jsonb) from public.bots b left join public.conversation_bots cb on cb.bot_id = b.id and cb.conversation_id = p_conv where b.status <> 'deleted' and (b.official or cb.bot_id is not null)));

  elsif p_action = 'delmsg' then
    select * into v_msg from public.messages where conversation_id = p_conv and seq = nullif(p_arg,'')::bigint;
    if not found then raise exception 'Ce message n''appartient pas à ce groupe'; end if;
    delete from public.messages where id = v_msg.id;
    perform public.libon_log(p_conv, v_msg.sender_id, 'message supprimé', '#' || v_msg.seq::text);
    return jsonb_build_object('ok', true, 'text', 'Message #' || v_msg.seq::text || ' supprimé');

  elsif p_action in ('fpause','bypass') then
    if p_action = 'bypass' and not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs'; end if;
    insert into public.bot_conv_state(conversation_id, bot_id, key, value) values (p_conv, public.libon_bot(), p_action, to_jsonb(coalesce(p_arg,'n') in ('o','O','oui','1','true')))
    on conflict (conversation_id, bot_id, key) do update set value = excluded.value, updated_at = now();
    perform public.libon_log(p_conv, v_me, p_action, coalesce(p_arg,'n'));
    return jsonb_build_object('ok', true, 'on', coalesce(p_arg,'n') in ('o','O','oui','1','true'));
  end if;
  raise exception 'Commande inconnue';
end $$;

-- Journalise une action de jeu/appel (kick, pause) déjà autorisée par has_cmd_right
create or replace function public.libon_note(p_conv uuid, p_user text, p_action text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if p_action not in ('kick','pause','fin de pause','bypass') then raise exception 'Action inconnue'; end if;
  if p_action in ('kick','bypass') and not public.has_cmd_right(p_conv) then raise exception 'Droit manquant'; end if;
  if p_action in ('pause','fin de pause') and not (public.has_cmd_right(p_conv) or coalesce((select (value)::text = 'true' from public.bot_conv_state where conversation_id = p_conv and bot_id = public.libon_bot() and key = 'fpause'), false)) then
    raise exception 'La pause n''est pas activée'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(coalesce(p_user,''), '^@', ''));
  if v is null then v := auth.uid(); end if;
  perform public.libon_server_id(p_conv);
  perform public.libon_log(p_conv, v, p_action, left(coalesce(p_detail,''), 200));
end $$;

-- ---------- Ciffron ----------
create table if not exists public.ciffron_rules (
  id text primary key, pat text not null, fl text not null default '', files text not null default '*', reason text not null, enabled boolean not null default true
);
alter table public.ciffron_rules enable row level security;
drop policy if exists cif_rules_sel on public.ciffron_rules;
create policy cif_rules_sel on public.ciffron_rules for select to authenticated using (enabled);
grant select on public.ciffron_rules to authenticated;

create table if not exists public.ciffron_exceptions (
  id bigint generated always as identity primary key,
  code text not null check (char_length(code) <= 20000),
  note text not null default '',
  added_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  removed_at timestamptz
);
alter table public.ciffron_exceptions enable row level security;
drop policy if exists cif_exc_sel on public.ciffron_exceptions;
create policy cif_exc_sel on public.ciffron_exceptions for select to authenticated using (removed_at is null);
grant select on public.ciffron_exceptions to authenticated;

create table if not exists public.ciffron_allow (        -- exceptions déclaratives (règle, bot) appliquées aussi côté serveur
  rule text not null, bot_id uuid, primary key (rule, bot_id)
);
alter table public.ciffron_allow enable row level security;

create table if not exists public.ciffron_exception_log (   -- journal immuable : tout le code ajouté
  id bigint generated always as identity primary key,
  exception_id bigint, action text not null check (action in ('ajout','retrait')),
  code text not null, note text, staff_id uuid, staff_name text, created_at timestamptz not null default now()
);
alter table public.ciffron_exception_log enable row level security;
drop policy if exists cif_exlog_sel on public.ciffron_exception_log;
create policy cif_exlog_sel on public.ciffron_exception_log for select to authenticated using (public.is_staff('admin'));
grant select on public.ciffron_exception_log to authenticated;
revoke update, delete, truncate on public.ciffron_exception_log from authenticated, anon, public;
drop trigger if exists cif_exlog_imm on public.ciffron_exception_log;
create trigger cif_exlog_imm before update or delete on public.ciffron_exception_log for each row execute function public.trg_immutable();

create table if not exists public.ciffron_flags (
  id bigint generated always as identity primary key,
  bot_id uuid not null references public.bots(id) on delete cascade,
  owner_id uuid references public.profiles(id) on delete set null,
  source text not null default 'static' check (source in ('static','runtime')),
  status text not null default 'open' check (status in ('open','confirmed','dismissed','appeal','final')),
  findings jsonb not null default '[]'::jsonb,       -- [{file,line,text,rule,reason}]
  created_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  note text,
  appeal_text text,
  appeal_at timestamptz,
  reporters uuid[] not null default '{}'
);
create index if not exists ciffron_flags_bot on public.ciffron_flags(bot_id);
alter table public.ciffron_flags enable row level security;
drop policy if exists cif_flags_sel on public.ciffron_flags;
create policy cif_flags_sel on public.ciffron_flags for select to authenticated using (owner_id = auth.uid() or public.is_staff('moderator'));
grant select on public.ciffron_flags to authenticated;

create table if not exists public.ciffron_protected (     -- lignes déclarées saines (apparaissent en bleu)
  bot_id uuid not null references public.bots(id) on delete cascade,
  file text not null, line_hash text not null, primary key (bot_id, file, line_hash)
);
alter table public.ciffron_protected enable row level security;
drop policy if exists cif_prot_sel on public.ciffron_protected;
create policy cif_prot_sel on public.ciffron_protected for select to authenticated using (public.bot_is_owner(bot_id) or public.is_staff('moderator'));
grant select on public.ciffron_protected to authenticated;

-- hachage identique à ciffron.js (FNV-1a 32 bits sur « fichier\nligne ») — calculé côté serveur pour la protection
create or replace function public.cif_hash(p_file text, p_line text) returns text language plpgsql immutable as $$
declare s bytea := convert_to(p_file || E'\n' || trim(p_line), 'UTF8'); h bigint := 2166136261; i int; b int;
begin
  -- JS hache des unités UTF-16 ; pour l'ASCII c'est identique. Pour le reste, le client fournit le hachage.
  for i in 0 .. length(s) - 1 loop
    b := get_byte(s, i);
    h := (h # b);
    h := (h * 16777619) % 4294967296;
  end loop;
  return lpad(to_hex(h), 8, '0');
end $$;

-- Un client (développeur ou membre d'un groupe utilisant le bot) signale des lignes
create or replace function public.ciffron_flag(p_bot uuid, p_source text, p_findings jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  b public.bots; v_me uuid := auth.uid(); v_id bigint; v_ok jsonb := '[]'::jsonb; e jsonb; f public.bot_files; v_line text; r public.ciffron_rules; v_open public.ciffron_flags; v_n int;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  select * into b from public.bots where id = p_bot and status <> 'deleted';
  if not found then raise exception 'Bot introuvable'; end if;
  if b.official then return null; end if;                    -- bots officiels : examinés par l'administration seulement
  if not (public.bot_is_owner(p_bot) or exists(select 1 from public.conversation_bots cb join public.conversation_members m on m.conversation_id = cb.conversation_id and m.user_id = v_me where cb.bot_id = p_bot)) then
    raise exception 'Accès refusé'; end if;
  if p_source not in ('static','runtime') then raise exception 'Source invalide'; end if;
  if p_source = 'static' then
    -- chaque détection est revérifiée sur le contenu stocké : impossible de signaler une ligne saine
    for e in select * from jsonb_array_elements(p_findings) limit 60 loop
      select * into f from public.bot_files where bot_id = p_bot and path = e->>'file';
      continue when not found or f.content is null;
      v_line := (string_to_array(f.content, E'\n'))[(e->>'line')::int];
      continue when v_line is null;
      select * into r from public.ciffron_rules where id = e->>'rule' and enabled;
      continue when not found;
      continue when not (case when r.fl like '%i%' then v_line ~* r.pat else v_line ~ r.pat end);
      continue when exists(select 1 from public.ciffron_allow a where a.rule = r.id and (a.bot_id is null or a.bot_id = p_bot));
      continue when exists(select 1 from public.ciffron_protected pr where pr.bot_id = p_bot and pr.file = f.path and pr.line_hash = coalesce(e->>'hash', public.cif_hash(f.path, v_line)));
      v_ok := v_ok || jsonb_build_object('file', f.path, 'line', (e->>'line')::int, 'text', left(v_line, 300), 'rule', r.id, 'reason', r.reason,
                                           'hash', coalesce(e->>'hash', public.cif_hash(f.path, v_line)));
    end loop;
    if jsonb_array_length(v_ok) = 0 then return null; end if;
    if not public.bot_is_owner(p_bot) then raise exception 'Seul le développeur déclenche une analyse statique'; end if;
  else
    -- exécution : il faut deux personnes différentes pour bloquer ; sinon simple signalement
    v_ok := coalesce(p_findings, '[]'::jsonb);
    if jsonb_array_length(v_ok) > 20 then raise exception 'Trop de lignes'; end if;
    select * into v_open from public.ciffron_flags where bot_id = p_bot and source = 'runtime' and status = 'open' order by id desc limit 1;
    if found then
      if not (v_me = any(v_open.reporters)) then update public.ciffron_flags set reporters = reporters || v_me where id = v_open.id; v_open.reporters := v_open.reporters || v_me; end if;
      if coalesce(array_length(v_open.reporters, 1), 0) < 2 then return v_open.id; end if;
      v_id := v_open.id;
    else
      insert into public.ciffron_flags(bot_id, owner_id, source, status, findings, reporters) values (p_bot, b.owner_id, 'runtime', 'open', v_ok, array[v_me]) returning id into v_id;
      return v_id;                                               -- premier signalement : pas de blocage
    end if;
    perform public.cif_apply_block(v_id, b);
    return v_id;
  end if;
  insert into public.ciffron_flags(bot_id, owner_id, source, status, findings) values (p_bot, b.owner_id, p_source, 'open', v_ok) returning id into v_id;
  perform public.cif_apply_block(v_id, b);
  return v_id;
end $$;

create or replace function public.cif_apply_block(p_flag bigint, b public.bots)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.bots set status = 'blocked', blocked_reason = 'Bloqué par Ciffron' where id = b.id;
  if b.owner_id is not null then
    insert into public.dev_status(user_id, enabled, blocked, blocked_reason, blocked_at)
    values (b.owner_id, false, true, 'Mode développeur bloqué par Ciffron (bot ' || b.name || 'BOT)', now())
    on conflict (user_id) do update set enabled = false, blocked = true, blocked_reason = excluded.blocked_reason, blocked_at = now();
    insert into public.dev_ip_blocks(ip, flag_id) select distinct ip, p_flag from public.user_ips where user_id = b.owner_id on conflict do nothing;
  end if;
end $$;

create or replace function public.cif_restore(p_flag bigint)
returns void language plpgsql security definer set search_path = public as $$
declare fl public.ciffron_flags; e jsonb;
begin
  select * into fl from public.ciffron_flags where id = p_flag;
  update public.bots set status = 'active', blocked_reason = null where id = fl.bot_id and status = 'blocked';
  if fl.owner_id is not null and not exists(select 1 from public.ciffron_flags x where x.owner_id = fl.owner_id and x.id <> p_flag and x.status in ('open','confirmed','appeal','final')) then
    update public.dev_status set blocked = false, blocked_reason = null where user_id = fl.owner_id;
  end if;
  delete from public.dev_ip_blocks where flag_id = p_flag;
  for e in select * from jsonb_array_elements(fl.findings) loop
    if e->>'hash' is not null then
      insert into public.ciffron_protected(bot_id, file, line_hash) values (fl.bot_id, e->>'file', e->>'hash') on conflict do nothing;
    end if;
  end loop;
end $$;

-- Modération (modérateur ou administrateur)
create or replace function public.ciffron_decide(p_flag bigint, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare fl public.ciffron_flags; b public.bots;
begin
  if not public.is_staff('moderator') then raise exception 'Accès refusé'; end if;
  select * into fl from public.ciffron_flags where id = p_flag for update;
  if not found then raise exception 'Détection introuvable'; end if;
  select * into b from public.bots where id = fl.bot_id;
  if p_decision = 'confirm' then                       -- « Accepter la raison » : plus de contestation possible
    if fl.status <> 'open' then raise exception 'Décision déjà prise'; end if;
    update public.ciffron_flags set status = 'confirmed', decided_by = auth.uid(), decided_at = now(), note = p_note where id = p_flag;
  elsif p_decision = 'dismiss' then                    -- « Refuser » : tout est rendu, lignes protégées
    if fl.status not in ('open','appeal') then raise exception 'Décision déjà prise'; end if;
    update public.ciffron_flags set status = 'dismissed', decided_by = auth.uid(), decided_at = now(), note = p_note where id = p_flag;
    perform public.cif_restore(p_flag);
  elsif p_decision = 'reject_appeal' then              -- appel refusé : définitif, bot supprimé
    if fl.status <> 'appeal' then raise exception 'Aucun appel en cours'; end if;
    update public.ciffron_flags set status = 'final', decided_by = auth.uid(), decided_at = now(), note = p_note where id = p_flag;
    update public.bots set status = 'deleted', username = username || '~' || num::text, prefix = prefix || '~' || num::text where id = fl.bot_id;
    delete from public.conversation_bots where bot_id = fl.bot_id;
  else raise exception 'Décision inconnue'; end if;
  perform public.log_admin('ciffron_' || p_decision, b.name || 'BOT', jsonb_build_object('flag', p_flag, 'note', p_note));
end $$;

-- Appel du développeur (raison longue obligatoire)
create or replace function public.ciffron_appeal(p_flag bigint, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare fl public.ciffron_flags;
begin
  select * into fl from public.ciffron_flags where id = p_flag and owner_id = auth.uid() for update;
  if not found then raise exception 'Détection introuvable'; end if;
  if fl.status <> 'open' then raise exception 'Cette décision ne peut plus être contestée'; end if;
  if char_length(trim(coalesce(p_text,''))) < 300 then raise exception 'Expliquez-vous en au moins 300 caractères'; end if;
  update public.ciffron_flags set status = 'appeal', appeal_text = left(trim(p_text), 6000), appeal_at = now() where id = p_flag;
end $$;

create or replace function public.ciffron_my_flags()
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'bot', b.name || 'BOT', 'bot_id', f.bot_id, 'status', f.status, 'findings', f.findings,
    'created_at', f.created_at, 'note', f.note, 'appeal_text', f.appeal_text) order by f.id desc), '[]'::jsonb)
  from public.ciffron_flags f join public.bots b on b.id = f.bot_id where f.owner_id = auth.uid()
$$;

create or replace function public.ciffron_exception_add(p_code text, p_note text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
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
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  update public.ciffron_exceptions set removed_at = now() where id = p_id and removed_at is null returning * into e;
  if not found then raise exception 'Exception introuvable'; end if;
  insert into public.ciffron_exception_log(exception_id, action, code, note, staff_id, staff_name)
  values (p_id, 'retrait', e.code, e.note, auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('ciffron_exception_retrait', '#' || p_id::text, jsonb_build_object('code', e.code));
end $$;
create or replace function public.ciffron_allow_set(p_rule text, p_bot uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  if p_on then insert into public.ciffron_allow(rule, bot_id) values (p_rule, p_bot) on conflict do nothing;
  else delete from public.ciffron_allow where rule = p_rule and bot_id is not distinct from p_bot; end if;
  perform public.log_admin('ciffron_allow', p_rule, jsonb_build_object('bot', p_bot, 'on', p_on));
end $$;

-- ---------- Administration ----------
create or replace function public.staff_bots()
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_staff('moderator') then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name || 'BOT', 'username', b.username, 'prefix', b.prefix, 'status', b.status, 'official', b.official,
      'owner', coalesce((select username from public.profiles where id = b.owner_id), b.owner_username), 'version', b.version, 'visibility', b.visibility,
      'flags', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'status', f.status, 'source', f.source, 'findings', f.findings, 'created_at', f.created_at,
            'note', f.note, 'appeal_text', f.appeal_text) order by f.id desc), '[]'::jsonb) from public.ciffron_flags f where f.bot_id = b.id)) order by b.created_at)
    from public.bots b where b.status <> 'deleted' or exists(select 1 from public.ciffron_flags f where f.bot_id = b.id and f.status = 'final')), '[]'::jsonb);
end $$;

-- Code source d'un bot : modérateur dans le cadre d'une détection ouverte ; administrateur avec justification (journalisée)
create or replace function public.staff_bot_source(p_bot uuid, p_justification text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bots; v_flag boolean;
begin
  if not public.is_staff('moderator') then raise exception 'Accès refusé'; end if;
  select * into b from public.bots where id = p_bot;
  if not found then raise exception 'Bot introuvable'; end if;
  v_flag := exists(select 1 from public.ciffron_flags where bot_id = p_bot and status in ('open','appeal','confirmed','final'));
  if (public.staff_role() = 'admin' or not v_flag) and char_length(trim(coalesce(p_justification,''))) < 15 then
    raise exception 'Une justification (15 caractères minimum) est obligatoire'; end if;
  perform public.log_admin('voir_source', b.name || 'BOT', jsonb_build_object('justification', p_justification, 'via_flag', v_flag));
  return jsonb_build_object('bot', b.name || 'BOT', 'protected', (select coalesce(jsonb_agg(jsonb_build_object('file', file, 'hash', line_hash)), '[]'::jsonb) from public.ciffron_protected where bot_id = p_bot),
     'files', (select coalesce(jsonb_agg(jsonb_build_object('path', f.path, 'content', f.content, 'binary', f.data_b64 is not null, 'size', f.size) order by f.path), '[]'::jsonb) from public.bot_files f where f.bot_id = p_bot));
end $$;

create or replace function public.staff_ban(p_username text, p_ip text, p_secs numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid; v_ip text := nullif(trim(coalesce(p_ip,'')), '');
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  if nullif(trim(coalesce(p_username,'')),'') is not null then
    select id into v from public.profiles where username = lower(regexp_replace(trim(p_username), '^@', ''));
    if v is null then raise exception 'Utilisateur introuvable'; end if;
    if v = auth.uid() then raise exception 'Vous ne pouvez pas vous bannir'; end if;
    if exists(select 1 from public.site_staff where user_id = v and role = 'admin') then raise exception 'Impossible de bannir un administrateur'; end if;
  elsif v_ip is null then raise exception 'Indiquez un utilisateur ou une IP';
  end if;
  if p_secs is null or p_secs < 0 then raise exception 'Durée invalide'; end if;
  insert into public.site_bans(user_id, ip, until, reason, by_id) values (v, v_ip, case when p_secs = 0 then null else now() + make_interval(secs => p_secs::double precision) end, left(p_reason, 300), auth.uid());
  perform public.log_admin(case when v is not null and v_ip is not null then 'ban_user_ip' when v is not null then 'ban_user' else 'ban_ip' end,
    coalesce(p_username, v_ip), jsonb_build_object('secs', p_secs, 'reason', p_reason, 'ip', v_ip));
end $$;

-- Bannit toutes les IP connues d'un utilisateur
create or replace function public.staff_ban_user_ips(p_username text, p_secs numeric, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
declare v uuid; r record; n int := 0;
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(p_username), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  for r in select distinct ip from public.user_ips where user_id = v loop
    insert into public.site_bans(ip, until, reason, by_id) values (r.ip, case when p_secs = 0 then null else now() + make_interval(secs => p_secs::double precision) end, left(coalesce(p_reason,''), 300), auth.uid());
    n := n + 1;
  end loop;
  perform public.log_admin('ban_ips_utilisateur', p_username, jsonb_build_object('n', n, 'secs', p_secs, 'reason', p_reason));
  return n;
end $$;

create or replace function public.staff_unban(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  update public.site_bans set lifted_at = now(), lifted_by = auth.uid() where id = p_id and lifted_at is null;
  if not found then raise exception 'Bannissement introuvable'; end if;
  perform public.log_admin('deban', '#' || p_id::text, '{}'::jsonb);
end $$;

create or replace function public.staff_ban_list()
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'user', (select username from public.profiles where id = b.user_id), 'ip', b.ip, 'until', b.until,
     'reason', b.reason, 'by', (select username from public.profiles where id = b.by_id), 'created_at', b.created_at,
     'active', b.lifted_at is null and (b.until is null or b.until > now()), 'lifted_at', b.lifted_at) order by b.id desc) from public.site_bans b), '[]'::jsonb);
end $$;

create or replace function public.staff_logs(p_limit int default 200)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select id, staff_name, action, target, detail, created_at from public.admin_logs order by id desc limit least(coalesce(p_limit,200), 1000)) l), '[]'::jsonb);
end $$;

create or replace function public.staff_exceptions()
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_staff('admin') then raise exception 'Réservé aux administrateurs'; end if;
  return jsonb_build_object(
    'active', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'note', note, 'created_at', created_at) order by id) from public.ciffron_exceptions where removed_at is null), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select id, exception_id, action, code, note, staff_name, created_at from public.ciffron_exception_log order by id desc limit 200) l), '[]'::jsonb));
end $$;

-- Règles Ciffron (reprises de ciffron.js : mêmes motifs, syntaxe commune JS / PostgreSQL)
insert into public.ciffron_rules(id, pat, fl, files, reason) values
 ('sb-ref', '(supabase|sb[ ]*\.[ ]*(from|rpc|auth|storage|channel|functions)|\.supabase\.co)', 'i', '*', 'Accès visant Supabase (base de données du site)'),
 ('net-api', '(^|[^A-Za-z0-9_$.])(fetch|XMLHttpRequest|WebSocket|EventSource|importScripts|sendBeacon)([^A-Za-z0-9_$]|$)', '', '*', 'Requête réseau directe interdite : le bot doit passer par le SDK'),
 ('dyn-code', '((^|[^A-Za-z0-9_$.])(eval|Function)[ ]*\(|new[ ]+Function|setTimeout[ ]*\([ ]*[''"`]|setInterval[ ]*\([ ]*[''"`])', '', '*', 'Exécution de code dynamique'),
 ('escape', '(^|[^A-Za-z0-9_$])(parent|top|opener|frameElement|globalThis\.parent)[ ]*(\.|\[)', '', 'js|cmm', 'Tentative de sortie du bac à sable'),
 ('storage', '(document[ ]*\.[ ]*cookie|localStorage|sessionStorage|indexedDB)', '', '*', 'Accès au stockage ou aux cookies du navigateur'),
 ('nav', '(window[ ]*\.[ ]*open|location[ ]*\.[ ]*(href|assign|replace)|location[ ]*=[^=])', '', '*', 'Redirection ou ouverture de page'),
 ('ext-url', '(https?://[A-Za-z0-9._-]+|@import|url\([ ]*[''"]?[ ]*//)', 'i', '*', 'Importation étrangère : tout doit être dans le répertoire du bot'),
 ('html-bad', '(<[ ]*(iframe|object|embed|base|form|meta|link)([^A-Za-z0-9]|$)|<[ ]*script[^>]*[ ]src|javascript[ ]*:)', 'i', 'html|js|cmm', 'Élément HTML dangereux'),
 ('obfus', '((atob|btoa|fromCharCode|unescape)[ ]*\(|(\\x[0-9a-fA-F]{2}){6,})', '', 'js|cmm', 'Code obscurci'),
 ('loop-inf', '(tant[ ]+que[ ]+(vrai|1)[ ]*:|while[ ]*\([ ]*(true|1)[ ]*\)|for[ ]*\([ ]*;[ ]*;[ ]*\))', '', 'js|cmm', 'Boucle infinie (risque de spam ou de gel)'),
 ('priv-info', '(sender_id|user_id|auth\.uid|password|mot_de_passe|private_key|public_key)', 'i', 'js|cmm', 'Recherche d’informations privées')
on conflict (id) do nothing;

-- ---------- Droits d'exécution ----------
do $$
declare f text;
begin
  foreach f in array array[
    'staff_role()','is_staff(text)','bot_is_owner(uuid)','ban_state(uuid)','register_ip()','dev_check(uuid)','set_dev_mode(boolean)','dev_info()',
    'bot_create(text,text,text,text,text[],jsonb)','bot_my_list()','bot_regen_key(uuid)','bot_set_visibility(uuid,text)','bot_delete(uuid)',
    'bot_list_files(uuid)','bot_get_file(uuid,text)','bot_save_files(uuid,jsonb)','bot_delete_file(uuid,text)','bot_rename_file(uuid,text,text)',
    'bot_publish(uuid,text,text[],jsonb)','conv_is_admin(uuid,uuid)','bot_find(text,text)','bot_add_to_conv(uuid,uuid,text[])','bot_remove_from_conv(uuid,uuid)',
    'bot_conv_list(uuid)','bot_bundle(uuid,uuid)','bot_requests_mine()','bot_request_resolve(bigint,boolean)','bot_state_set(uuid,uuid,text,jsonb)',
    'has_cmd_right(uuid,uuid)','user_has_cmd_right(uuid,text)','libon_server_id(uuid)','libon_do(uuid,text,text,text,numeric)','libon_note(uuid,text,text,text)',
    'ciffron_flag(uuid,text,jsonb)','ciffron_decide(bigint,text,text)','ciffron_appeal(bigint,text)','ciffron_my_flags()','ciffron_exception_add(text,text)',
    'ciffron_exception_remove(bigint)','ciffron_allow_set(text,uuid,boolean)','staff_bots()','staff_bot_source(uuid,text)','staff_ban(text,text,numeric,text)',
    'staff_ban_user_ips(text,numeric,text)','staff_unban(bigint)','staff_ban_list()','staff_logs(int)','staff_exceptions()'
  ] loop
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  -- fonctions internes : non appelables directement
  foreach f in array array['log_admin(text,text,jsonb)','libon_file_append(text,text)','libon_file_rewrite(text,text)','libon_log(uuid,uuid,text,text)','libon_rewrite_bans(uuid)',
     'cif_apply_block(bigint,public.bots)','cif_restore(bigint)','cif_hash(text,text)','is_member_of(uuid,uuid)','libon_bot()','bot_dev_ok(uuid)','req_ip()','ban_active(uuid,uuid)'
  ] loop
    begin execute format('revoke execute on function public.%s from public, anon, authenticated', f); exception when others then null; end;
  end loop;
end $$;

-- Realtime : les administrateurs de groupe voient arriver les demandes de validation
do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversation_bots') then
    alter publication supabase_realtime add table public.conversation_bots;
  end if;
end $$;
