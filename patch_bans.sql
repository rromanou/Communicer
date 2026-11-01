-- Communicer! — patch bannissements : temporaire / permanent (anonymisation à 60 jours) / supprimé (additif)
-- Dépend de patch_hierarchie.sql et patch_journaux.sql.
alter table public.site_bans add column if not exists kind text not null default 'temp';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'site_bans_kind_chk') then
    alter table public.site_bans add constraint site_bans_kind_chk check (kind in ('temp','perm','erase'));
  end if;
end $$;
alter table public.site_bans add column if not exists anon_at timestamptz;
update public.site_bans set kind = 'perm' where user_id is not null and until is null and kind = 'temp';

-- noms générés par le système : del[12] et user[<numéro>]
alter table public.profiles drop constraint if exists profiles_username_fmt;
alter table public.profiles add constraint profiles_username_fmt check (username ~ '^[a-z0-9_]{3,20}$' or username ~ '^(del|user)\[[0-9]{1,12}\]$');
alter table public.messages alter column sender_id drop not null;
create sequence if not exists public.anon_num_seq;

-- casier : toutes les sanctions de chaque personne (visible par l'intéressé)
create table if not exists public.casier (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('warn','sanction','ban_temp','ban_perm','ban_erase','rights','profile')),
  reason text not null, message text, by_id uuid references public.profiles(id) on delete set null, by_name text,
  at timestamptz not null default now()
);
create index if not exists casier_user on public.casier (user_id, id desc);
alter table public.casier enable row level security;
revoke all on public.casier from anon, authenticated;

-- l'anonymisation doit pouvoir purger token_log malgré la garde des journaux
create or replace function public.trg_log_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 or current_setting('app.anon_ok', true) = '1' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  insert into public.log_alerts(tbl, op, actor, detail)
    values (tg_table_name, tg_op, session_user || '/' || current_user, left(coalesce(row_to_json(old)::text, ''), 500));
  return null;
end $$;

