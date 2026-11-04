-- ============================================================================
-- Communicer! — Patch « correctifs 2 » (additif, relançable)
-- 1) Audit : fin de la boucle infinie (stack depth), interrupteur du commandant, notifications limitées
-- 2) Échange Romanomoney : anciennes versions de l'extension
-- 3) Décor de profil : opacité réglable (1 à 90 %)
-- À exécuter APRÈS patch_audit.sql et patch_customize.sql. Si l'éditeur SQL est bloqué par l'erreur « stack depth limit exceeded »,
-- lancez d'abord uniquement le bloc « 1) Audit » : il lève le blocage.
-- ============================================================================

-- ---------- 1) Audit ----------
create table if not exists public.audit_cfg (k text primary key, v text not null);
alter table public.audit_cfg enable row level security; revoke all on public.audit_cfg from anon, authenticated;
insert into public.audit_cfg(k, v) values ('enabled', '1') on conflict (k) do nothing;

create or replace function public.trg_audit() returns trigger language plpgsql security definer set search_path = public as $$
declare kd text := case when public._is_journal(tg_table_name) then 'journal' else 'data' end; pkc jsonb; r record; fid bigint; recent boolean;
begin
  -- garde-fous : pas de récursion (les notifications écrivent dans messages / conversation_seq), table de config exclue, interrupteur
  if tg_table_name in ('audit_flags', 'audit_cfg', 'conversation_seq') or pg_trigger_depth() > 1
     or coalesce(current_setting('app.audit_skip', true), '') = '1' then return coalesce(new, old); end if;
  if coalesce((select c.v from public.audit_cfg c where c.k = 'enabled'), '1') <> '1' then return coalesce(new, old); end if;
  if session_user in ('authenticator', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_realtime_admin', 'pgbouncer') then return coalesce(new, old); end if;
  perform set_config('app.audit_skip', '1', true);
  pkc := to_jsonb(old);
  select exists(select 1 from public.audit_flags where tbl = tg_table_name and at > now() - interval '10 minutes') into recent;
  insert into public.audit_flags(tbl, op, kind, pk, old_row, new_row, db_user)
  values (tg_table_name, tg_op, kd, case when pkc ? 'id' then jsonb_build_object('id', pkc->'id') when pkc ? 'user_id' then jsonb_build_object('user_id', pkc->'user_id') else null end,
          to_jsonb(old), case when tg_op = 'UPDATE' then to_jsonb(new) end, session_user) returning id into fid;
  if not recent then   -- une seule alerte par table toutes les 10 minutes (importations en masse)
    for r in select user_id from public.site_staff where role = 'commander' loop
      begin
        perform public.sys_notify(r.user_id, 'Modification hors application signalée sur « ' || tg_table_name || ' » (' || tg_op || ', n° ' || fid || '). Administration > Contrôle.');
      exception when others then null;
      end;
    end loop;
  end if;
  perform set_config('app.audit_skip', '', true);
  return coalesce(new, old);
end $$;
revoke all on function public.trg_audit() from public, anon, authenticated;

-- le commandant active ou désactive la surveillance (depuis Administration > Contrôle)
create or replace function public.audit_cfg_get() returns boolean language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select c.v from public.audit_cfg c where c.k = 'enabled'), '1') = '1';
end $$;
create or replace function public.audit_cfg_set(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  insert into public.audit_cfg(k, v) values ('enabled', case when p_on then '1' else '0' end) on conflict (k) do update set v = excluded.v;
  perform public.log_admin(case when p_on then 'audit_active' else 'audit_desactive' end, 'audit', '{}'::jsonb);
end $$;
revoke all on function public.audit_cfg_get(), public.audit_cfg_set(boolean) from public, anon;
grant execute on function public.audit_cfg_get(), public.audit_cfg_set(boolean) to authenticated;
-- coupure d'urgence sans passer par le site : update public.audit_cfg set v = '0' where k = 'enabled';
select public.audit_install();

-- ---------- 2) Échange Romanomoney : anciennes versions de l'extension ----------
alter table public.xchg add column if not exists legacy boolean not null default false;
create or replace function public.xchg_begin_legacy(p_units int) returns text language plpgsql security definer set search_path = public as $$
declare nonce text := public.rand_code(24); cap int := public.cfg_n('xchg_month_cap')::int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_units is null or p_units < 1 or p_units > 100 then raise exception 'Quantité invalide'; end if;
  perform public.rate_ok('xchg', 30, 3600);
  if coalesce((select ext or site from public.panel_flags where user_id = auth.uid()), false) then raise exception 'Échange refusé : le panneau administrateur de Romanomoney a déjà été ouvert'; end if;
  if public.xchg_month_used(auth.uid()) + p_units > cap then raise exception 'Limite mensuelle : % échanges par mois', cap; end if;
  insert into public.xchg(user_id, src, units, nonce, legacy) values (auth.uid(), 'ext', p_units, nonce, true);
  return nonce;
end $$;
-- total des tranches déjà retirées pour une ancienne extension (le site les soustrait à chaque synchronisation)
create or replace function public.xchg_legacy_total() returns int language sql security definer stable set search_path = public as $$
  select coalesce(sum(units), 0)::int from public.xchg where user_id = auth.uid() and legacy and status = 'done' $$;
revoke all on function public.xchg_begin_legacy(int), public.xchg_legacy_total() from public, anon;
grant execute on function public.xchg_begin_legacy(int), public.xchg_legacy_total() to authenticated;

