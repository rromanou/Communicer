-- Lot 26 : Communicer Pass et Pass+ — additif, relançable
-- Tous les avantages du Pass ne valent QUE pendant que l'abonnement est actif. Le paiement (Stripe) viendra plus tard ;
-- en attendant, le commandant et les chefs des administrateurs peuvent accorder le Pass ou le Pass+ pour des jours, des mois ou des années.

create table if not exists public.pass_subs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  pass_until timestamptz, plus_until timestamptz, updated_at timestamptz not null default now());
create table if not exists public.pass_grants (id bigint generated always as identity primary key, user_id uuid not null, kind text not null, amount int, unit text, by_id uuid, at timestamptz not null default now(), note text);
create table if not exists public.pass_month (user_id uuid not null references public.profiles(id) on delete cascade, ym text not null, at timestamptz not null default now(), primary key (user_id, ym));
create table if not exists public.pass_spend (user_id uuid not null references public.profiles(id) on delete cascade, ym text not null, spent numeric(14,1) not null default 0, primary key (user_id, ym));
alter table public.pass_subs enable row level security; alter table public.pass_grants enable row level security; alter table public.pass_month enable row level security; alter table public.pass_spend enable row level security;
revoke all on public.pass_subs, public.pass_grants, public.pass_month, public.pass_spend from anon, authenticated;

create or replace function public._pass_on(p_user uuid default auth.uid()) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select pass_until > now() from public.pass_subs where user_id = p_user), false) $$;
create or replace function public._plus_on(p_user uuid default auth.uid()) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select plus_until > now() from public.pass_subs where user_id = p_user), false) $$;
create or replace function public._plus_codes() returns text[] language sql immutable as $$ select array['tournaments','vaze_pp','esport','krypto_plus','credits_name'] $$;
revoke all on function public._pass_on(uuid), public._plus_on(uuid), public._plus_codes() from public, anon, authenticated;

-- badge « Pass »
insert into public.badge_defs(code, name, descr, tier, price, sort) values ('pass', 'Communicer Pass', 'Abonné Communicer Pass', 'special', null, 90) on conflict (code) do nothing;

