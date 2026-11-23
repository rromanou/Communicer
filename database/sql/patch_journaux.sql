-- Communicer! — patch journaux : suppression interdite + alertes + rétention (additif)
create table if not exists public.log_alerts (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(), tbl text not null, op text not null,
  actor text not null, detail text
);
create table if not exists public.log_alert_ack (
  alert_id bigint primary key references public.log_alerts(id), by_id uuid references public.profiles(id) on delete set null,
  by_name text not null, note text not null, at timestamptz not null default now()
);
alter table public.log_alerts enable row level security;
alter table public.log_alert_ack enable row level security;
revoke all on public.log_alerts, public.log_alert_ack from anon, authenticated, public;

insert into public.tok_cfg(k, v) values ('log_keep', '50') on conflict do nothing;
create or replace function public.log_keep_n() returns int language sql stable security definer set search_path = public as $$
  select least(500, greatest(50, coalesce((select v::int from public.tok_cfg where k = 'log_keep'), 50)))
$$;

-- toute modification/suppression directe d'un journal est annulée ET consignée en alerte rouge
create or replace function public.trg_log_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then   -- purge automatique de rétention ou cascade interne
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  insert into public.log_alerts(tbl, op, actor, detail)
    values (tg_table_name, tg_op, session_user || '/' || current_user, left(coalesce(row_to_json(old)::text, ''), 500));
  return null;   -- l'opération sur cette ligne est annulée, l'alerte est conservée
end $$;
create or replace function public.trg_log_trunc() returns trigger language plpgsql as $$
begin raise exception 'Suppression de journaux interdite'; end $$;

do $$ declare t text; begin
  foreach t in array array['admin_logs','bot_logs','token_log','ciffron_exception_log'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', t || '_imm', t);
      execute format('drop trigger if exists %I on public.%I', t || '_guard', t);
      execute format('create trigger %I before update or delete on public.%I for each row execute function public.trg_log_guard()', t || '_guard', t);
      execute format('drop trigger if exists %I on public.%I', t || '_trunc', t);
      execute format('create trigger %I before truncate on public.%I for each statement execute function public.trg_log_trunc()', t || '_trunc', t);
    end if;
  end loop;
end $$;
-- le trigger existant du journal des ciffron porte un autre nom
drop trigger if exists cif_exlog_imm on public.ciffron_exception_log;

-- rétention : on garde les N dernières lignes (N = 50 par défaut, 500 au maximum)
create or replace function public.trg_log_prune() returns trigger language plpgsql security definer set search_path = public as $$
declare n int := public.log_keep_n(); cut bigint;
begin
  if tg_table_name = 'admin_logs' then
    select id into cut from public.admin_logs order by id desc offset n limit 1;
    if cut is not null then delete from public.admin_logs where id <= cut; end if;
  elsif tg_table_name = 'token_log' then
    select id into cut from public.token_log where user_id = new.user_id order by id desc offset n limit 1;
    if cut is not null then delete from public.token_log where user_id = new.user_id and id <= cut; end if;
  elsif tg_table_name = 'bot_logs' then
    select id into cut from public.bot_logs where bot_id = new.bot_id order by id desc offset n limit 1;
    if cut is not null then delete from public.bot_logs where bot_id = new.bot_id and id <= cut; end if;
  end if;
  return null;
end $$;
do $$ declare t text; begin
  foreach t in array array['admin_logs','bot_logs','token_log'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', t || '_prune', t);
      execute format('create trigger %I after insert on public.%I for each row execute function public.trg_log_prune()', t || '_prune', t);
    end if;
  end loop;
end $$;

create or replace function public.log_keep_set(p_n int) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_n is null or p_n < 50 or p_n > 500 then raise exception 'Entre 50 et 500'; end if;
  update public.tok_cfg set v = p_n::text where k = 'log_keep';
  perform public.log_admin('journaux_retention', 'log_keep', jsonb_build_object('n', p_n));
end $$;
create or replace function public.log_keep_get() returns int language sql stable security definer set search_path = public as $$
  select public.log_keep_n() where public.staff_rank_me() >= 1
$$;

-- alertes visibles par tout le personnel, inspection (accusé) par le commandant seulement
create or replace function public.log_alert_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 1 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'tbl', a.tbl, 'op', a.op, 'actor', a.actor, 'detail', a.detail,
      'ack', k.by_name, 'note', k.note, 'ack_at', k.at) order by a.id desc)
    from (select * from public.log_alerts order by id desc limit 100) a left join public.log_alert_ack k on k.alert_id = a.id), '[]'::jsonb);
end $$;
create or replace function public.log_alert_ack(p_id bigint, p_note text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Seul le commandant peut déclarer l’inspection'; end if;
  if char_length(trim(coalesce(p_note, ''))) < 10 then raise exception 'Compte rendu d’inspection obligatoire (10 caractères minimum)'; end if;
  insert into public.log_alert_ack(alert_id, by_id, by_name, note)
    values (p_id, auth.uid(), coalesce((select username from public.profiles where id = auth.uid()), '?'), trim(p_note));
  perform public.log_admin('alerte_journal_inspectee', p_id::text, jsonb_build_object('note', p_note));
end $$;
do $$ declare f text; begin foreach f in array array['log_keep_set(int)','log_keep_get()','log_alert_list()','log_alert_ack(bigint,text)'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
