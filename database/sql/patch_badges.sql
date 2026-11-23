-- ============================================================================
-- Communicer! — Patch « badges créés par le commandant » + correctif VlafiBOT (additif, relançable)
-- À exécuter après patch_customize.sql / patch_correctifs2.sql.
-- ============================================================================

-- ---------- correctif VlafiBOT : un retour à la ligne réel coupait une chaîne (main.cmm, « chaîne non fermée ») ----------
update public.bot_files set content = replace(content, 'joue le nom le plus proche' || chr(10) || 'vl/speed', 'joue le nom le plus proche\nvl/speed')
 where path = 'main.cmm' and bot_id = (select id from public.bots where username = 'vlafibot') and position('joue le nom le plus proche' || chr(10) || 'vl/speed' in content) > 0;

-- ---------- badges personnalisés ----------
alter table public.badge_defs add column if not exists custom boolean not null default false;
alter table public.badge_defs add column if not exists created_by uuid references public.profiles(id) on delete set null;
alter table public.badge_defs add column if not exists color text;
alter table public.badge_defs add column if not exists glyph text;
alter table public.badge_defs add column if not exists cond jsonb not null default '[]'::jsonb;
alter table public.badge_defs add column if not exists auto boolean not null default false;
alter table public.badge_defs add column if not exists available boolean not null default true;
alter table public.badge_defs add column if not exists avail_from timestamptz;
alter table public.badge_defs add column if not exists avail_until timestamptz;
create sequence if not exists public.badge_custom_seq;

create table if not exists public.login_days (user_id uuid not null references public.profiles(id) on delete cascade, day date not null, primary key (user_id, day));
alter table public.login_days enable row level security;

create or replace function public._badge_open(p_code text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select d.available and (d.avail_from is null or now() >= d.avail_from) and (d.avail_until is null or now() < d.avail_until) from public.badge_defs d where d.code = p_code), true) $$;
revoke all on function public._badge_open(text) from public, anon, authenticated;

-- un badge indisponible ne peut plus être obtenu (achat ou condition) ; seuls les modérateurs peuvent encore le remettre à la main
create or replace function public.badge_grant(p_user uuid, p_code text, p_by uuid default null, p_extra jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare k int;
begin
  if exists(select 1 from public.user_badges where user_id = p_user and code = p_code) then return false; end if;
  if p_by is null and not public._badge_open(p_code) then raise exception 'Ce badge n’est plus disponible'; end if;
  insert into public.badge_counters as bc(code, n) values (p_code, 1) on conflict (code) do update set n = bc.n + 1 returning bc.n into k;
  insert into public.user_badges(user_id, code, seq, given_by, extra) values (p_user, p_code, k, p_by, coalesce(p_extra, '{}'::jsonb));
  return true;
end $$;
revoke all on function public.badge_grant(uuid, text, uuid, jsonb) from public, anon, authenticated;

create or replace function public.badge_json(p_user uuid, p_code text)
returns jsonb language sql security definer stable set search_path = public as $$
  select jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier, 'seq', u.seq, 'at', u.at,
    'by', case when d.tier = 'special' or d.code = 'grand_mecene' then (select username from public.profiles where id = u.given_by) end,
    'extra', u.extra, 'color', d.color, 'glyph', d.glyph)
  from public.user_badges u join public.badge_defs d on d.code = u.code where u.user_id = p_user and u.code = p_code
$$;
revoke all on function public.badge_json(uuid, text) from public, anon, authenticated;

create or replace function public.shop_list()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'descr', s.descr, 'price', s.price, 'kind', s.kind,
       'owned', s.kind <> 'credit' and exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code),
       'via', exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code and i.via is not null)) order by s.sort) from public.shop_items s), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier, 'price', d.price, 'color', d.color, 'glyph', d.glyph,
       'owned', exists(select 1 from public.user_badges b where b.user_id = auth.uid() and b.code = d.code)) order by d.sort) from public.badge_defs d where d.price is not null and public._badge_open(d.code)), '[]'::jsonb),
    'frames', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'name', name) order by cat, sort) from public.frame_defs), '[]'::jsonb),
    'pack', jsonb_build_object('cad', public.cfg_n('pack_price_cad'), 'tokens', public.cfg_n('pack_tokens')))
