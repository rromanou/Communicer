-- ============================================================================
-- Communicer! — Patch 7 (additif) : /mp (message privé), liens, clés API, journal des bots
-- À exécuter après le patch 6 (patch_bots.sql). Rejouable sans risque.
-- ============================================================================

-- ---------- Générateur aléatoire sûr (sans biais) ----------
create or replace function public.rand_str(p_n int, p_alpha text)
returns text language plpgsql volatile as $$
declare v_out text := ''; v_b bytea; i int; v int; v_l int := length(p_alpha); v_max int := (256 / length(p_alpha)) * length(p_alpha);
begin
  while length(v_out) < p_n loop
    v_b := uuid_send(gen_random_uuid());
    for i in 0 .. 15 loop
      continue when i in (6, 8);                       -- octets de version/variante de l'UUID : non aléatoires
      v := get_byte(v_b, i);
      if v < v_max then
        v_out := v_out || substr(p_alpha, (v % v_l) + 1, 1);
        exit when length(v_out) >= p_n;
      end if;
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function public.rand_str(int, text) from public, anon, authenticated;

-- ============================================================================
-- 1) Message privé (/mp) : visible seulement par la personne visée (et l'auteur)
-- ============================================================================
alter table public.messages add column if not exists whisper_to uuid references public.profiles(id) on delete cascade;

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    public.is_member(conversation_id)
    and (expires_at is null or expires_at > now())
    and (whisper_to is null or whisper_to = auth.uid() or sender_id = auth.uid())
    and created_at > coalesce(
      (select cm.cleared_at from public.conversation_members cm
        where cm.conversation_id = messages.conversation_id and cm.user_id = auth.uid()),
      '-infinity'::timestamptz)
  );

-- p_cmd_msg : numéro interne du message « /mp … » tapé dans le groupe ; supprimé par LibonBOT tout de suite après
create or replace function public.send_whisper(p_conv uuid, p_target text, p_kind text, p_body text, p_media text default null, p_cmd_msg bigint default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_c public.conversations; v_t uuid; v_row public.messages; v_un text := lower(regexp_replace(coalesce(p_target,''), '^@', ''));
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'Les messages privés LibonBOT se font dans les groupes'; end if;
  if p_kind <> 'text' then raise exception 'Type de message invalide'; end if;
  select id into v_t from public.profiles where username = v_un;
  if v_t is null then raise exception 'Utilisateur introuvable'; end if;
  if v_t = v_me then raise exception 'Vous ne pouvez pas vous écrire à vous-même'; end if;
  if not public.is_member_of(p_conv, v_t) then raise exception 'Cette personne n''est pas dans le groupe'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Message vide'; end if;
  insert into public.messages(conversation_id, sender_id, kind, body, media_path, whisper_to)
  values (p_conv, v_me, 'text', p_body, null, v_t) returning * into v_row;
  if p_cmd_msg is not null then
    delete from public.messages where id = p_cmd_msg and sender_id = v_me and conversation_id = p_conv
       and whisper_to is null and created_at > now() - interval '2 minutes';
  end if;
  perform public.libon_log(p_conv, v_t, 'message privé', null);     -- le contenu n'est jamais journalisé
  return v_row;
end $$;
grant execute on function public.send_whisper(uuid, text, text, text, text, bigint) to authenticated;

-- ============================================================================
-- 2) Liens : groupe (9 caractères), bot (6 chiffres)
-- ============================================================================
create table if not exists public.invite_links (
  code text primary key check (code ~ '^[A-Za-z0-9]{9}$'),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  uses int not null default 0
);
create unique index if not exists invite_links_one_active on public.invite_links(conversation_id) where revoked_at is null;
alter table public.invite_links enable row level security;     -- aucune politique : accès par fonctions seulement