-- ---------- 3) Décor de profil : opacité ----------
alter table public.profile_ext add column if not exists backdrop_op int not null default 60 check (backdrop_op between 1 and 90);
create or replace function public.custom_set(p_field text, p_value text) returns void language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_value,'')), ''); arr text[]; k text; allowed text[] := array['bio','age','anniv','ville','travail','etudes','jeu','citation','site','pronoms'];
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.has_cplus() then raise exception 'Réservé à Customize+'; end if;
  perform public.rate_ok('cplus', 120, 3600);
  insert into public.profile_ext(user_id) values (auth.uid()) on conflict do nothing;
  if p_field = 'site_color' then
    if v is not null and v !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
    update public.profile_ext set site_color = v where user_id = auth.uid();
  elsif p_field = 'music_btn' then
    if v is not null and v !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
    update public.profile_ext set music_btn = v where user_id = auth.uid();
  elsif p_field = 'bg_music' then
    if v is not null and v !~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$' then raise exception 'Lien https invalide'; end if;
    update public.profile_ext set bg_music = v where user_id = auth.uid();
  elsif p_field = 'backdrop' then
    if v is not null and v !~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$' then raise exception 'Lien https invalide'; end if;
    update public.profile_ext set backdrop = v where user_id = auth.uid();
  elsif p_field = 'backdrop_op' then
    if v is null or v !~ '^[0-9]{1,2}$' or v::int < 1 or v::int > 90 then raise exception 'Opacité entre 1 et 90 %'; end if;
    update public.profile_ext set backdrop_op = v::int where user_id = auth.uid();
  elsif p_field = 'music_vol' then
    if v is null or v !~ '^(0|1|0?\.[0-9]{1,2})$' then raise exception 'Volume invalide'; end if;
    update public.profile_ext set music_vol = v::numeric where user_id = auth.uid();
  elsif p_field = 'layout' then
    arr := coalesce(string_to_array(coalesce(v,''), ','), '{}');
    if exists(select 1 from unnest(arr) x where x not in ('bio','info','extra','stats','badges')) or cardinality(arr) <> (select count(distinct x) from unnest(arr) x) then raise exception 'Ordre invalide'; end if;
    update public.profile_ext set layout = arr where user_id = auth.uid();
  elsif p_field like 'x:%' then
    k := split_part(p_field, ':', 2);
    if not (k = any(allowed)) then raise exception 'Champ inconnu'; end if;
    if split_part(p_field, ':', 3) = 'show' then
      update public.profile_ext set extra = jsonb_set(extra, array[k], coalesce(extra -> k, '{}'::jsonb) || jsonb_build_object('show', v = '1')) where user_id = auth.uid();
    else
      if v is not null and char_length(v) > 120 then raise exception '120 caractères au maximum'; end if;
      if v is null then update public.profile_ext set extra = extra - k where user_id = auth.uid();
      else update public.profile_ext set extra = jsonb_set(extra, array[k], coalesce(extra -> k, '{"show":false}'::jsonb) || jsonb_build_object('v', v)) where user_id = auth.uid(); end if;
    end if;
  else raise exception 'Réglage inconnu'; end if;
end $$;

create or replace function public.custom_me() returns jsonb language sql security definer stable set search_path = public as $$
  select case when public.has_cplus() then (select jsonb_build_object('on', true, 'site_color', e.site_color, 'bg_music', e.bg_music, 'music_vol', e.music_vol, 'music_btn', e.music_btn, 'backdrop', e.backdrop, 'backdrop_op', e.backdrop_op,
      'layout', to_jsonb(e.layout), 'extra', e.extra, 'last_rename', e.last_rename) from public.profile_ext e where e.user_id = auth.uid())
    else jsonb_build_object('on', false) end
$$;

create or replace function public.profile_full(p_username text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare u uuid; e public.profile_ext; shown jsonb := '[]'::jsonb; c text; ex jsonb := '{}'::jsonb; k text; cp boolean;
begin
  select id into u from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if u is null then return '{}'::jsonb; end if;
  select * into e from public.profile_ext where user_id = u;
  if exists(select 1 from public.user_badges where user_id = u and code = 'moderateur') then shown := shown || jsonb_build_array(public.badge_json(u, 'moderateur')); end if;
  foreach c in array coalesce(e.badges, '{}') loop
    if c <> 'moderateur' and exists(select 1 from public.user_badges where user_id = u and code = c) then shown := shown || jsonb_build_array(public.badge_json(u, c)); end if;
  end loop;
  cp := exists(select 1 from public.inventory where user_id = u and code = 'customize_plus');
  if cp then for k in select jsonb_object_keys(coalesce(e.extra, '{}'::jsonb)) loop
      if coalesce((e.extra -> k ->> 'show')::boolean, false) then ex := ex || jsonb_build_object(k, e.extra -> k ->> 'v'); end if;
  end loop; end if;
  return jsonb_build_object('nc', e.name_color, 'pc', e.profile_color, 'ptc', e.profile_text_color, 'bg', e.profile_bg, 'pf', e.photo_frame, 'rf', e.profile_frame, 'badges', shown,
    'cp', cp, 'music', case when cp then e.bg_music end, 'vol', e.music_vol, 'mbtn', case when cp then e.music_btn end, 'backdrop', case when cp then e.backdrop end, 'backdrop_op', e.backdrop_op,
    'layout', case when cp then to_jsonb(e.layout) else '[]'::jsonb end, 'extra', ex);
end $$;

notify pgrst, 'reload schema';