$$;

-- ---------- connexions (pour les conditions « connecté tel jour ») ----------
create or replace function public.login_note() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.login_days(user_id, day) values (auth.uid(), public.staff_today()) on conflict do nothing;
end $$;

-- ---------- évaluation des conditions ----------
create or replace function public._badge_cond_ok(p_user uuid, c jsonb) returns boolean language plpgsql security definer stable set search_path = public as $$
declare k text := c->>'k'; n int := coalesce((c->>'n')::int, 0); v int;
begin
  if k = 'login' then return exists(select 1 from public.login_days where user_id = p_user and day between (c->>'from')::date and (c->>'until')::date);
  elsif k = 'login_days' then select count(*) into v from public.login_days where user_id = p_user; return v >= n;
  elsif k = 'joined_before' then return coalesce((select created_at::date < (c->>'until')::date from public.profiles where id = p_user), false);
  elsif k = 'msgs' then select count(*) into v from public.messages where sender_id = p_user and kind <> 'system'; return v >= n;
  elsif k = 'friends' then select count(*) into v from public.friendships where status = 'accepted' and (requester = p_user or addressee = p_user); return v >= n;
  elsif k = 'wins' then select count(*) into v from public.game_wins where user_id = p_user; return v >= n;
  elsif k = 'quests' then select count(*) into v from public.user_quests where user_id = p_user and claimed; return v >= n;
  elsif k = 'buy' then return exists(select 1 from public.inventory where user_id = p_user and code = c->>'item') or exists(select 1 from public.user_badges where user_id = p_user and code = c->>'item');
  end if;
  return false;
exception when others then return false;
end $$;
revoke all on function public._badge_cond_ok(uuid, jsonb) from public, anon, authenticated;

create or replace function public._badge_eval(p_user uuid, p_code text) returns boolean language plpgsql security definer stable set search_path = public as $$
declare d public.badge_defs; c jsonb;
begin
  select * into d from public.badge_defs where code = p_code;
  if not found or not d.auto or jsonb_array_length(d.cond) = 0 then return false; end if;
  for c in select * from jsonb_array_elements(d.cond) loop
    if not public._badge_cond_ok(p_user, c) then return false; end if;
  end loop;
  return true;
end $$;
revoke all on function public._badge_eval(uuid, text) from public, anon, authenticated;

create or replace function public.badge_custom_sync_me() returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if auth.uid() is null then return 0; end if;
  perform public.rate_ok('bsync', 40, 3600);
  for r in select code from public.badge_defs where custom and auto and public._badge_open(code)
           and not exists(select 1 from public.user_badges b where b.user_id = auth.uid() and b.code = badge_defs.code) loop
    if public._badge_eval(auth.uid(), r.code) then
      if public.badge_grant(auth.uid(), r.code, null) then n := n + 1; perform public.sys_notify(auth.uid(), 'Nouveau badge obtenu : « ' || (select name from public.badge_defs where code = r.code) || ' ».'); end if;
    end if;
  end loop;
  return n;
end $$;

-- ---------- gestion par le commandant ----------
create or replace function public.badge_def_save(p_code text, p_name text, p_descr text, p_color text, p_glyph text, p_price numeric, p_cond jsonb, p_auto boolean,
  p_available boolean, p_from timestamptz, p_until timestamptz) returns text language plpgsql security definer set search_path = public as $$