create or replace function public.link_group_create(p_conv uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_c public.conversations; v text; n int := 0;
begin
  if not public.is_member(p_conv) or not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'Réservé aux groupes'; end if;
  if v_c.mode <> 'clear' then raise exception 'Un groupe chiffré ne peut pas être rejoint par lien (la clé doit être transmise par un membre)'; end if;
  update public.invite_links set revoked_at = now() where conversation_id = p_conv and revoked_at is null;
  loop
    v := public.rand_str(9, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789');
    begin
      insert into public.invite_links(code, conversation_id, created_by) values (v, p_conv, auth.uid());
      exit;
    exception when unique_violation then n := n + 1; if n > 8 then raise exception 'Réessayez'; end if;
    end;
  end loop;
  perform public.libon_log(p_conv, auth.uid(), 'lien créé', null);
  return v;
end $$;

create or replace function public.link_group_get(p_conv uuid)
returns text language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_member(p_conv) or not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  return (select code from public.invite_links where conversation_id = p_conv and revoked_at is null);
end $$;

create or replace function public.link_group_revoke(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) or not public.conv_is_admin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  update public.invite_links set revoked_at = now() where conversation_id = p_conv and revoked_at is null;
  perform public.libon_log(p_conv, auth.uid(), 'lien révoqué', null);
end $$;

create or replace function public.link_group_info(p_code text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare l public.invite_links; c public.conversations;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into l from public.invite_links where code = p_code and revoked_at is null;
  if not found then raise exception 'Lien invalide ou expiré'; end if;
  select * into c from public.conversations where id = l.conversation_id;
  return jsonb_build_object('name', c.name, 'avatar_url', c.avatar_url,
    'members', (select count(*) from public.conversation_members where conversation_id = c.id),
    'member', public.is_member(c.id), 'banned', public.ban_active(c.id, auth.uid()));
end $$;

create or replace function public.link_group_join(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.invite_links; c public.conversations; v_un text := (select username from public.profiles where id = auth.uid());
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into l from public.invite_links where code = p_code and revoked_at is null;
  if not found then raise exception 'Lien invalide ou expiré'; end if;
  select * into c from public.conversations where id = l.conversation_id;
  if public.is_member(c.id) then return jsonb_build_object('conversation', c.id, 'already', true); end if;
  if public.ban_active(c.id, auth.uid()) then raise exception 'Vous êtes banni de ce groupe'; end if;
  if c.mode <> 'clear' then raise exception 'Ce groupe est chiffré'; end if;
  insert into public.conversation_members(conversation_id, user_id) values (c.id, auth.uid());
  insert into public.messages(conversation_id, sender_id, kind, body) values (c.id, auth.uid(), 'system', '@' || v_un || ' a rejoint le groupe par lien');
  update public.invite_links set uses = uses + 1 where code = p_code;
  perform public.libon_log(c.id, auth.uid(), 'ajout', 'par lien');
  return jsonb_build_object('conversation', c.id, 'already', false);
end $$;

-- lien d'ajout d'un bot : code à 6 chiffres, créé par le développeur
alter table public.bots add column if not exists share_code text;
do $$ begin
  if not exists(select 1 from pg_constraint where conname = 'bots_share_fmt') then
    alter table public.bots add constraint bots_share_fmt check (share_code is null or share_code ~ '^[0-9]{6}$');
  end if;
end $$;
create unique index if not exists bots_share_uq on public.bots(share_code) where share_code is not null;

create or replace function public.bot_link_regen(p_bot uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text; n int := 0;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  if (select official from public.bots where id = p_bot) then raise exception 'Bot officiel : déjà présent partout'; end if;
  if (select status from public.bots where id = p_bot) <> 'active' then raise exception 'Bot indisponible'; end if;
  loop
    v := public.rand_str(6, '0123456789');
    begin update public.bots set share_code = v where id = p_bot; exit;
    exception when unique_violation then n := n + 1; if n > 20 then raise exception 'Réessayez'; end if;
    end;
  end loop;
  return v;
end $$;

create or replace function public.bot_link_get(p_bot uuid)
returns text language plpgsql security definer stable set search_path = public as $$
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  return (select share_code from public.bots where id = p_bot);
end $$;

create or replace function public.bot_link_clear(p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  update public.bots set share_code = null where id = p_bot;
end $$;

-- même forme que bot_find
create or replace function public.bot_link_info(p_code text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare b public.bots;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into b from public.bots where share_code = p_code and status = 'active';
  if not found then raise exception 'Lien invalide ou expiré'; end if;
  return jsonb_build_object('id', b.id, 'name', b.name, 'username', b.username, 'prefix', b.prefix, 'description', b.description,
    'perms', b.perms, 'commands', b.commands, 'visibility', b.visibility, 'official', b.official, 'version', b.version,
    'status', b.status, 'owner', coalesce((select username from public.profiles where id = b.owner_id), b.owner_username));
end $$;

-- groupes où la personne est administratrice (pour choisir où ajouter un bot)
create or replace function public.my_admin_groups()
returns table (id uuid, name text, avatar_url text, has_bot_ids uuid[]) language sql security definer stable set search_path = public as $$
  select c.id, c.name, c.avatar_url, coalesce((select array_agg(cb.bot_id) from public.conversation_bots cb where cb.conversation_id = c.id), '{}')
    from public.conversations c join public.conversation_members m on m.conversation_id = c.id
   where m.user_id = auth.uid() and m.role = 'admin' and c.kind = 'group' order by c.name
$$;

grant execute on function public.link_group_create(uuid), public.link_group_get(uuid), public.link_group_revoke(uuid),
  public.link_group_info(text), public.link_group_join(text), public.bot_link_regen(uuid), public.bot_link_get(uuid),
  public.bot_link_clear(uuid), public.bot_link_info(text), public.my_admin_groups() to authenticated;

-- ============================================================================
-- 3) Journal immuable de chaque bot (écrit uniquement par le serveur)
-- ============================================================================
create table if not exists public.bot_logs (
  id bigint generated always as identity primary key,
  bot_id uuid not null,
  at timestamptz not null default now(),
  actor_kind text not null check (actor_kind in ('createur','api_privee','api_publique','moderateur','administrateur','ciffron','systeme')),
  actor_name text,
  action text not null,
  detail jsonb not null default '{}'::jsonb
);
create index if not exists bot_logs_bot on public.bot_logs(bot_id, id desc);
alter table public.bot_logs enable row level security;
drop policy if exists bot_logs_sel on public.bot_logs;
create policy bot_logs_sel on public.bot_logs for select to authenticated using (public.bot_is_owner(bot_id) or public.is_staff('moderator'));
grant select on public.bot_logs to authenticated;
revoke insert, update, delete, truncate on public.bot_logs from authenticated, anon, public;
drop trigger if exists bot_logs_imm on public.bot_logs;
create trigger bot_logs_imm before update or delete on public.bot_logs for each row execute function public.trg_immutable();

create or replace function public.bot_log_add(p_bot uuid, p_action text, p_detail jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_kind text; v_name text; v_set text := nullif(current_setting('cm.actor', true), '');
begin
  if v_set is not null then v_kind := v_set; v_name := nullif(current_setting('cm.actor_name', true), '');
  elsif auth.uid() is null then v_kind := 'systeme';
  else
    v_name := (select username from public.profiles where id = auth.uid());
    if public.bot_is_owner(p_bot) then v_kind := 'createur';
    elsif public.staff_role() = 'admin' then v_kind := 'administrateur';
    elsif public.is_staff('moderator') then v_kind := 'moderateur';
    else v_kind := 'systeme'; end if;
  end if;
  insert into public.bot_logs(bot_id, actor_kind, actor_name, action, detail) values (p_bot, v_kind, v_name, p_action, coalesce(p_detail, '{}'::jsonb));
end $$;
revoke all on function public.bot_log_add(uuid, text, jsonb) from public, anon, authenticated;

create or replace function public.trg_botfiles_log() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if not old.runtime then perform public.bot_log_add(old.bot_id, 'fichier supprimé', jsonb_build_object('path', old.path, 'size', old.size)); end if;
    return old;
  end if;
  if new.runtime then return new; end if;
  if tg_op = 'INSERT' then perform public.bot_log_add(new.bot_id, 'fichier ajouté', jsonb_build_object('path', new.path, 'size', new.size));
  elsif old.path <> new.path then perform public.bot_log_add(new.bot_id, 'fichier renommé', jsonb_build_object('de', old.path, 'vers', new.path));
  elsif new.content is distinct from old.content or new.data_b64 is distinct from old.data_b64 then
    perform public.bot_log_add(new.bot_id, 'fichier modifié', jsonb_build_object('path', new.path, 'size', new.size, 'avant', old.size));
  end if;
  return new;
end $$;
drop trigger if exists bot_files_log on public.bot_files;
create trigger bot_files_log after insert or update or delete on public.bot_files for each row execute function public.trg_botfiles_log();

create or replace function public.trg_bots_log() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform public.bot_log_add(new.id, 'bot créé', jsonb_build_object('nom', new.name || 'BOT', 'visibilité', new.visibility)); return new; end if;
  if new.version <> old.version then perform public.bot_log_add(new.id, 'version publiée', jsonb_build_object('version', new.version, 'notes', left(coalesce(new.notes,''), 300))); end if;
  if new.status <> old.status then perform public.bot_log_add(new.id, 'statut modifié', jsonb_build_object('de', old.status, 'vers', new.status, 'raison', new.blocked_reason)); end if;
  if new.visibility <> old.visibility then perform public.bot_log_add(new.id, 'visibilité modifiée', jsonb_build_object('de', old.visibility, 'vers', new.visibility)); end if;
  if new.perms is distinct from old.perms then perform public.bot_log_add(new.id, 'permissions modifiées', jsonb_build_object('permissions', to_jsonb(new.perms))); end if;
  if new.commands is distinct from old.commands then perform public.bot_log_add(new.id, 'commandes modifiées', jsonb_build_object('nombre', jsonb_array_length(new.commands))); end if;
  if new.access_key is distinct from old.access_key then perform public.bot_log_add(new.id, 'clé d''ajout régénérée', '{}'::jsonb); end if;
  if new.share_code is distinct from old.share_code then perform public.bot_log_add(new.id, case when new.share_code is null then 'lien d''ajout supprimé' else 'lien d''ajout créé' end, '{}'::jsonb); end if;
  return new;
end $$;
drop trigger if exists bots_log on public.bots;
create trigger bots_log after insert or update on public.bots for each row execute function public.trg_bots_log();

create or replace function public.bot_logs_list(p_bot uuid, p_limit int default 200)
returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not (public.bot_is_owner(p_bot) or public.is_staff('moderator')) then raise exception 'Accès refusé'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (select id, at, actor_kind, actor_name, action, detail from public.bot_logs
          where bot_id = p_bot order by id desc limit greatest(1, least(coalesce(p_limit,200), 1000))) x), '[]'::jsonb);
end $$;
grant execute on function public.bot_logs_list(uuid, int) to authenticated;

-- ============================================================================
-- 4) Clés API : privée CmmApI + 24 caractères, publique CmmApI + 18 caractères
-- ============================================================================
create table if not exists public.bot_api_keys (
  bot_id uuid primary key references public.bots(id) on delete cascade,
  priv_hash text, pub_hash text, priv_hint text, pub_hint text,
  created_at timestamptz not null default now(), priv_at timestamptz, pub_at timestamptz,
  blocked boolean not null default false, blocked_reason text
);
create unique index if not exists api_priv_uq on public.bot_api_keys(priv_hash) where priv_hash is not null;
create unique index if not exists api_pub_uq on public.bot_api_keys(pub_hash) where pub_hash is not null;
alter table public.bot_api_keys enable row level security;   -- aucune politique : les empreintes ne sortent jamais

create table if not exists public.api_calls (
  id bigint generated always as identity primary key,
  bot_id uuid, kind text not null, ip text, at timestamptz not null default now()
);
create index if not exists api_calls_bot_at on public.api_calls(bot_id, at desc);
create table if not exists public.api_fails (
  id bigint generated always as identity primary key, ip text, at timestamptz not null default now()
);
create index if not exists api_fails_ip_at on public.api_fails(ip, at desc);
alter table public.api_calls enable row level security;
alter table public.api_fails enable row level security;

create or replace function public.api_hash(p text) returns text language sql immutable as $$
  select encode(sha256(convert_to(p, 'UTF8')), 'hex')
$$;
revoke all on function public.api_hash(text) from public, anon, authenticated;

-- Développeur : état et régénération des clés (affichées une seule fois)
create or replace function public.bot_keys_status(p_bot uuid)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare k public.bot_api_keys;
begin
  if not public.bot_is_owner(p_bot) then raise exception 'Accès refusé'; end if;
  select * into k from public.bot_api_keys where bot_id = p_bot;
  if not found then return jsonb_build_object('priv', null, 'pub', null, 'blocked', false); end if;
  return jsonb_build_object('priv', case when k.priv_hash is null then null else 'CmmApI…' || k.priv_hint end,
    'pub', case when k.pub_hash is null then null else 'CmmApI…' || k.pub_hint end,
    'priv_at', k.priv_at, 'pub_at', k.pub_at, 'blocked', k.blocked, 'blocked_reason', k.blocked_reason);
end $$;

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
    update public.bot_api_keys set priv_hash = public.api_hash(v_priv), priv_hint = right(v_priv, 4), priv_at = now() where bot_id = p_bot;
  end if;
  if p_which in ('pub','both') then
    v_pub := 'CmmApI' || public.rand_str(18, v_a);
    update public.bot_api_keys set pub_hash = public.api_hash(v_pub), pub_hint = right(v_pub, 4), pub_at = now() where bot_id = p_bot;
  end if;
  perform public.bot_log_add(p_bot, case p_which when 'priv' then 'clé API privée régénérée' when 'pub' then 'clé API publique régénérée' else 'clés API régénérées' end, '{}'::jsonb);
  return jsonb_build_object('priv', v_priv, 'pub', v_pub);
end $$;
grant execute on function public.bot_keys_status(uuid), public.bot_keys_regen(uuid, text) to authenticated;

-- Modérateur : lève le blocage des clés (après examen)
create or replace function public.staff_api_unblock(p_bot uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff('moderator') then raise exception 'Accès refusé'; end if;
  update public.bot_api_keys set blocked = false, blocked_reason = null where bot_id = p_bot;
  perform public.bot_log_add(p_bot, 'clés API débloquées', '{}'::jsonb);
  perform public.log_admin('api_debloquer', (select name || 'BOT' from public.bots where id = p_bot), '{}'::jsonb);
end $$;
grant execute on function public.staff_api_unblock(uuid) to authenticated;

-- ---------- Analyse Ciffron côté serveur (règles portables), utilisée pour chaque push API ----------
create or replace function public.cif_scan_bot(p_bot uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f record; r record; v_lines text[]; i int; v_out jsonb := '[]'::jsonb; v_h text;
begin
  for f in select path, content from public.bot_files where bot_id = p_bot and content is not null and not runtime loop
    v_lines := string_to_array(f.content, E'\n');
    for r in select * from public.ciffron_rules where enabled and (files = '*' or lower(f.path) ~ ('\.(' || files || ')$')) loop
      for i in 1 .. least(coalesce(array_length(v_lines, 1), 0), 20000) loop
        continue when not (case when r.fl like '%i%' then v_lines[i] ~* r.pat else v_lines[i] ~ r.pat end);
        continue when exists(select 1 from public.ciffron_allow a where a.rule = r.id and (a.bot_id is null or a.bot_id = p_bot));
        v_h := public.cif_hash(f.path, v_lines[i]);
        continue when exists(select 1 from public.ciffron_protected pr where pr.bot_id = p_bot and pr.file = f.path and pr.line_hash = v_h);
        v_out := v_out || jsonb_build_object('file', f.path, 'line', i, 'text', left(v_lines[i], 300), 'rule', r.id, 'reason', r.reason, 'hash', v_h);
        if jsonb_array_length(v_out) >= 60 then return v_out; end if;
      end loop;
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function public.cif_scan_bot(uuid) from public, anon, authenticated;

-- ---------- Porte d'entrée de l'API (clé, limites de débit, blocage Ciffron) ----------
-- Renvoie {ok:true, bot, kind} ou {ok:false, error}. Écrit les compteurs même en cas de refus.
create or replace function public.api_gate(p_key text, p_need text, p_op text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ip text := public.req_ip(); k public.bot_api_keys; b public.bots; v_kind text; v_n int; v_p int; o public.dev_status;
begin
  p_key := trim(coalesce(p_key, ''));
  if v_ip is not null and (select count(*) from public.api_fails where ip = v_ip and at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('ok', false, 'error', 'Ciffron : trop de tentatives avec une clé invalide, réessayez dans quelques minutes');
  end if;
  if p_key ~ '^CmmApI[A-Za-z0-9]{24}$' then v_kind := 'priv';
  elsif p_key ~ '^CmmApI[A-Za-z0-9]{18}$' then v_kind := 'pub'; end if;
  if v_kind is not null then
    select * into k from public.bot_api_keys where (v_kind = 'priv' and priv_hash = public.api_hash(p_key)) or (v_kind = 'pub' and pub_hash = public.api_hash(p_key));
  end if;
  if v_kind is null or k.bot_id is null then
    insert into public.api_fails(ip) values (v_ip);
    delete from public.api_fails where at < now() - interval '1 day';
    return jsonb_build_object('ok', false, 'error', 'Clé invalide');
  end if;
  if p_need = 'priv' and v_kind <> 'priv' then return jsonb_build_object('ok', false, 'error', 'Cette action demande la clé privée'); end if;
  select * into b from public.bots where id = k.bot_id and status <> 'deleted';
  if not found then return jsonb_build_object('ok', false, 'error', 'Bot introuvable'); end if;
  if k.blocked then return jsonb_build_object('ok', false, 'error', 'Clés bloquées par Ciffron : un modérateur doit les débloquer'); end if;
  if b.status = 'blocked' then return jsonb_build_object('ok', false, 'error', 'Bot bloqué par Ciffron'); end if;
  select * into o from public.dev_status where user_id = b.owner_id;
  if found and o.blocked then return jsonb_build_object('ok', false, 'error', 'Mode développeur bloqué par Ciffron'); end if;
  if b.owner_id is not null and (public.ban_state(b.owner_id)->>'banned')::boolean then return jsonb_build_object('ok', false, 'error', 'Compte suspendu'); end if;
  insert into public.api_calls(bot_id, kind, ip) values (b.id, p_op, v_ip);
  delete from public.api_calls where at < now() - interval '1 day';
  select count(*), count(*) filter (where kind = 'push') into v_n, v_p from public.api_calls where bot_id = b.id and at > now() - interval '60 seconds';
  if v_n > 300 or v_p > 40 then            -- abus manifeste : blocage des clés, du bot et du mode développeur (comme une détection)
    update public.bot_api_keys set blocked = true, blocked_reason = 'Débit anormal détecté par Ciffron' where bot_id = b.id;
    insert into public.ciffron_flags(bot_id, owner_id, source, status, findings)
      values (b.id, b.owner_id, 'runtime', 'open', jsonb_build_array(jsonb_build_object('file', 'API', 'line', 0, 'text', v_n || ' requêtes / ' || v_p || ' push en 60 s', 'rule', 'api-flood', 'reason', 'Débit anormal sur les clés API')));
    perform public.cif_apply_block((select max(id) from public.ciffron_flags where bot_id = b.id), b);
    perform public.bot_log_add(b.id, 'clés API bloquées par Ciffron', jsonb_build_object('requetes', v_n, 'push', v_p));
    return jsonb_build_object('ok', false, 'error', 'Ciffron : débit anormal, clés et bot bloqués');
  end if;
  if v_n > 120 then return jsonb_build_object('ok', false, 'error', 'Ciffron : trop de requêtes (120 par minute)'); end if;
  if p_op = 'push' and v_p > 10 then return jsonb_build_object('ok', false, 'error', 'Ciffron : trop de push (10 par minute)'); end if;
  perform set_config('cm.actor', case v_kind when 'priv' then 'api_privee' else 'api_publique' end, true);
  perform set_config('cm.actor_name', 'CmmApI…' || case v_kind when 'priv' then k.priv_hint else k.pub_hint end, true);
  return jsonb_build_object('ok', true, 'bot', b.id, 'kind', v_kind);
end $$;
revoke all on function public.api_gate(text, text, text) from public, anon, authenticated;

create or replace function public.api_ping(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  g := public.api_gate(p_key, 'any', 'read');
  if not (g->>'ok')::boolean then return g; end if;
  return jsonb_build_object('ok', true, 'kind', g->>'kind', 'bot', (select name || 'BOT' from public.bots where id = (g->>'bot')::uuid));
end $$;

-- clé publique (ou privée) : informations publiques du bot, utilisables sur un site tiers
create or replace function public.api_info(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; b public.bots;
begin
  g := public.api_gate(p_key, 'any', 'read');
  if not (g->>'ok')::boolean then return g; end if;
  select * into b from public.bots where id = (g->>'bot')::uuid;
  return jsonb_build_object('ok', true, 'name', b.name || 'BOT', 'username', b.username, 'prefix', b.prefix, 'description', b.description,
    'version', b.version, 'visibility', b.visibility, 'status', b.status, 'commands', b.commands);
end $$;

create or replace function public.api_files(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  g := public.api_gate(p_key, 'priv', 'read');
  if not (g->>'ok')::boolean then return g; end if;
  return jsonb_build_object('ok', true, 'files', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'size', size, 'text', content is not null, 'updated_at', updated_at) order by path)
      from public.bot_files where bot_id = (g->>'bot')::uuid and not runtime), '[]'::jsonb));
end $$;

create or replace function public.api_get(p_key text, p_path text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; f public.bot_files;
begin
  g := public.api_gate(p_key, 'priv', 'read');
  if not (g->>'ok')::boolean then return g; end if;
  select * into f from public.bot_files where bot_id = (g->>'bot')::uuid and path = p_path and not runtime;
  if not found then return jsonb_build_object('ok', false, 'error', 'Fichier introuvable'); end if;
  return jsonb_build_object('ok', true, 'path', f.path, 'content', f.content, 'data', f.data_b64, 'size', f.size);
end $$;

-- p_files : [{path, content | data}] ; analyse Ciffron du répertoire entier après chaque push
create or replace function public.api_push(p_key text, p_files jsonb, p_message text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; v_bot uuid; e jsonb; v_size int; v_tot bigint := 0; v_n int := 0; v_find jsonb; v_fid bigint; b public.bots;
begin
  g := public.api_gate(p_key, 'priv', 'push');
  if not (g->>'ok')::boolean then return g; end if;
  v_bot := (g->>'bot')::uuid;
  begin
    if jsonb_typeof(p_files) <> 'array' or jsonb_array_length(p_files) = 0 or jsonb_array_length(p_files) > 200 then raise exception 'Lot de fichiers invalide (1 à 200 fichiers)'; end if;
    for e in select * from jsonb_array_elements(p_files) loop
      if (e->>'path') is null then raise exception 'Chemin manquant'; end if;
      if (e->>'content') is not null then v_size := octet_length(e->>'content');
      elsif (e->>'data') is not null then v_size := (length(e->>'data') * 3) / 4;
      else raise exception 'Fichier vide : %', e->>'path'; end if;
      if v_size > 12582912 then raise exception 'Fichier trop gros : %', e->>'path'; end if;
      v_tot := v_tot + v_size;
    end loop;
    if v_tot > 8388608 then raise exception 'Push trop gros (8 Mo maximum par envoi)'; end if;
    for e in select * from jsonb_array_elements(p_files) loop
      if (e->>'content') is not null then v_size := octet_length(e->>'content'); else v_size := (length(e->>'data') * 3) / 4; end if;
      insert into public.bot_files(bot_id, path, content, data_b64, size, runtime, updated_at)
      values (v_bot, e->>'path', e->>'content', case when (e->>'content') is null then e->>'data' end, v_size, false, now())
      on conflict (bot_id, path) do update set content = excluded.content, data_b64 = excluded.data_b64, size = excluded.size, updated_at = now(), runtime = false;
      v_n := v_n + 1;
    end loop;
    if (select coalesce(sum(size), 0) from public.bot_files where bot_id = v_bot) > 50331648 then raise exception 'Répertoire trop gros (48 Mo maximum)'; end if;
    update public.bots set updated_at = now() where id = v_bot;
    perform public.bot_log_add(v_bot, 'push', jsonb_build_object('fichiers', v_n, 'message', left(coalesce(p_message,''), 200)));
    v_find := public.cif_scan_bot(v_bot);
    if jsonb_array_length(v_find) > 0 then
      select * into b from public.bots where id = v_bot;
      insert into public.ciffron_flags(bot_id, owner_id, source, status, findings) values (v_bot, b.owner_id, 'static', 'open', v_find) returning id into v_fid;
      perform public.cif_apply_block(v_fid, b);
      perform public.bot_log_add(v_bot, 'push bloqué par Ciffron', jsonb_build_object('lignes', jsonb_array_length(v_find)));
      return jsonb_build_object('ok', true, 'files', v_n, 'blocked', true, 'findings', v_find);
    end if;
    return jsonb_build_object('ok', true, 'files', v_n, 'blocked', false);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function public.api_delete(p_key text, p_path text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; n int;
begin
  g := public.api_gate(p_key, 'priv', 'push');
  if not (g->>'ok')::boolean then return g; end if;
  delete from public.bot_files where bot_id = (g->>'bot')::uuid and not runtime and (path = p_path or path like p_path || '/%');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;

create or replace function public.api_publish(p_key text, p_notes text, p_perms text[] default null, p_commands jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb; v_bot uuid; b public.bots; v_ver int; r record;
begin
  g := public.api_gate(p_key, 'priv', 'push');
  if not (g->>'ok')::boolean then return g; end if;
  v_bot := (g->>'bot')::uuid;
  begin
    select * into b from public.bots where id = v_bot;
    if p_perms is not null and not public.bot_perm_ok(p_perms) then raise exception 'Permission inconnue'; end if;
    v_ver := b.version + 1;
    update public.bots set version = v_ver, notes = left(coalesce(p_notes,''), 1500), perms = coalesce(p_perms, perms),
           commands = coalesce(p_commands, commands), updated_at = now() where id = v_bot;
    for r in select conversation_id from public.conversation_bots where bot_id = v_bot loop
      update public.conversation_bots set pending = true where conversation_id = r.conversation_id and bot_id = v_bot;
      delete from public.bot_requests where conversation_id = r.conversation_id and bot_id = v_bot and resolved_at is null;
      insert into public.bot_requests(conversation_id, bot_id, kind, version, notes, perms)
      values (r.conversation_id, v_bot, 'update', v_ver, left(coalesce(p_notes,''), 1500), coalesce(p_perms, b.perms));
    end loop;
    return jsonb_build_object('ok', true, 'version', v_ver);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function public.api_logs(p_key text, p_limit int default 100)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g jsonb;
begin
  g := public.api_gate(p_key, 'priv', 'read');
  if not (g->>'ok')::boolean then return g; end if;
  return jsonb_build_object('ok', true, 'logs', coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (select id, at, actor_kind, actor_name, action, detail
      from public.bot_logs where bot_id = (g->>'bot')::uuid order by id desc limit greatest(1, least(coalesce(p_limit,100), 500))) x), '[]'::jsonb));
end $$;

grant execute on function public.api_ping(text), public.api_info(text), public.api_files(text), public.api_get(text, text),
  public.api_push(text, jsonb, text), public.api_delete(text, text), public.api_publish(text, text, text[], jsonb), public.api_logs(text, int) to anon, authenticated;