create or replace function public._del_if(p_tbl text, p_col text, p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if to_regclass('public.' || p_tbl) is not null then execute format('delete from public.%I where %I = $1', p_tbl, p_col) using p_id; end if;
end $$;
revoke all on function public._del_if(text, text, uuid) from public, anon, authenticated;

create or replace function public._ban_anonymize(p_user uuid, p_erase boolean) returns void language plpgsql security definer set search_path = public as $$
declare n bigint; c record; nx uuid; has_edit boolean;
begin
  perform set_config('app.anon_ok', '1', true);
  n := nextval('public.anon_num_seq');
  -- messages
  if to_regclass('storage.objects') is not null then
    begin execute 'delete from storage.objects where name in (select media_path from public.messages where sender_id = $1 and media_path is not null)' using p_user; exception when others then null; end;
  end if;
  delete from public.message_hidden where message_id in (select id from public.messages where sender_id = p_user);
  delete from public.messages where whisper_to = p_user and sender_id is distinct from p_user;
  select exists(select 1 from information_schema.columns where table_schema='public' and table_name='messages' and column_name='edited_at') into has_edit;
  if p_erase then
    delete from public.messages where sender_id = p_user;
  else
    update public.messages set sender_id = null, media_path = null, whisper_to = null where sender_id = p_user;
    if has_edit then execute 'update public.messages set edited_at = null where sender_id is null and edited_at is not null'; end if;
  end if;
  -- groupes : supprimés si la personne est la créatrice et la seule administratrice, sinon droits transférés
  for c in select cv.id from public.conversations cv where cv.kind = 'group' and cv.created_by = p_user loop
    select user_id into nx from public.conversation_members where conversation_id = c.id and role = 'admin' and user_id <> p_user order by joined_at limit 1;
    if nx is null then delete from public.conversations where id = c.id;
    else update public.conversations set created_by = nx where id = c.id; end if;
  end loop;
  if p_erase then
    delete from public.conversations where kind = 'direct' and id in (select conversation_id from public.conversation_members where user_id = p_user);
    delete from public.conversation_members where user_id = p_user;
  else
    update public.conversation_members set role = 'member' where user_id = p_user and role = 'admin' and exists
      (select 1 from public.conversation_members x where x.conversation_id = conversation_members.conversation_id and x.role = 'admin' and x.user_id <> p_user);
  end if;
  -- bots
  if to_regclass('public.bots') is not null then
    update public.bots set status = 'deleted', username = left(username, 24) || '~d' || n::text, prefix = left(prefix, 8) || '~d' || n::text where owner_id = p_user and status <> 'deleted';
  end if;
  -- données personnelles
  perform public._del_if(t, 'user_id', p_user) from unnest(array['profile_ext','wallets','user_quests','user_keys','user_badges','token_log','romanomoney_saves','referral_codes','conv_pins','inventory','equipped','badge_requests','quest_events','quest_claims','daily_claims','daily_state']) t;
  delete from public.friendships where requester = p_user or addressee = p_user;
  update public.profiles set username = (case when p_erase then 'del[' else 'del[' end) || n::text || ']', nickname = null, avatar_url = null, public_key = null,
    last_seen = 'epoch', created_at = 'epoch', bio = null, purity = null, purity_at = null where id = p_user;
  update public.site_bans set anon_at = now() where user_id = p_user and anon_at is null;
  perform public.log_admin(case when p_erase then 'ban_supprime_execute' else 'ban_anonymisation' end, 'del[' || n::text || ']', jsonb_build_object('erase', p_erase));
end $$;
revoke all on function public._ban_anonymize(uuid, boolean) from public, anon, authenticated;

create or replace function public.ban_issue(p_username text, p_kind text, p_secs numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid; me int := public.staff_rank_me(); tr int; nm text; bid bigint;
begin
  if me < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if p_kind not in ('temp','perm','erase') then raise exception 'Type de bannissement invalide'; end if;
  if p_kind = 'erase' and me < 3 then raise exception 'Seul le chef des administrateurs peut prononcer un ban supprimé'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  select id, username into v, nm from public.profiles where username = lower(regexp_replace(trim(p_username), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  if v = auth.uid() then raise exception 'Vous ne pouvez pas vous bannir'; end if;
  tr := public.staff_rank_of(v);
  if tr >= 4 then raise exception 'Le commandant ne peut pas être banni'; end if;
  if tr >= me then raise exception 'Vous ne pouvez pas bannir un rang égal ou supérieur au vôtre'; end if;
  if p_kind = 'temp' and (p_secs is null or p_secs <= 0 or p_secs > 31536000) then raise exception 'Durée invalide (jusqu’à un an)'; end if;
  insert into public.site_bans(user_id, until, reason, by_id, kind)
    values (v, case when p_kind = 'temp' then now() + make_interval(secs => p_secs::double precision) end, left(p_reason, 300), auth.uid(), p_kind) returning id into bid;
  insert into public.casier(user_id, kind, reason, by_id, by_name)
    values (v, 'ban_' || p_kind, left(p_reason, 300), auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('ban_' || p_kind, nm, jsonb_build_object('secs', p_secs, 'reason', p_reason, 'ban', bid));
  if p_kind = 'erase' then perform public._ban_anonymize(v, true); end if;
end $$;

-- anonymisation des bans permanents après 60 jours (appelée au démarrage ; au plus une fois par 10 minutes)
create or replace function public.ban_sweep() returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; last timestamptz;
begin
  if auth.uid() is null then return 0; end if;
  select v::timestamptz into last from public.tok_cfg where k = 'ban_sweep_at';
  if last is not null and last > now() - interval '10 minutes' then return 0; end if;
  insert into public.tok_cfg(k, v) values ('ban_sweep_at', now()::text) on conflict (k) do update set v = excluded.v;
  for r in select distinct user_id from public.site_bans where kind = 'perm' and user_id is not null and lifted_at is null and anon_at is null and created_at < now() - interval '60 days' loop
    perform public._ban_anonymize(r.user_id, false); n := n + 1;
  end loop;
  return n;
end $$;

-- utilisateurs actuellement sanctionnés (profil masqué, badge « Sanctionné »)
create or replace function public.banned_ids() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(distinct user_id), '[]'::jsonb) from public.site_bans
   where user_id is not null and lifted_at is null and (until is null or until > now()) and anon_at is null
$$;

-- un compte banni ne peut plus rien envoyer, quel que soit le client (y compris Lite)
create or replace function public.trg_msg_ban_gate() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sender_id is not null and new.kind <> 'system' and (public.ban_state(new.sender_id) ->> 'banned')::boolean then
    raise exception 'Compte suspendu';
  end if;
  return new;
end $$;
drop trigger if exists msg_ban_gate on public.messages;
create trigger msg_ban_gate before insert on public.messages for each row execute function public.trg_msg_ban_gate();

-- casier consultable par la personne
create or replace function public.casier_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'reason', reason, 'message', message, 'by', by_name, 'at', at) order by id desc), '[]'::jsonb)
  from public.casier where user_id = auth.uid()
$$;
do $$ declare f text; begin foreach f in array array['ban_issue(text,text,numeric,text)','ban_sweep()','banned_ids()','casier_mine()'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