-- objets accordés par le Pass (via = 'pass') : retirés dès que le Pass n'est plus actif ; un achat antérieur reste
create or replace function public._pass_sync(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if p_user is null then return; end if;
  if public._pass_on(p_user) then
    foreach c in array array['lite','pin'] loop
      insert into public.inventory(user_id, code, via) select p_user, c, 'pass' where exists(select 1 from public.shop_items where code = c) on conflict do nothing;
    end loop;
    perform public.badge_grant(p_user, 'pass');
  else
    delete from public.inventory where user_id = p_user and via = 'pass';
    delete from public.user_badges where user_id = p_user and code = 'pass';
  end if;
end $$;
revoke all on function public._pass_sync(uuid) from public, anon, authenticated;
create or replace function public.pass_sweep() returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  for u in select distinct user_id from (select user_id from public.inventory where via = 'pass' union select user_id from public.user_badges where code = 'pass') x loop
    if not public._pass_on(u) then perform public._pass_sync(u); end if;
  end loop;
end $$;
revoke all on function public.pass_sweep() from public, anon, authenticated;
do $$ begin begin perform cron.schedule('communicer-pass-sweep', '7 * * * *', 'select public.pass_sweep()'); exception when others then raise notice 'pg_cron : %', sqlerrm; end; end $$;

create or replace function public._owns(p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code and (via is distinct from 'pass' or public._pass_on())) $$;
create or replace function public.has_item(p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code and (via is distinct from 'pass' or public._pass_on())) $$;

-- état affiché à la personne
create or replace function public.pass_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.pass_subs; v_ym text := to_char(now(), 'YYYYMM'); sp numeric := 0;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public._pass_sync(auth.uid());
  select * into s from public.pass_subs where user_id = auth.uid();
  select coalesce(spent, 0) into sp from public.pass_spend where user_id = auth.uid() and pass_spend.ym = v_ym;
  sp := coalesce(sp, 0);
  return jsonb_build_object('pass', public._pass_on(), 'until', s.pass_until, 'plus', public._plus_on(), 'plus_until', s.plus_until,
    'price', 6.99, 'storage', 2.99, 'total', 9.98, 'tokens', 1500, 'discount', 5, 'plus_discount', 20, 'plus_cap', 65000, 'plus_spent', sp,
    'claimed', exists(select 1 from public.pass_month where user_id = auth.uid() and pass_month.ym = v_ym),
    'msg_limit', case when public._pass_on() then 200 else 100 end,
    'plus_codes', to_jsonb(public._plus_codes()),
    'rate_med', (select (v)::numeric from public.tok_cfg where k = 'poppy_rate'));
end $$;

-- identifiants des abonnés actifs (pour le symbole à côté du surnom)
create or replace function public.pass_active_ids(p_ids uuid[]) returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then '[]'::jsonb else coalesce((select jsonb_agg(user_id) from public.pass_subs where user_id = any(p_ids) and pass_until > now()), '[]'::jsonb) end $$;

-- 1500 jetons par mois, seulement pendant que le Pass est actif
create or replace function public.pass_claim_month() returns numeric language plpgsql security definer set search_path = public as $$
declare v_ym text := to_char(now(), 'YYYYMM'); b numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public._pass_on() then raise exception 'Le Pass n’est pas actif'; end if;
  insert into public.pass_month(user_id, ym) values (auth.uid(), v_ym) on conflict do nothing;
  if not found then raise exception 'Les jetons de ce mois sont déjà réclamés'; end if;
  b := public.tok_add(auth.uid(), 1500, 'Communicer Pass : jetons du mois', null);
  return b;
end $$;

-- accorder / retirer (commandant et chefs des administrateurs)
create or replace function public.pass_grant(p_username text, p_kind text, p_amount int, p_unit text) returns timestamptz language plpgsql security definer set search_path = public as $$
declare v uuid; iv interval; t timestamptz;
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au commandant et aux chefs des administrateurs'; end if;
  if p_kind not in ('pass','plus') then raise exception 'Type invalide'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000 then raise exception 'Durée invalide'; end if;
  iv := case p_unit when 'day' then make_interval(days => p_amount) when 'month' then make_interval(months => p_amount) when 'year' then make_interval(years => p_amount) else null end;
  if iv is null then raise exception 'Unité invalide (jour, mois, an)'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
  insert into public.pass_subs(user_id) values (v) on conflict do nothing;
  if p_kind = 'pass' then update public.pass_subs set pass_until = greatest(coalesce(pass_until, now()), now()) + iv, updated_at = now() where user_id = v returning pass_until into t;
  else update public.pass_subs set plus_until = greatest(coalesce(plus_until, now()), now()) + iv, updated_at = now() where user_id = v returning plus_until into t; end if;
  insert into public.pass_grants(user_id, kind, amount, unit, by_id) values (v, p_kind, p_amount, p_unit, auth.uid());
  perform public._pass_sync(v);
  perform public.log_admin('pass_grant', p_username, jsonb_build_object('kind', p_kind, 'n', p_amount, 'unit', p_unit));
  return t;
end $$;
create or replace function public.pass_revoke(p_username text, p_kind text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 3 then raise exception 'Réservé au commandant et aux chefs des administrateurs'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); if v is null then raise exception 'Utilisateur introuvable'; end if;
  if p_kind = 'pass' then update public.pass_subs set pass_until = now() - interval '1 second' where user_id = v;
  elsif p_kind = 'plus' then update public.pass_subs set plus_until = now() - interval '1 second' where user_id = v;
  else raise exception 'Type invalide'; end if;
  perform public._pass_sync(v);
  perform public.log_admin('pass_revoke', p_username, jsonb_build_object('kind', p_kind));
end $$;

-- jetons vers coquelicots : 40 % plus cher que coquelicots vers jetons (taux synchronisé avec poppy_rate)
create or replace function public.pass_tok_to_med(p_med int) returns jsonb language plpgsql security definer set search_path = public as $$
declare rate numeric; cost numeric; b numeric; w public.wallets;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public._pass_on() then raise exception 'Réservé aux abonnés Communicer Pass actifs'; end if;
  if p_med is null or p_med < 1 or p_med > 1000 then raise exception 'Quantité invalide (1 à 1 000)'; end if;
  perform public.rate_ok('tok2med', 20, 3600);
  select (v)::numeric into rate from public.tok_cfg where k = 'poppy_rate';
  cost := ceil(p_med * rate * 1.4 * 10) / 10;
  select * into w from public.wallets where user_id = auth.uid() for update;
  if not found or w.balance < cost then raise exception 'Jetons insuffisants (% jetons requis)', cost; end if;
  b := public.tok_add(auth.uid(), -cost, 'échange de jetons contre ' || p_med || ' coquelicots', null);
  update public.wallets set medals = medals + p_med where user_id = auth.uid();
  return jsonb_build_object('cost', cost, 'balance', b, 'medals', w.medals + p_med);
end $$;
create or replace function public.pass_casino_bonus() returns numeric language sql stable security definer set search_path = public as $$ select case when public._pass_on() then 0.02 else 0 end $$;

-- protection des données des comptes Pass actifs
create or replace function public._purge_guard(p_tbl text) returns text language plpgsql stable security definer set search_path = public as $$
declare c text;
begin
  select column_name into c from information_schema.columns where table_schema = 'public' and table_name = p_tbl
    and column_name in ('user_id','sender_id','owner_id','creator','created_by','requester','author_id') order by array_position(array['user_id','sender_id','owner_id','creator','created_by','requester','author_id'], column_name::text) limit 1;
  if c is null then return 'true'; end if;
  return format('(%I is null or %I not in (select user_id from public.pass_subs where pass_until > now()))', c, c);
end $$;
revoke all on function public._purge_guard(text) from public, anon, authenticated;
create or replace function public._purge_inactive(p_months int) returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p
   where coalesce(p.last_seen, p.created_at) < now() - make_interval(months => p_months)
     and not exists(select 1 from public.site_staff s where s.user_id = p.id)
     and not exists(select 1 from public.pass_subs a where a.user_id = p.id and a.pass_until > now())
     and p.id not in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002')
$$;
revoke all on function public._purge_inactive(int) from public, anon, authenticated;

-- recopies avec protection du Pass
create or replace function public._purge_count(p_kind text, p_item text, p_mode text, p_n int, p_months int) returns bigint language plpgsql security definer set search_path = public as $$
declare c record; tc text; w text := 'true'; n bigint;
begin
  select * into c from public._purge_cat() where kind = p_kind and item = p_item;
  if not found or to_regclass('public.' || c.tbl) is null then return -1; end if;
  if c.extra is not null then w := '(' || c.extra || ')'; end if;
  w := w || ' and ' || public._purge_guard(c.tbl);   -- les comptes Pass actifs sont protégés
  if p_kind = 'g' then
    if p_mode = 'all' then execute format('select count(*) from public.%I where %s', c.tbl, w) into n;
    elsif p_mode = 'oldest' then execute format('select least(count(*), %s) from public.%I where %s', greatest(p_n, 0), c.tbl, w) into n;
    elsif p_mode = 'age' then
      tc := public._purge_tcol(c.tbl); if tc is null or p_months is null then return -1; end if;
      execute format('select count(*) from public.%I where %s and %I < now() - make_interval(months => %s)', c.tbl, w, tc, p_months) into n;
    else return -1; end if;
  else
    if p_months is null then return -1; end if;
    execute format('select count(*) from public.%I where %s and (%I in (select public._purge_inactive(%s))%s)', c.tbl, w, c.col, p_months,
      case when c.col2 is null then '' else format(' or %I in (select public._purge_inactive(%s))', c.col2, p_months) end) into n;
  end if;
  return n;
end $$;
create or replace function public._purge_do(p_kind text, p_item text, p_mode text, p_n int, p_months int) returns bigint language plpgsql security definer set search_path = public as $$
declare c record; tc text; w text := 'true'; n bigint;
begin
  perform set_config('communicer.purge', public._purge_pass(), true);   -- autorise la suppression de journaux par ce chemin uniquement
  perform set_config('app.audit_skip', '1', true);                       -- ne pas signaler cette suppression légitime
  select * into c from public._purge_cat() where kind = p_kind and item = p_item;
  if not found or to_regclass('public.' || c.tbl) is null then raise exception 'Élément inconnu'; end if;
  if c.extra is not null then w := '(' || c.extra || ')'; end if;
  w := w || ' and ' || public._purge_guard(c.tbl);   -- les comptes Pass actifs sont protégés
  if p_kind = 'g' then
    if p_mode = 'all' then
      if c.extra is null and not exists(select 1 from pg_constraint where contype = 'f' and confrelid = ('public.' || c.tbl)::regclass) then
        execute format('select count(*) from public.%I', c.tbl) into n;
        execute format('truncate table public.%I', c.tbl);          -- libère réellement l'espace disque
        return n;
      end if;
      return public._purge_del(('public.' || c.tbl)::regclass, w);
    elsif p_mode = 'oldest' then
      tc := public._purge_tcol(c.tbl); if tc is null then raise exception 'Aucune colonne de date : utilisez « tout »'; end if;
      return public._purge_del(('public.' || c.tbl)::regclass, format('ctid in (select ctid from public.%I where %s order by %I asc limit %s)', c.tbl, w, tc, p_n));
    else
      tc := public._purge_tcol(c.tbl); if tc is null or p_months is null then raise exception 'Durée invalide'; end if;
      return public._purge_del(('public.' || c.tbl)::regclass, format('%s and %I < now() - make_interval(months => %s)', w, tc, p_months));
    end if;
  else
    if p_months is null then raise exception 'Durée invalide'; end if;
    return public._purge_del(('public.' || c.tbl)::regclass, format('%s and (%I in (select public._purge_inactive(%s))%s)', w, c.col, p_months,
      case when c.col2 is null then '' else format(' or %I in (select public._purge_inactive(%s))', c.col2, p_months) end));
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
create or replace function public.group_font_add(p_conv uuid, p_name text, p_b64 text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not public._pass_on() then raise exception 'Les polices personnalisées demandent un abonnement Communicer Pass actif'; end if;
  if not public.has_cmd_right(p_conv) then raise exception 'Vous n''avez pas le droit d''utiliser les commandes de LibonBOT'; end if;
  if (select count(*) from public.group_fonts where conversation_id = p_conv) >= 10 then raise exception 'Maximum 10 polices par groupe'; end if;
  -- signature TrueType (00 01 00 00) ou OpenType (OTTO)
  if left(p_b64, 6) not in ('AAEAAA', 'T1RUTw') then raise exception 'Ce fichier n''est pas une police .ttf ou .otf'; end if;
  insert into public.group_fonts(conversation_id, name, data_b64, created_by) values (p_conv, trim(p_name), p_b64, auth.uid())
  on conflict (conversation_id, name) do update set data_b64 = excluded.data_b64, created_by = auth.uid(), created_at = now();
  perform public.libon_log(p_conv, auth.uid(), 'police ajoutée', left(trim(p_name), 30));
end $$;

create or replace function public.inventory_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.profile_ext;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public._pass_sync(auth.uid());
  select * into e from public.profile_ext where user_id = auth.uid();
  return jsonb_build_object('ext', coalesce(to_jsonb(e) - 'user_id', '{}'::jsonb),
    'items', coalesce((select jsonb_agg(code) from public.inventory where user_id = auth.uid() and (via is distinct from 'pass' or public._pass_on())), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(public.badge_json(auth.uid(), code) order by (select sort from public.badge_defs where code = u.code)) from public.user_badges u where user_id = auth.uid()), '[]'::jsonb),
    'pass', public._pass_on(), 'plus', public._plus_on(),
    'slots', case when public.staff_rank_me() >= 4 then 1000 else 4 + case when exists(select 1 from public.inventory where user_id = auth.uid() and code = 'badge_slot5') then 1 else 0 end end);
end $$;


-- achats : rabais Pass (5 %), Pass+ (20 % jusqu'à 65 000 jetons par mois), articles réservés au Pass+
create or replace function public.shop_buy(p_code text)
returns numeric language plpgsql security definer set search_path = public as $$
declare it public.shop_items; bd public.badge_defs; b numeric; price numeric; base numeric; part numeric := 0; nm text; gated boolean := false; sp numeric := 0;
  pon boolean := public._pass_on(); xon boolean := public._plus_on(); v_ym text := to_char(now(), 'YYYYMM');
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('buy', 60, 3600);
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select balance into b from public.wallets where user_id = auth.uid() for update;
  select * into it from public.shop_items where code = p_code;
  if found then
    if it.price is null then raise exception 'Cet article ne s’achète pas'; end if;
    if it.kind <> 'credit' and exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code and (via is distinct from 'pass' or pon)) then raise exception 'Déjà possédé'; end if;
    base := it.price; nm := it.name; gated := p_code = any(public._plus_codes());
  else
    select * into bd from public.badge_defs where code = p_code;
    if not found or bd.price is null then raise exception 'Article introuvable'; end if;
    if exists(select 1 from public.user_badges where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
    base := bd.price; nm := 'badge ' || bd.name;
  end if;
  if gated and not xon then raise exception 'Cet article demande un abonnement Communicer Pass+ actif'; end if;
  price := base;
  if not gated then
    if xon then
      select coalesce(spent, 0) into sp from public.pass_spend where user_id = auth.uid() and pass_spend.ym = v_ym;
      sp := coalesce(sp, 0);
      part := least(base, greatest(65000 - sp, 0));
      price := round(part * 0.80 + (base - part) * case when pon then 0.95 else 1 end, 1);
    elsif pon then price := round(base * 0.95, 1); end if;
  end if;
  if b < price then raise exception 'Jetons insuffisants'; end if;
  if it.code is not null then
    if it.kind = 'credit' then
      insert into public.profile_ext(user_id, rename_credits) values (auth.uid(), 1) on conflict (user_id) do update set rename_credits = public.profile_ext.rename_credits + 1;
    else
      delete from public.inventory where user_id = auth.uid() and code = p_code and via = 'pass';
      insert into public.inventory(user_id, code) values (auth.uid(), p_code);
    end if;
  else perform public.badge_grant(auth.uid(), p_code, null); end if;
  if part > 0 then insert into public.pass_spend(user_id, ym, spent) values (auth.uid(), v_ym, part) on conflict (user_id, ym) do update set spent = public.pass_spend.spent + part; end if;
  return public.tok_add(auth.uid(), -price, 'achat : ' || nm);
end $$;

-- liste de la boutique : prix affichés avec les rabais, articles Pass+
create or replace function public.shop_list()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'descr', s.descr, 'price', s.price, 'kind', s.kind,
       'owned', s.kind <> 'credit' and exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code and (i.via is distinct from 'pass' or public._pass_on())),
       'via', exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code and i.via is not null and (i.via is distinct from 'pass' or public._pass_on())),
       'plus_only', s.code = any(public._plus_codes()),
       'price_now', case when s.price is null then null when s.code = any(public._plus_codes()) then s.price
                         when public._plus_on() then round(s.price * 0.8, 1) when public._pass_on() then round(s.price * 0.95, 1) else s.price end) order by s.sort) from public.shop_items s), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier, 'price', d.price,
       'owned', exists(select 1 from public.user_badges b where b.user_id = auth.uid() and b.code = d.code)) order by d.sort) from public.badge_defs d where d.price is not null), '[]'::jsonb),
    'frames', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'name', name) order by cat, sort) from public.frame_defs), '[]'::jsonb),
    'pack', jsonb_build_object('cad', public.cfg_n('pack_price_cad'), 'tokens', public.cfg_n('pack_tokens')))
$$;

do $$ declare f text; begin
  foreach f in array array['pass_state()','pass_active_ids(uuid[])','pass_claim_month()','pass_grant(text,text,int,text)','pass_revoke(text,text)','pass_tok_to_med(int)','pass_casino_bonus()','shop_buy(text)','shop_list()','inventory_me()','group_font_add(uuid,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
notify pgrst, 'reload schema';
