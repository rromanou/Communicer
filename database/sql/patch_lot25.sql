-- Lot 25 : corrections et extensions du panneau, sécurité des tournois/sondages — additif
-- Le panneau est un outil de divertissement et d'animation : il ne sert jamais à nuire.

-- ---------- 1) tournois : seul l'organisateur ; sondages : seul l'auteur ----------
create or replace function public._ev_boss(p_tid bigint) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.tournaments where id = p_tid and creator = auth.uid()) $$;
create or replace function public.t_delete(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.tournaments where id = p_id and creator = auth.uid()) then raise exception 'Réservé à l’organisateur'; end if;
  delete from public.tournaments where id = p_id;
end $$;
create or replace function public.gi_set(p_id bigint, p_data jsonb default null, p_closed boolean default null) returns void language plpgsql security definer set search_path = public as $$
declare i public.group_items;
begin
  select * into i from public.group_items where id = p_id;
  if not found then raise exception 'Élément introuvable'; end if;
  if i.kind = 'task' and i.conv is not null and public._is_member(i.conv) then null;   -- les tâches se cochent par tout membre
  elsif i.created_by is distinct from auth.uid() then raise exception 'Réservé à l’auteur'; end if;
  update public.group_items set data = case when p_data is null then data else data || p_data end, closed = coalesce(p_closed, closed) where id = p_id;
end $$;
create or replace function public.gi_del(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare i public.group_items;
begin
  select * into i from public.group_items where id = p_id;
  if not found then raise exception 'Élément introuvable'; end if;
  if i.created_by is distinct from auth.uid() and not (i.conv is not null and public._is_cadmin(i.conv)) then raise exception 'Réservé à l’auteur ou aux administrateurs du groupe'; end if;
  delete from public.group_items where id = p_id;
end $$;

-- ---------- 2) console du serveur : bonnes colonnes ----------
create or replace function public.panel_console(p_n int default 40) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare n int := least(greatest(coalesce(p_n, 40), 5), 200);
begin
  perform public._panel_need(2);
  return jsonb_build_object(
    'admin', coalesce((select jsonb_agg(x) from (select created_at as at, staff_name, action, target from public.admin_logs order by id desc limit n) x), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(x) from (select at, tbl, op from public.log_alerts order by id desc limit n) x), '[]'::jsonb),
    'panel', coalesce((select jsonb_agg(x) from (select l.at, p.username, l.action from public.panel_log l left join public.profiles p on p.id = l.user_id order by l.id desc limit n) x), '[]'::jsonb));
end $$;

-- ---------- 3) premier NIP : le commandant peut le créer (avant, impossible : il fallait déjà être dans le panneau) ----------
create or replace function public.panel_pin(p_pin text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u public.panel_users; c public.panel_cfg; okp boolean;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into u from public.panel_users where user_id = auth.uid() for update;
  if not found or u.seq_at is null or u.seq_at < now() - interval '5 minutes' then return jsonb_build_object('ok', false, 'left', null, 'why', 'seq'); end if;
  if u.banned then return jsonb_build_object('ok', false, 'banned', true); end if;
  select * into c from public.panel_cfg where id = 1;
  if c.pin_hash is null then
    -- aucun NIP défini : seul le commandant peut en fixer un en le tapant ici
    if public.staff_rank_of(auth.uid()) >= 4 and p_pin ~ '^[A-Za-z]{8}$' then
      update public.panel_cfg set pin_hash = extensions.crypt(lower(p_pin), extensions.gen_salt('bf')), updated_at = now(), updated_by = auth.uid() where id = 1;
      okp := true;
    else
      return jsonb_build_object('ok', false, 'left', 3, 'why', 'nopin');
    end if;
  else
    okp := p_pin ~ '^[A-Za-z]{8}$' and c.pin_hash = extensions.crypt(lower(p_pin), c.pin_hash);
  end if;
  if okp then
    update public.panel_users set unlocked = true, unlocked_at = coalesce(unlocked_at, now()), pin_fail = 0, seq_at = null, revoked = false, seen = now() where user_id = auth.uid();
    perform public._panel_log('unlock', '{}'::jsonb);
    return jsonb_build_object('ok', true);
  end if;
  update public.panel_users set pin_fail = pin_fail + 1, seq_at = null,
      banned = (pin_fail + 1 >= 3 and public.staff_rank_of(auth.uid()) < 4) where user_id = auth.uid() returning * into u;
  perform public._panel_log('pin_fail', jsonb_build_object('n', u.pin_fail));
  return jsonb_build_object('ok', false, 'left', greatest(3 - u.pin_fail, 0), 'banned', u.banned);
end $$;

-- ---------- 4) présence dans le panneau (visible du commandant) ----------
alter table public.panel_users add column if not exists seen timestamptz;
create or replace function public.panel_ping() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public._panel_ok(auth.uid()) then return; end if;
  update public.panel_users set seen = now() where user_id = auth.uid();
