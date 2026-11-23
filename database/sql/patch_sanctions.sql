-- Communicer! — patch sanctions : avertissements, sanctions, modération de profil (additif). Dépend de patch_bans.sql.
alter table public.casier add column if not exists consumed boolean not null default false;
alter table public.casier add column if not exists seen_at timestamptz;
create sequence if not exists public.user_num_seq;

create or replace function public._target(p_username text, out uid uuid, out uname text) language plpgsql security definer set search_path = public as $$
declare me int := public.staff_rank_me(); tr int;
begin
  if me < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id, username into uid, uname from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if uid is null then raise exception 'Utilisateur introuvable'; end if;
  if uid = auth.uid() then raise exception 'Action impossible sur soi-même'; end if;
  tr := public.staff_rank_of(uid);
  if tr >= me then raise exception 'Vous ne pouvez pas agir sur un rang égal ou supérieur au vôtre'; end if;
end $$;
revoke all on function public._target(text) from public, anon, authenticated;

create or replace function public.warn_issue(p_username text, p_reason text, p_message text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t record; n int; me text := (select username from public.profiles where id = auth.uid()); banned boolean := false;
begin
  select * into t from public._target(p_username);
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  insert into public.casier(user_id, kind, reason, message, by_id, by_name) values (t.uid, 'warn', left(p_reason, 300), left(nullif(trim(coalesce(p_message,'')), ''), 1000), auth.uid(), me);
  select count(*) into n from public.casier where user_id = t.uid and kind = 'warn' and not consumed;
  if n >= 3 then
    update public.casier set consumed = true where user_id = t.uid and kind = 'warn' and not consumed;
    insert into public.site_bans(user_id, until, reason, by_id, kind) values (t.uid, now() + interval '3 days', 'Trois avertissements', auth.uid(), 'temp');
    insert into public.casier(user_id, kind, reason, by_id, by_name) values (t.uid, 'ban_temp', 'Trois avertissements : bannissement de 3 jours', auth.uid(), me);
    banned := true;
  end if;
  perform public.log_admin('avertissement', t.uname, jsonb_build_object('reason', p_reason, 'n', n, 'ban', banned));
  return jsonb_build_object('count', n, 'banned', banned);
end $$;

create or replace function public.sanction_issue(p_username text, p_reason text, p_message text) returns void
language plpgsql security definer set search_path = public as $$
declare t record;
begin
  select * into t from public._target(p_username);
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  if char_length(trim(coalesce(p_message,''))) < 3 then raise exception 'Message à joindre obligatoire'; end if;
  insert into public.casier(user_id, kind, reason, message, by_id, by_name) values (t.uid, 'sanction', left(p_reason, 300), left(p_message, 1000), auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('sanction', t.uname, jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.profile_mod(p_username text, p_action text, p_reason text, p_credit boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare t record; nm text;
begin
  select * into t from public._target(p_username);
  if char_length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Raison obligatoire'; end if;
  if p_action = 'photo' then update public.profiles set avatar_url = null where id = t.uid;
  elsif p_action = 'nickname' then update public.profiles set nickname = null where id = t.uid;
  elsif p_action = 'bio' then update public.profiles set bio = null where id = t.uid;
  elsif p_action = 'bg' then update public.profile_ext set profile_bg = null where user_id = t.uid;
  elsif p_action = 'username' then
    nm := 'user[' || nextval('public.user_num_seq')::text || ']';
    update public.profiles set username = nm where id = t.uid;
    if p_credit then insert into public.profile_ext(user_id, rename_credits) values (t.uid, 1) on conflict (user_id) do update set rename_credits = public.profile_ext.rename_credits + 1; end if;
  else raise exception 'Action inconnue'; end if;
  insert into public.casier(user_id, kind, reason, message, by_id, by_name) values (t.uid, 'profile', left(p_reason, 300),
    case p_action when 'photo' then 'Photo de profil retirée' when 'nickname' then 'Surnom retiré' when 'bio' then 'Description retirée' when 'bg' then 'Fond de profil retiré'
      else 'Nom d’utilisateur remplacé' || case when p_credit then ' (un renommage gratuit vous est accordé)' else '' end end,
    auth.uid(), (select username from public.profiles where id = auth.uid()));
  perform public.log_admin('profil_modere', t.uname, jsonb_build_object('action', p_action, 'reason', p_reason, 'credit', p_credit));
end $$;

create or replace function public.casier_of(p_username text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'reason', reason, 'message', message, 'by', by_name, 'at', at, 'consumed', consumed) order by id desc) from public.casier where user_id = v), '[]'::jsonb);
end $$;

-- la personne voit les nouveautés de son casier dès sa connexion
create or replace function public.casier_unseen() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'reason', reason, 'message', message, 'by', by_name, 'at', at) order by id), '[]'::jsonb)
  from public.casier where user_id = auth.uid() and seen_at is null and kind in ('warn','sanction','profile')
$$;
create or replace function public.casier_mark_seen() returns void language sql security definer set search_path = public as $$
  update public.casier set seen_at = now() where user_id = auth.uid() and seen_at is null
$$;
do $$ declare f text; begin foreach f in array array['warn_issue(text,text,text)','sanction_issue(text,text,text)','profile_mod(text,text,text,boolean)','casier_of(text)','casier_unseen()','casier_mark_seen()'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
