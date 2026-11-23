-- ============================================================================
-- Communicer! — Patch « audit » (additif, relançable)
-- Toute modification ou suppression de ligne faite hors de l'application (éditeur SQL, accès direct à la base)
-- sur n'importe quelle table du schéma public est signalée au commandant.
-- Journaux : le commandant peut seulement inspecter. Autres tables : accepter, ou inspecter puis refuser (la ligne est rétablie).
-- ============================================================================
create table if not exists public.audit_flags (
  id bigint generated always as identity primary key,
  tbl text not null, op text not null check (op in ('UPDATE','DELETE')), kind text not null check (kind in ('journal','data')),
  pk jsonb, old_row jsonb, new_row jsonb, db_user text not null, at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','accepted','refused')),
  decided_by uuid references public.profiles(id) on delete set null, decided_at timestamptz, note text
);
create index if not exists audit_flags_status on public.audit_flags (status, id desc);
alter table public.audit_flags enable row level security; revoke all on public.audit_flags from anon, authenticated;

create or replace function public._is_journal(t text) returns boolean language sql immutable as $$
  select t ~ '(^|_)logs?$' or t in ('casier','token_log','admin_logs','staff_week_log','mail_log','bot_logs','staff_activity','audit_flags')
$$;

-- séance de l'application (API Supabase, fonctions) : session_user = authenticator ; tout autre accès est « hors application »
create or replace function public.trg_audit() returns trigger language plpgsql security definer set search_path = public as $$
declare k text := case when public._is_journal(tg_table_name) then 'journal' else 'data' end; pkc jsonb; r record; fid bigint;
begin
  if tg_table_name = 'audit_flags' or coalesce(current_setting('app.audit_skip', true), '') = '1' then return coalesce(new, old); end if;
  if session_user in ('authenticator', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_realtime_admin', 'pgbouncer') then return coalesce(new, old); end if;
  pkc := to_jsonb(old);
  insert into public.audit_flags(tbl, op, kind, pk, old_row, new_row, db_user)
  values (tg_table_name, tg_op, k, case when pkc ? 'id' then jsonb_build_object('id', pkc->'id') when pkc ? 'user_id' then jsonb_build_object('user_id', pkc->'user_id') else null end,
          to_jsonb(old), case when tg_op = 'UPDATE' then to_jsonb(new) end, session_user) returning id into fid;
  for r in select user_id from public.site_staff where role = 'commander' loop
    perform public.sys_notify(r.user_id, 'Modification hors application signalée sur « ' || tg_table_name || ' » (' || tg_op || ', n° ' || fid || '). Administration > Contrôle.');
  end loop;
  return coalesce(new, old);
end $$;
revoke all on function public.trg_audit() from public, anon, authenticated;

create or replace function public.audit_install() returns int language plpgsql security definer set search_path = public as $$
declare t record; n int := 0;
begin
  for t in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r' and c.relname <> 'audit_flags' loop
    execute format('drop trigger if exists zz_audit on public.%I', t.relname);
    execute format('create trigger zz_audit after update or delete on public.%I for each row execute function public.trg_audit()', t.relname);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.audit_install() from public, anon, authenticated;
select public.audit_install();

-- nouvelles tables : même surveillance (si les triggers d'événement sont permis)
do $$ begin
  create or replace function public.trg_audit_ddl() returns event_trigger language plpgsql security definer set search_path = public as $f$
  begin perform public.audit_install(); end $f$;
  drop event trigger if exists audit_ddl;
  create event trigger audit_ddl on ddl_command_end when tag in ('CREATE TABLE', 'CREATE TABLE AS') execute function public.trg_audit_ddl();
exception when others then raise notice 'trigger d’événement non installé : % (relancer select public.audit_install(); après chaque nouvelle table)', sqlerrm;
end $$;

create or replace function public.audit_list(p_status text default 'pending') returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'tbl', f.tbl, 'op', f.op, 'kind', f.kind, 'db_user', f.db_user, 'at', f.at, 'status', f.status, 'note', f.note) order by f.id desc)
    from (select * from public.audit_flags where (p_status = 'all' or status = p_status) order by id desc limit 200) f), '[]'::jsonb);
end $$;
create or replace function public.audit_view(p_id bigint) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare f public.audit_flags;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select * into f from public.audit_flags where id = p_id;
  if not found then raise exception 'Signalement introuvable'; end if;
  return jsonb_build_object('id', f.id, 'tbl', f.tbl, 'op', f.op, 'kind', f.kind, 'before', f.old_row, 'after', f.new_row, 'db_user', f.db_user, 'at', f.at, 'status', f.status);
end $$;

-- journaux : inspection seulement. Autres tables : accepter, ou refuser (rétablit la ligne d'origine)
create or replace function public.audit_decide(p_id bigint, p_accept boolean, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare f public.audit_flags; pkcol text; pkval text;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select * into f from public.audit_flags where id = p_id for update;
  if not found or f.status <> 'pending' then raise exception 'Signalement introuvable ou déjà traité'; end if;
  if f.kind = 'journal' then raise exception 'Les modifications de journaux ne peuvent qu’être inspectées'; end if;
  if not p_accept then
    if char_length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Indiquez la raison du refus'; end if;
    perform set_config('app.audit_skip', '1', true);
    if f.op = 'DELETE' then
      execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I, $1) on conflict do nothing', f.tbl, f.tbl) using f.old_row;
    else
      select key into pkcol from jsonb_each(f.pk) limit 1;
      if pkcol is null then raise exception 'Cette ligne n’a pas d’identifiant simple : rétablissement impossible, corrigez-la à la main'; end if;
      pkval := f.old_row ->> pkcol;
      execute format('update public.%I t set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1) r) where t.%I::text = $2',
        f.tbl,
        (select string_agg(quote_ident(key), ', ') from jsonb_object_keys(f.old_row) key),
        (select string_agg('r.' || quote_ident(key), ', ') from jsonb_object_keys(f.old_row) key),
        f.tbl, pkcol) using f.old_row, pkval;
    end if;
    perform set_config('app.audit_skip', '', true);
  end if;
  update public.audit_flags set status = case when p_accept then 'accepted' else 'refused' end, decided_by = auth.uid(), decided_at = now(), note = left(p_note, 300) where id = p_id;
  perform public.log_admin(case when p_accept then 'audit_accepte' else 'audit_refuse' end, f.tbl, jsonb_build_object('numero', p_id));
end $$;
revoke all on function public.audit_list(text), public.audit_view(bigint), public.audit_decide(bigint, boolean, text) from public, anon;
grant execute on function public.audit_list(text), public.audit_view(bigint), public.audit_decide(bigint, boolean, text) to authenticated;

-- les tâches planifiées (pg_cron) font partie de l'application : elles ne sont pas signalées
do $$ begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$update cron.job set command = 'select set_config(''app.audit_skip'', ''1'', true); ' || command where command not like 'select set_config(''app.audit_skip''%'$q$;
  end if;
exception when others then raise notice 'tâches planifiées non modifiées : %', sqlerrm;
end $$;