end $$;
create or replace function public.panel_active() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('username', p.username, 'rank', public.staff_rank_of(u.user_id), 'secs', extract(epoch from now() - u.seen)::int) order by u.seen desc)
    from public.panel_users u join public.profiles p on p.id = u.user_id where u.seen > now() - interval '90 seconds'), '[]'::jsonb);
end $$;

-- ---------- 5) invisibilité par discussion ----------
create table if not exists public.panel_vanish_conv (user_id uuid not null references public.profiles(id) on delete cascade, conv uuid not null references public.conversations(id) on delete cascade, primary key (user_id, conv));
alter table public.panel_vanish_conv enable row level security; revoke all on public.panel_vanish_conv from anon, authenticated;
drop function if exists public.panel_vanish(boolean);
create or replace function public.panel_vanish(p_on boolean, p_conv uuid default null) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  if p_conv is null then
    update public.panel_users set vanish = coalesce(p_on, false) where user_id = auth.uid();
  elsif coalesce(p_on, false) then
    if not public.is_member(p_conv) then raise exception 'Vous n’êtes pas dans cette discussion'; end if;
    insert into public.panel_vanish_conv(user_id, conv) values (auth.uid(), p_conv) on conflict do nothing;
  else
    delete from public.panel_vanish_conv where user_id = auth.uid() and conv = p_conv;
  end if;
  perform public._panel_log('vanish', jsonb_build_object('on', p_on, 'conv', p_conv));
end $$;
-- liste des invisibles visibles pour la personne qui demande : seulement ceux de ses discussions
create or replace function public.panel_vanished() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'conv', x.conv)) from (
    select u.user_id as id, null::uuid as conv from public.panel_users u where u.vanish and u.user_id <> auth.uid() and public._panel_ok(u.user_id)
    union all
    select v.user_id, v.conv from public.panel_vanish_conv v where v.user_id <> auth.uid() and public.is_member(v.conv)) x), '[]'::jsonb)
$$;

-- ---------- 6) gérer un groupe : retirer, bannir, lever le ban, droits sur les bots ----------
create or replace function public._panel_target(p_username text) returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  if v <> auth.uid() and public.staff_rank_of(v) >= public.staff_rank_me() and public.staff_rank_me() < 4 then raise exception 'Rang insuffisant pour agir sur cette personne'; end if;
  return v;
end $$;
revoke all on function public._panel_target(text) from public, anon, authenticated;