declare cd text := p_code; c jsonb; nm text := btrim(coalesce(p_name,'')); ks text[] := array['login','login_days','joined_before','msgs','friends','wins','quests','buy'];
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if char_length(nm) not between 2 and 30 then raise exception 'Nom de 2 à 30 caractères'; end if;
  if char_length(btrim(coalesce(p_descr,''))) not between 3 and 200 then raise exception 'Description de 3 à 200 caractères'; end if;
  if p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
  if p_glyph is null or p_glyph !~ '^[a-z_]{2,12}$' then raise exception 'Symbole invalide'; end if;
  if p_price is not null and (p_price < 1 or p_price > 10000000) then raise exception 'Prix entre 1 et 10 000 000 jetons'; end if;
  if p_cond is null or jsonb_typeof(p_cond) <> 'array' or jsonb_array_length(p_cond) > 8 then raise exception 'Conditions invalides (8 au maximum)'; end if;
  if p_until is not null and p_from is not null and p_until <= p_from then raise exception 'La fin doit suivre le début'; end if;
  for c in select * from jsonb_array_elements(p_cond) loop
    if jsonb_typeof(c) <> 'object' or not (c->>'k' = any(ks)) then raise exception 'Condition inconnue'; end if;
    if c->>'k' = 'login' then
      perform (c->>'from')::date, (c->>'until')::date;
      if (c->>'until')::date < (c->>'from')::date then raise exception 'Période de connexion invalide'; end if;
    elsif c->>'k' = 'joined_before' then perform (c->>'until')::date;
    elsif c->>'k' = 'buy' then
      if not exists(select 1 from public.shop_items where code = c->>'item') and not exists(select 1 from public.badge_defs where code = c->>'item') then raise exception 'Article de la condition « achat » introuvable'; end if;
    elsif coalesce((c->>'n')::int, 0) not between 1 and 10000000 then raise exception 'Nombre invalide dans une condition'; end if;
  end loop;
  if cd is null then
    cd := 'cb' || nextval('public.badge_custom_seq');
    insert into public.badge_defs(code, name, descr, tier, price, sort, custom, created_by, color, glyph, cond, auto, available, avail_from, avail_until)
    values (cd, nm, btrim(p_descr), 'special', p_price, 500 + currval('public.badge_custom_seq')::int, true, auth.uid(), p_color, p_glyph, p_cond, coalesce(p_auto, false), coalesce(p_available, true), p_from, p_until);
  else
    update public.badge_defs set name = nm, descr = btrim(p_descr), price = p_price, color = p_color, glyph = p_glyph, cond = p_cond, auto = coalesce(p_auto, false),
      available = coalesce(p_available, true), avail_from = p_from, avail_until = p_until where code = cd and custom;
    if not found then raise exception 'Badge introuvable'; end if;
  end if;
  perform public.log_admin('badge_cree', nm, jsonb_build_object('code', cd, 'auto', p_auto, 'disponible', p_available));
  return cd;
end $$;

create or replace function public.badge_def_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'color', d.color, 'glyph', d.glyph, 'price', d.price, 'cond', d.cond, 'auto', d.auto,
    'available', d.available, 'from', d.avail_from, 'until', d.avail_until, 'open', public._badge_open(d.code), 'owners', (select count(*) from public.user_badges b where b.code = d.code)) order by d.sort)
    from public.badge_defs d where d.custom), '[]'::jsonb);
end $$;

create or replace function public.badge_def_delete(p_code text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if exists(select 1 from public.user_badges where code = p_code) then raise exception 'Des personnes possèdent ce badge : rendez-le indisponible plutôt que de le supprimer'; end if;
  delete from public.badge_defs where code = p_code and custom;
  if not found then raise exception 'Badge introuvable'; end if;
  perform public.log_admin('badge_supprime', p_code, '{}'::jsonb);
end $$;

-- attribue le badge à tous ceux qui remplissent déjà les conditions (badges automatiques disponibles)
create or replace function public.badge_sweep(p_code text) returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if not exists(select 1 from public.badge_defs where code = p_code and custom and auto) then raise exception 'Badge automatique introuvable'; end if;
  if not public._badge_open(p_code) then raise exception 'Ce badge est indisponible'; end if;
  for r in select id from public.profiles order by id limit 20000 loop
    if public._badge_eval(r.id, p_code) and public.badge_grant(r.id, p_code, null) then n := n + 1; end if;
  end loop;
  perform public.log_admin('badge_balayage', p_code, jsonb_build_object('attribues', n));
  return n;
end $$;

revoke all on function public.login_note(), public.badge_custom_sync_me(), public.badge_def_save(text,text,text,text,text,numeric,jsonb,boolean,boolean,timestamptz,timestamptz),
  public.badge_def_list(), public.badge_def_delete(text), public.badge_sweep(text) from public, anon;
grant execute on function public.login_note(), public.badge_custom_sync_me(), public.badge_def_save(text,text,text,text,text,numeric,jsonb,boolean,boolean,timestamptz,timestamptz),
  public.badge_def_list(), public.badge_def_delete(text), public.badge_sweep(text) to authenticated;

notify pgrst, 'reload schema';