create or replace function public.panel_remove(p_conv uuid, p_username text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(2); v := public._panel_target(p_username);
  if not exists(select 1 from public.conversations where id = p_conv and kind = 'group') then raise exception 'Seulement dans un groupe'; end if;
  delete from public.conversation_members where conversation_id = p_conv and user_id = v;
  if not found then raise exception 'Cette personne n’est pas dans le groupe'; end if;
  insert into public.messages(conversation_id, sender_id, kind, body) values (p_conv, auth.uid(), 'system', '@' || lower(regexp_replace(trim(p_username), '^@', '')) || ' a été retiré du groupe');
  perform public._panel_log('remove', jsonb_build_object('conv', p_conv, 'cible', p_username));
end $$;
create or replace function public.panel_cban(p_conv uuid, p_username text, p_secs numeric default 0) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(2); v := public._panel_target(p_username);
  update public.conversation_bans set lifted_at = now() where conversation_id = p_conv and user_id = v and lifted_at is null;
  insert into public.conversation_bans(conversation_id, user_id, by_id, seconds, until) values (p_conv, v, auth.uid(), greatest(coalesce(p_secs,0),0), case when coalesce(p_secs,0) > 0 then now() + make_interval(secs => p_secs::double precision) end);
  delete from public.conversation_members where conversation_id = p_conv and user_id = v and exists(select 1 from public.conversations where id = p_conv and kind = 'group');
  insert into public.messages(conversation_id, sender_id, kind, body) values (p_conv, auth.uid(), 'system', '@' || lower(regexp_replace(trim(p_username), '^@', '')) || ' a été banni');
  perform public._panel_log('cban', jsonb_build_object('conv', p_conv, 'cible', p_username, 'secs', p_secs));
end $$;
create or replace function public.panel_cunban(p_conv uuid, p_username text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(2); v := public._panel_target(p_username);
  update public.conversation_bans set lifted_at = now() where conversation_id = p_conv and user_id = v and lifted_at is null;
  perform public._panel_log('cunban', jsonb_build_object('conv', p_conv, 'cible', p_username));
end $$;
-- droit d'utiliser les commandes des bots, accordé à un citoyen par le panneau
create or replace function public.panel_right(p_conv uuid, p_username text, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(2); v := public._panel_target(p_username);
  if not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = v) then raise exception 'Cette personne n’est pas dans la discussion'; end if;
  if coalesce(p_on, false) then insert into public.conversation_rights(conversation_id, user_id, granted_by) values (p_conv, v, auth.uid()) on conflict do nothing;
  else delete from public.conversation_rights where conversation_id = p_conv and user_id = v; end if;
  perform public._panel_log('right', jsonb_build_object('conv', p_conv, 'cible', p_username, 'on', p_on));
end $$;

-- ---------- 7) écrire à la place de quelqu'un (étiquette discrète) ----------
alter table public.messages add column if not exists via text;
create table if not exists public.speak_volunteers (user_id uuid primary key references public.profiles(id) on delete cascade, at timestamptz not null default now());
alter table public.speak_volunteers enable row level security; revoke all on public.speak_volunteers from anon, authenticated;
create or replace function public.speak_vol_set(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if coalesce(p_on, false) then insert into public.speak_volunteers(user_id) values (auth.uid()) on conflict do nothing; else delete from public.speak_volunteers where user_id = auth.uid(); end if;
end $$;
create or replace function public.speak_vol_me() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.speak_volunteers where user_id = auth.uid()) $$;
-- panneau : n'importe quel profil (étiquette A) ; sans panneau : seulement les volontaires (étiquette V). Motif obligatoire, journalisé.
create or replace function public.speak_as(p_conv uuid, p_username text, p_text text, p_reason text) returns bigint language plpgsql security definer set search_path = public as $$
declare v uuid; m text; mid bigint; via text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 10 then raise exception 'Indiquez un motif justifié (10 caractères minimum)'; end if;
  if char_length(trim(coalesce(p_text,''))) not between 1 and 2000 then raise exception 'Message de 1 à 2000 caractères'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
  select mode into m from public.conversations where id = p_conv; if m is null then raise exception 'Discussion introuvable'; end if;
  if m = 'e2e' then raise exception 'Discussion chiffrée : impossible d’écrire à la place de quelqu’un'; end if;
  if not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = v) then raise exception 'Cette personne n’est pas dans la discussion'; end if;
  if public.staff_rank_of(v) >= public.staff_rank_me() and public.staff_rank_me() < 4 then raise exception 'Rang insuffisant'; end if;
  if public._panel_ok(auth.uid()) then via := 'A';
  elsif exists(select 1 from public.speak_volunteers where user_id = v) then via := 'V';
  else raise exception 'Cette personne ne s’est pas portée volontaire'; end if;
  perform public.rate_ok('speak_as', 20, 3600);
  insert into public.messages(conversation_id, sender_id, kind, body, via) values (p_conv, v, 'text', trim(p_text), via) returning messages.id into mid;
  insert into public.panel_log(user_id, action, detail) values (auth.uid(), 'speak_as', jsonb_build_object('conv', p_conv, 'cible', p_username, 'via', via, 'motif', left(p_reason, 200)));
  return mid;
end $$;

-- ---------- 8) un hôte vérifie qu'un joueur a le droit de voir les mains (panneau débloqué) ----------
create or replace function public.panel_peek_ok(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public._panel_ok(p_user) $$;

do $$ declare f text; begin
  foreach f in array array['panel_ping()','panel_active()','panel_vanish(boolean,uuid)','panel_vanished()','panel_remove(uuid,text)','panel_cban(uuid,text,numeric)','panel_cunban(uuid,text)','panel_right(uuid,text,boolean)','speak_vol_set(boolean)','speak_vol_me()','speak_as(uuid,text,text,text)','panel_peek_ok(uuid)','panel_console(int)','panel_pin(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';
