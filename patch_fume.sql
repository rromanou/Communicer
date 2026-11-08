-- ============================================================================
-- Communicer! — Patch « Personnage fumeur » (additif, relançable)
-- Personnage, dépendance, boutique d'objets (vapes, cigares, cigarettes, joints AU THÉ — jeu, rien de réel), pass VAZE+.
-- Les jetons passent par tok_add (portefeuille existant). À exécuter après patch_bourse.sql (aucune dépendance stricte).
-- ============================================================================
insert into public.shop_items(code, kind, name, descr, price, sort) values
 ('vaze_plus', 'feature', 'VAZE+', 'Créer et vendre vos propres vapes, cigares, cigarettes et joints au thé, avec la puissance et les effets de votre choix.', 27799, 62)
on conflict (code) do update set name = excluded.name, descr = excluded.descr, price = excluded.price;

create or replace function public._has_vaze(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = p_user and code = 'vaze_plus') $$;
revoke all on function public._has_vaze(uuid) from public, anon, authenticated;

create table if not exists public.smoke_items (
  code text primary key, kind text not null check (kind in ('vape','cigar','cigarette','joint')), name text not null check (char_length(name) between 3 and 30),
  price numeric(10,1) not null check (price >= 0), power int not null check (power between 1 and 100), fx jsonb not null,
  creator uuid references public.profiles(id) on delete set null, system boolean not null default false, active boolean not null default true,
  sold int not null default 0, created_at timestamptz not null default now());
create index if not exists smoke_items_creator on public.smoke_items(creator);
create table if not exists public.smoke_inv (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.smoke_items(code) on delete cascade,
  bought_at timestamptz not null default now(), primary key (user_id, code));
create table if not exists public.smoke_chars (
  user_id uuid primary key references public.profiles(id) on delete cascade, name text not null default 'Fumeur' check (char_length(name) between 1 and 24),
  hair text not null default 'court', hc text not null default '#3b2a1d', eyes text not null default 'ronds', ec text not null default '#2a1d12', skin text not null default '#f1c9a5',
  item text not null default 'vape_basic' references public.smoke_items(code) on update cascade,
  dep numeric(7,3) not null default 0 check (dep between 0 and 100), dep_at timestamptz not null default now(), last_smoke timestamptz, puffs int not null default 0,
  show boolean not null default false, created_at timestamptz not null default now());
alter table public.smoke_items add column if not exists smoke jsonb not null default '{}'::jsonb;
alter table public.smoke_chars add column if not exists endu numeric(7,2) not null default 0;
alter table public.smoke_chars add column if not exists lvl_top int not null default 0;
alter table public.smoke_chars add column if not exists lvl_claimed int not null default 0;
create or replace function public._sm_end(p_dep numeric, p_endu numeric) returns int language sql immutable as $f$ select 2000 + round(coalesce(p_dep, 0) * 40)::int + round(coalesce(p_endu, 0) * 8)::int $f$;
alter table public.smoke_items enable row level security; alter table public.smoke_inv enable row level security; alter table public.smoke_chars enable row level security;
revoke all on public.smoke_items, public.smoke_inv, public.smoke_chars from anon, authenticated;

insert into public.smoke_items(code, kind, name, price, power, fx, system) values
 ('vape_basic','vape','Vape basic',0,10,'{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4}',true),
 ('vape_normale','vape','Vape normale',50,20,'{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4}',true),
 ('cigarette_taco','cigarette','Cigarette Taco',60,24,'{"scr":0.6,"mouse":0.3,"delay":0.8,"anim":0.5,"warp":0.3,"psy":0.3,"obj":0.3,"hal":0.5,"fau":0.4,"ill":0.3}',true),
 ('cigare_tabacco','cigar','Cigare Tabacco',90,30,'{"scr":0.4,"mouse":0.5,"delay":1,"anim":0.9,"warp":0.6,"psy":0.5,"obj":0.4,"hal":0.7,"fau":0.5,"ill":0.4}',true),
 ('vape_premium','vape','Vape premium',100,32,'{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4}',true),
 ('cigarette_taccossimo','cigarette','Cigarette Taccossimo',150,44,'{"scr":0.6,"mouse":0.3,"delay":0.8,"anim":0.5,"warp":0.3,"psy":0.3,"obj":0.3,"hal":0.5,"fau":0.4,"ill":0.3}',true),
 ('cigare_cigarae','cigar','Cigare Cigarae',170,50,'{"scr":0.4,"mouse":0.5,"delay":1,"anim":0.9,"warp":0.6,"psy":0.5,"obj":0.4,"hal":0.7,"fau":0.5,"ill":0.4}',true),
 ('vape_vip','vape','Vape VIP',180,55,'{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4}',true),
 ('cigare_tabalanissmo','cigar','Cigare Tabalanissmo',300,75,'{"scr":0.4,"mouse":0.5,"delay":1,"anim":0.9,"warp":0.6,"psy":0.5,"obj":0.4,"hal":0.7,"fau":0.5,"ill":0.4}',true),
 ('vape_titanic','vape','Vape Titanic',330,80,'{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4}',true),
 ('joint_asperger','joint','Joint Asperger',340,92,'{"scr":1,"mouse":1,"delay":0.8,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1}',true),
 ('joint_mashaussete','joint','Joint Mashaussete',350,100,'{"scr":1,"mouse":1,"delay":0.8,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1}',true)
on conflict (code) do update set name = excluded.name, price = excluded.price, power = excluded.power, fx = excluded.fx, kind = excluded.kind where public.smoke_items.system;

-- ---------- utilitaires ----------
create or replace function public._sm_fx(p jsonb) returns jsonb language plpgsql immutable as $$
declare k text; o jsonb := '{}'; v numeric;
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Effets invalides'; end if;
  foreach k in array array['scr','mouse','delay','anim','warp','psy','obj','hal','fau','ill','scrl','blur','keys','coord','att'] loop
    v := coalesce((p->>k)::numeric, 0);
    if v < 0 or v > 1 then raise exception 'Chaque effet doit être entre 0 et 1'; end if;
    o := o || jsonb_build_object(k, round(v, 2));
  end loop;
  return o;
end $$;

create or replace function public._sm_row() returns public.smoke_chars language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars; d numeric; e numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.smoke_chars(user_id) values (auth.uid()) on conflict do nothing;
  insert into public.smoke_inv(user_id, code) values (auth.uid(), 'vape_basic') on conflict do nothing;
  select * into c from public.smoke_chars where user_id = auth.uid() for update;
  d := greatest(0, c.dep - 6 * extract(epoch from now() - c.dep_at) / 3600);
  e := greatest(0, coalesce(c.endu, 0) - 3 * extract(epoch from now() - c.dep_at) / 3600);
  if d <> c.dep or e <> c.endu or c.dep_at < now() - interval '1 minute' then update public.smoke_chars set dep = d, endu = e, dep_at = now() where user_id = auth.uid() returning * into c; end if;
  return c;
end $$;
revoke all on function public._sm_row() from public, anon, authenticated;

create or replace function public._sm_def(p_code text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('code', code, 'kind', kind, 'name', name, 'price', price, 'power', power, 'fx', fx, 'smoke', smoke) from public.smoke_items where code = p_code $$;
revoke all on function public._sm_def(text) from public, anon, authenticated;

-- ---------- état du personnage ----------
create or replace function public.smoke_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', c.item, 'show', c.show,
    'dep', round(c.dep, 3), 'endurance_ms', public._sm_end(c.dep, c.endu), 'puffs', c.puffs,
    'since_s', case when c.last_smoke is null then null else round(extract(epoch from now() - c.last_smoke)) end,
    'owned', coalesce((select jsonb_agg(public._sm_def(i.code) order by s.price) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_state() from public, anon;
grant execute on function public.smoke_state() to authenticated;

create or replace function public.smoke_char_set(p_name text, p_hair text, p_hc text, p_eyes text, p_ec text, p_skin text, p_show boolean) returns void language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name,''));
begin
  perform public._sm_row();
  perform public.rate_ok('smchar', 60, 3600);
  if char_length(n) < 1 or char_length(n) > 24 then raise exception 'Nom de 1 à 24 caractères'; end if;
  if p_hair not in ('court','longs','frange','chignon','tresses','cret','afro','chauve') then raise exception 'Coiffure inconnue'; end if;
  if p_eyes not in ('ronds','fins','grands','endormis','joyeux') then raise exception 'Yeux inconnus'; end if;
  if p_hc !~ '^#[0-9a-fA-F]{6}$' or p_ec !~ '^#[0-9a-fA-F]{6}$' or p_skin !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
  update public.smoke_chars set name = n, hair = p_hair, hc = p_hc, eyes = p_eyes, ec = p_ec, skin = p_skin, show = coalesce(p_show, false) where user_id = auth.uid();
end $$;
revoke all on function public.smoke_char_set(text, text, text, text, text, text, boolean) from public, anon;
grant execute on function public.smoke_char_set(text, text, text, text, text, text, boolean) to authenticated;

create or replace function public.smoke_equip(p_code text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._sm_row();
  if not exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Objet non possédé'; end if;
  update public.smoke_chars set item = p_code where user_id = auth.uid();
end $$;
revoke all on function public.smoke_equip(text) from public, anon;
grant execute on function public.smoke_equip(text) to authenticated;

-- ---------- boutique ----------
create or replace function public.smoke_shop() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0), 'vaze', public._has_vaze(auth.uid()),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'kind', s.kind, 'name', s.name, 'price', s.price, 'power', s.power, 'fx', s.fx, 'smoke', s.smoke, 'active', s.active, 'system', s.system,
        'owned', exists(select 1 from public.smoke_inv i where i.user_id = auth.uid() and i.code = s.code), 'mine', s.creator = auth.uid(), 'sold', s.sold,
        'by', case when s.system then null else (select username from public.profiles where id = s.creator) end) order by s.system desc, s.price, s.name)
      from public.smoke_items s where s.active or s.creator = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_shop() from public, anon;
grant execute on function public.smoke_shop() to authenticated;

create or replace function public.smoke_buy(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.smoke_items; b numeric; net numeric;
begin
  perform public._sm_row();
  perform public.rate_ok('smbuy', 40, 3600);
  select * into s from public.smoke_items where code = p_code for update;
  if not found or not s.active then raise exception 'Objet indisponible'; end if;
  if exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
  if s.price > 0 then
    insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
    select balance into b from public.wallets where user_id = auth.uid() for update;
    if b < s.price then raise exception 'Jetons insuffisants'; end if;
    perform public.tok_add(auth.uid(), -s.price, 'achat ' || s.name, null);
    if s.creator is not null and s.creator <> auth.uid() then
      net := round(s.price * 0.9, 1);
      perform public.tok_add(s.creator, net, 'vente ' || s.name, null);
      perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, s.price - net, 'frais de vente ' || s.name, null);
    else
      perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, s.price, 'achat ' || s.name, null);
    end if;
  end if;
  insert into public.smoke_inv(user_id, code) values (auth.uid(), p_code);
  update public.smoke_items set sold = sold + 1 where code = p_code;
  return public._sm_def(p_code);
end $$;
revoke all on function public.smoke_buy(text) from public, anon;
grant execute on function public.smoke_buy(text) to authenticated;

-- ---------- bouffée : la dépendance augmente vite, redescend lentement ----------
create or replace function public.smoke_puff(p_code text, p_q numeric, p_ms int) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_items; q numeric := greatest(0, least(1, coalesce(p_q, 0))); gain numeric; nd numeric;
begin
  perform public.rate_ok('smpuff', 90, 60);
  select * into s from public.smoke_items where code = p_code;
  if not found or not exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Objet non possédé'; end if;
  if coalesce(p_ms, 0) > public._sm_end(c.dep, c.endu) + 1500 then q := 0; end if;
  gain := s.power / 100.0 * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  nd := least(100, c.dep + gain);
  update public.smoke_chars set dep = nd, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid();
  return jsonb_build_object('dep', round(nd, 3), 'endurance_ms', public._sm_end(nd, c.endu), 'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - c.last_smoke)) end);
end $$;
revoke all on function public.smoke_puff(text, numeric, int) from public, anon;
grant execute on function public.smoke_puff(text, numeric, int) to authenticated;

-- ---------- créer / modifier ses objets (VAZE+) ----------
create or replace function public.smoke_item_create(p_name text, p_kind text, p_price numeric, p_power int, p_fx jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name,'')); c text;
begin
  perform public._sm_row();
  if not public._has_vaze(auth.uid()) then raise exception 'Il faut le pass VAZE+'; end if;
  perform public.rate_ok('smnew', 30, 3600);
  if char_length(n) < 3 or char_length(n) > 30 then raise exception 'Nom de 3 à 30 caractères'; end if;
  if p_kind not in ('vape','cigar','cigarette','joint') then raise exception 'Type inconnu'; end if;
  if p_price is null or p_price < 10 or p_price > 100000 or p_price <> round(p_price, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if;
  if p_power is null or p_power < 1 or p_power > 100 then raise exception 'Puissance entre 1 et 100'; end if;
  if (select count(*) from public.smoke_items where creator = auth.uid()) >= 20 then raise exception '20 objets au maximum'; end if;
  c := 'u' || substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 1, 10);
  insert into public.smoke_items(code, kind, name, price, power, fx, creator) values (c, p_kind, n, p_price, p_power, public._sm_fx(p_fx), auth.uid());
  insert into public.smoke_inv(user_id, code) values (auth.uid(), c);
  return public._sm_def(c);
end $$;
revoke all on function public.smoke_item_create(text, text, numeric, int, jsonb) from public, anon;
grant execute on function public.smoke_item_create(text, text, numeric, int, jsonb) to authenticated;

create or replace function public.smoke_item_update(p_code text, p_price numeric, p_power int, p_fx jsonb, p_active boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._sm_row();
  if not exists(select 1 from public.smoke_items where code = p_code and creator = auth.uid() and not system) then raise exception 'Objet introuvable'; end if;
  if p_price is null or p_price < 10 or p_price > 100000 or p_price <> round(p_price, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if;
  if p_power is null or p_power < 1 or p_power > 100 then raise exception 'Puissance entre 1 et 100'; end if;
  update public.smoke_items set price = p_price, power = p_power, fx = public._sm_fx(p_fx), active = coalesce(p_active, true) where code = p_code;
end $$;
revoke all on function public.smoke_item_update(text, numeric, int, jsonb, boolean) from public, anon;
grant execute on function public.smoke_item_update(text, numeric, int, jsonb, boolean) to authenticated;

-- ---------- exposition sur le profil ----------
create or replace function public.smoke_profile(p_username text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare u uuid; c public.smoke_chars; i public.smoke_items; d numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select id into u from public.profiles where lower(username) = lower(btrim(coalesce(p_username,'')));
  if u is null then return null; end if;
  select * into c from public.smoke_chars where user_id = u;
  if not found or (not c.show and u <> auth.uid()) then return null; end if;
  select * into i from public.smoke_items where code = c.item;
  d := greatest(0, c.dep - 6 * extract(epoch from now() - c.dep_at) / 3600);
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'dep', round(d, 1), 'endurance_ms', public._sm_end(d, c.endu), 'level', c.lvl_top,
    'power', i.power, 'item', i.name, 'kind', i.kind, 'puffs', c.puffs, 'owned', (select count(*) from public.smoke_inv where user_id = u), 'shown', c.show);
end $$;
revoke all on function public.smoke_profile(text) from public, anon;
grant execute on function public.smoke_profile(text) to authenticated;


-- ============================================================================
-- Tricks de fumée (achetables) — utilisés seul et dans le jeu « Fumatoir »
-- ============================================================================
create table if not exists public.smoke_tricks (code text primary key, name text not null, price numeric(10,1) not null check (price >= 0), sort int not null default 0);
create table if not exists public.smoke_trick_inv (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.smoke_tricks(code) on delete cascade,
  bought_at timestamptz not null default now(), primary key (user_id, code));
alter table public.smoke_trick_inv add column if not exists uses int not null default 0;
alter table public.smoke_tricks enable row level security; alter table public.smoke_trick_inv enable row level security;
revoke all on public.smoke_tricks, public.smoke_trick_inv from anon, authenticated;
insert into public.smoke_tricks(code, name, price, sort) values
 ('o_rings','O-Rings',99,1),('ghost_inhale','Ghost Inhale',129,2),('french_inhale','French Inhale',149,3),('dragon','Dragon',349,4),('waterfall','Waterfall',199,5),('jellyfish','Jellyfish',449,6),
 ('tornado','Tornado',499,7),('smoke_bubble','Smoke Bubble',249,8),('double_ring','Double O-Ring',169,9),('triple_ring','Triple O-Ring',299,10),('bane_inhale','Bane Inhale',229,11),
 ('triangle','Triangle',399,12),('heart','Heart',549,13),('ghost_ring','Ghost Ring',279,14),('smoke_rings','Smoke Rings',179,15),('smoke_cascade','Smoke Cascade',599,16),
 ('mushroom','Mushroom Cloud',649,17),('vortex','Smoke Vortex',699,18)
on conflict (code) do update set name = excluded.name, price = excluded.price, sort = excluded.sort;

-- état : ajoute les tricks possédés (le trick gratuit est donné d'office)
create or replace function public.smoke_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', c.item, 'show', c.show,
    'dep', round(c.dep, 3), 'endurance_ms', public._sm_end(c.dep, c.endu), 'puffs', c.puffs,
    'since_s', case when c.last_smoke is null then null else round(extract(epoch from now() - c.last_smoke)) end,
    'owned', coalesce((select jsonb_agg(public._sm_def(i.code) order by s.price) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = auth.uid()), '[]'::jsonb),
    'tricks', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'uses', uses) order by code) from public.smoke_trick_inv where user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_state() from public, anon;
grant execute on function public.smoke_state() to authenticated;

create or replace function public.smoke_tricks_list() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._sm_row();
  return jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'tricks', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'price', t.price, 'owned', exists(select 1 from public.smoke_trick_inv i where i.user_id = auth.uid() and i.code = t.code), 'uses', coalesce((select i.uses from public.smoke_trick_inv i where i.user_id = auth.uid() and i.code = t.code), 0)) order by t.sort) from public.smoke_tricks t), '[]'::jsonb));
end $$;
revoke all on function public.smoke_tricks_list() from public, anon;
grant execute on function public.smoke_tricks_list() to authenticated;

create or replace function public.smoke_trick_buy(p_code text) returns void language plpgsql security definer set search_path = public as $$
declare t public.smoke_tricks; b numeric;
begin
  perform public._sm_row();
  perform public.rate_ok('smtrick', 40, 3600);
  select * into t from public.smoke_tricks where code = p_code;
  if not found then raise exception 'Trick introuvable'; end if;
  if exists(select 1 from public.smoke_trick_inv where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
  if t.price > 0 then
    insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
    select balance into b from public.wallets where user_id = auth.uid() for update;
    if b < t.price then raise exception 'Jetons insuffisants'; end if;
    perform public.tok_add(auth.uid(), -t.price, 'trick ' || t.name, null);
    perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, t.price, 'trick ' || t.name, null);
  end if;
  insert into public.smoke_trick_inv(user_id, code) values (auth.uid(), p_code);
end $$;
revoke all on function public.smoke_trick_buy(text) from public, anon;
grant execute on function public.smoke_trick_buy(text) to authenticated;


-- ============================================================================
-- Lot 18b : maîtrise des tricks, réhabilitation
-- ============================================================================
alter table public.smoke_chars add column if not exists rehab_last timestamptz;

-- usage des tricks (la maîtrise monte très lentement : côté client 1 - exp(-usages/300))
create or replace function public.smoke_trick_use(p_code text, p_n int) returns int language plpgsql security definer set search_path = public as $$
declare u int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('smtuse', 120, 60);
  update public.smoke_trick_inv set uses = least(5000, uses + greatest(1, least(10, coalesce(p_n, 1)))) where user_id = auth.uid() and code = p_code returning uses into u;
  if not found then raise exception 'Trick non possédé'; end if;
  return u;
end $$;
revoke all on function public.smoke_trick_use(text, int) from public, anon;
grant execute on function public.smoke_trick_use(text, int) to authenticated;

-- réhabilitation : entrer, battement (toutes les ~10 s tant que la page est visible), sortir
create or replace function public.smoke_rehab_start() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  update public.smoke_chars set rehab_last = now() where user_id = auth.uid();
  return jsonb_build_object('dep', round(c.dep, 3));
end $$;
create or replace function public.smoke_rehab_tick() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); el numeric; cr numeric; nd numeric;
begin
  perform public.rate_ok('smrehab', 40, 60);
  if c.rehab_last is null then return jsonb_build_object('dep', round(c.dep, 3), 'active', false); end if;
  el := extract(epoch from now() - c.rehab_last);
  -- page cachée / fermée : pas de crédit (au-delà de 15 s on ne rattrape rien)
  cr := case when el <= 15 then el else 0 end;
  -- 0,3 par minute au total : 0,1 naturel (déjà appliqué) + 0,2 de réhabilitation
  nd := greatest(0, c.dep - 0.2 * cr / 60);
  update public.smoke_chars set dep = nd, dep_at = now(), rehab_last = now() where user_id = auth.uid();
  return jsonb_build_object('dep', round(nd, 3), 'endurance_ms', public._sm_end(nd, c.endu), 'active', true);
end $$;
create or replace function public.smoke_rehab_stop() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  update public.smoke_chars set rehab_last = null where user_id = auth.uid();
  return jsonb_build_object('dep', round(c.dep, 3), 'endurance_ms', public._sm_end(c.dep, c.endu));
end $$;
revoke all on function public.smoke_rehab_start(), public.smoke_rehab_tick(), public.smoke_rehab_stop() from public, anon;
grant execute on function public.smoke_rehab_start(), public.smoke_rehab_tick(), public.smoke_rehab_stop() to authenticated;

-- pas de bouffée pendant la réhabilitation (battement récent)
create or replace function public.smoke_puff(p_code text, p_q numeric, p_ms int) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_items; q numeric := greatest(0, least(1, coalesce(p_q, 0))); gain numeric; nd numeric;
begin
  perform public.rate_ok('smpuff', 120, 60);
  if c.rehab_last is not null and c.rehab_last > now() - interval '60 seconds' then raise exception 'En réhabilitation : impossible de fumer'; end if;
  select * into s from public.smoke_items where code = p_code;
  if not found or not exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Objet non possédé'; end if;
  if coalesce(p_ms, 0) > public._sm_end(c.dep, c.endu) + 2500 then q := 0; end if;
  gain := s.power / 100.0 * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  nd := least(100, c.dep + gain);
  update public.smoke_chars set dep = nd, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid();
  return jsonb_build_object('dep', round(nd, 3), 'endurance_ms', public._sm_end(nd, c.endu), 'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - c.last_smoke)) end);
end $$;
revoke all on function public.smoke_puff(text, numeric, int) from public, anon;
grant execute on function public.smoke_puff(text, numeric, int) to authenticated;

-- ============================================================================
-- Lot 18c : nouveaux effets (scrl, blur, keys, coord, att) et nouveaux objets
-- ============================================================================
with b(kind, fx) as (values
 ('vape','{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4,"scrl":0.4,"blur":0.7,"keys":0.3,"coord":0.4,"att":0.4}'::jsonb),
 ('cigarette','{"scr":0.6,"mouse":0.3,"delay":0.8,"anim":0.5,"warp":0.3,"psy":0.3,"obj":0.3,"hal":0.5,"fau":0.4,"ill":0.3,"scrl":0.3,"blur":0.3,"keys":0.7,"coord":0.5,"att":0.6}'::jsonb),
 ('cigar','{"scr":0.4,"mouse":0.5,"delay":1,"anim":0.9,"warp":0.6,"psy":0.5,"obj":0.4,"hal":0.7,"fau":0.5,"ill":0.4,"scrl":0.6,"blur":0.5,"keys":0.5,"coord":0.7,"att":0.5}'::jsonb),
 ('joint','{"scr":1,"mouse":1,"delay":0.8,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}'::jsonb))
update public.smoke_items s set fx = s.fx || jsonb_build_object('scrl', b.fx->'scrl', 'blur', b.fx->'blur', 'keys', b.fx->'keys', 'coord', b.fx->'coord', 'att', b.fx->'att')
from b where b.kind = s.kind and s.system and not (s.fx ? 'scrl');

with b(kind, fx) as (values
 ('vape','{"scr":0.5,"mouse":0.7,"delay":0.3,"anim":1,"warp":0.4,"psy":0.7,"obj":0.5,"hal":0.3,"fau":0.2,"ill":0.4,"scrl":0.4,"blur":0.7,"keys":0.3,"coord":0.4,"att":0.4}'::jsonb),
 ('cigarette','{"scr":0.6,"mouse":0.3,"delay":0.8,"anim":0.5,"warp":0.3,"psy":0.3,"obj":0.3,"hal":0.5,"fau":0.4,"ill":0.3,"scrl":0.3,"blur":0.3,"keys":0.7,"coord":0.5,"att":0.6}'::jsonb),
 ('cigar','{"scr":0.4,"mouse":0.5,"delay":1,"anim":0.9,"warp":0.6,"psy":0.5,"obj":0.4,"hal":0.7,"fau":0.5,"ill":0.4,"scrl":0.6,"blur":0.5,"keys":0.5,"coord":0.7,"att":0.5}'::jsonb),
 ('joint','{"scr":1,"mouse":1,"delay":0.8,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}'::jsonb))
insert into public.smoke_items(code, kind, name, price, power, fx, system)
select v.code, v.kind, v.name, v.price, v.power, b.fx, true from (values
 ('vape_mini','vape','Vape Mini',55,16),
 ('vape_menthe','vape','Vape Menthe',75,26),
 ('vape_fruitee','vape','Vape Fruitée',120,36),
 ('vape_nuage','vape','Vape Nuage',150,42),
 ('vape_turbo','vape','Vape Turbo',230,63),
 ('vape_eclipse','vape','Vape Éclipse',280,70),
 ('cigarette_blonde','cigarette','Cigarette Blonde',52,14),
 ('cigarette_brune','cigarette','Cigarette Brune',85,28),
 ('cigarette_mentholee','cigarette','Cigarette Mentholée',110,34),
 ('cigarette_roulee','cigarette','Cigarette Roulée',200,58),
 ('cigare_corona','cigar','Cigare Corona',130,40),
 ('cigare_havane','cigar','Cigare Havane',210,62),
 ('cigare_maduro','cigar','Cigare Maduro',260,68),
 ('joint_the_blanc','joint','Joint Thé Blanc',290,82),
 ('joint_jasmin','joint','Joint Jasmin',315,86),
 ('joint_earl_grey','joint','Joint Earl Grey',325,88)) as v(code, kind, name, price, power) join b on b.kind = v.kind
on conflict (code) do update set name = excluded.name, price = excluded.price, power = excluded.power, fx = excluded.fx, kind = excluded.kind where public.smoke_items.system;

-- ============================================================================
-- Lot 18d : cônes, plafond d'endurance, niveaux (23)
-- ============================================================================
alter table public.smoke_items drop constraint if exists smoke_items_kind_check;
alter table public.smoke_items add constraint smoke_items_kind_check check (kind in ('vape','cigar','cigarette','joint','cone'));
alter table public.smoke_items drop constraint if exists smoke_items_power_check;
alter table public.smoke_items add constraint smoke_items_power_check check (power between 1 and 2050);

insert into public.smoke_items(code, kind, name, price, power, fx, system) values
 ('cone_reds','cone','Cône REDS',1500,300,'{"scr":1,"mouse":1,"delay":1,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}',true),
 ('cone_violets','cone','Cône VIOLETS',3000,500,'{"scr":1,"mouse":1,"delay":1,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}',true),
 ('cone_tricks','cone','Cône TRICKS',8000,700,'{"scr":1,"mouse":1,"delay":1,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}',true),
 ('cone_og','cone','Cône OG',6000,900,'{"scr":1,"mouse":1,"delay":1,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}',true),
 ('cone_bluuby','cone','Cône BLUUBY',15000,2050,'{"scr":1,"mouse":1,"delay":1,"anim":1,"warp":1,"psy":1,"obj":1,"hal":1,"fau":1,"ill":1,"scrl":1,"blur":1,"keys":1,"coord":1,"att":1}',true)
on conflict (code) do update set name = excluded.name, price = excluded.price, power = excluded.power, fx = excluded.fx, kind = excluded.kind where public.smoke_items.system;

create table if not exists public.smoke_levels (n int primary key, name text not null, xp int not null, reward numeric(10,1) not null);
alter table public.smoke_levels enable row level security; revoke all on public.smoke_levels from anon, authenticated;
insert into public.smoke_levels(n, name, xp, reward) values
 (1,'Bouffée Novice',0,55),
 (2,'Vapoteur Timide',30,70),
 (3,'Fumeur du Dimanche',40,85),
 (4,'Habitué du Balcon',53,105),
 (5,'Souffleur de Ronds',71,130),
 (6,'Collectionneur de Mégots',94,165),
 (7,'Apprenti Tabacologue',125,200),
 (8,'Maître des Volutes',166,250),
 (9,'Alchimiste de Brume',221,310),
 (10,'Chasseur de Nuages',294,385),
 (11,'Gardien du Sweet Spot',391,480),
 (12,'Seigneur du Cendrier',520,600),
 (13,'Fumeur Légendaire',691,745),
 (14,'Dragon de Fumée',919,925),
 (15,'Spectre Blanc',1222,1145),
 (16,'Tornade Vivante',1626,1425),
 (17,'Archiviste des Fumées',2162,1770),
 (18,'Sage du Calumet',2876,2195),
 (19,'Roi des Nuages',3825,2730),
 (20,'Empereur du Tabac',5087,3390),
 (21,'Oracle de Brume',6766,4210),
 (22,'Titan de Fumée',8998,5230),
 (23,'Légende du Fumatoir',11968,6500)
on conflict (n) do update set name = excluded.name, xp = excluded.xp, reward = excluded.reward;

-- expérience : bouffées, puissance maximale possédée (plafonnée à 100) et plafond d'endurance gagné avec les cônes
create or replace function public._sm_lvl_upd(c public.smoke_chars) returns int language plpgsql security definer set search_path = public as $$
declare x numeric; n int;
begin
  x := c.puffs * 2 + coalesce((select max(least(s.power, 100)) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = c.user_id), 0) * 3 + c.endu * 0.5;
  select coalesce(max(l.n), 0) into n from public.smoke_levels l where l.xp <= x;
  if n > c.lvl_top then update public.smoke_chars set lvl_top = n where user_id = c.user_id; return n; end if;
  return c.lvl_top;
end $$;
revoke all on function public._sm_lvl_upd(public.smoke_chars) from public, anon, authenticated;

create or replace function public.smoke_levels_list() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); lv int := public._sm_lvl_upd(c); x numeric;
begin
  select * into c from public.smoke_chars where user_id = auth.uid();
  x := c.puffs * 2 + coalesce((select max(least(s.power, 100)) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = c.user_id), 0) * 3 + c.endu * 0.5;
  return jsonb_build_object('xp', round(x), 'top', c.lvl_top, 'claimed', c.lvl_claimed,
    'claimable', coalesce((select sum(reward) from public.smoke_levels where n > c.lvl_claimed and n <= c.lvl_top), 0),
    'levels', coalesce((select jsonb_agg(jsonb_build_object('n', l.n, 'name', l.name, 'xp', l.xp, 'reward', l.reward) order by l.n) from public.smoke_levels l), '[]'::jsonb));
end $$;
revoke all on function public.smoke_levels_list() from public, anon;
grant execute on function public.smoke_levels_list() to authenticated;

create or replace function public.smoke_level_claim() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); tot numeric;
begin
  perform public.rate_ok('smlvl', 20, 3600);
  perform public._sm_lvl_upd(c);
  select * into c from public.smoke_chars where user_id = auth.uid() for update;
  select coalesce(sum(reward), 0) into tot from public.smoke_levels where n > c.lvl_claimed and n <= c.lvl_top;
  if tot <= 0 then raise exception 'Aucune récompense à récupérer'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  perform public.tok_add(auth.uid(), tot, 'niveaux fumeur', null);
  update public.smoke_chars set lvl_claimed = lvl_top where user_id = auth.uid();
  return jsonb_build_object('tokens', tot, 'level', c.lvl_top);
end $$;
revoke all on function public.smoke_level_claim() from public, anon;
grant execute on function public.smoke_level_claim() to authenticated;

-- état : ajoute endu et niveau
create or replace function public.smoke_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); n int;
begin
  n := public._sm_lvl_upd(c);
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', c.item, 'show', c.show,
    'dep', round(c.dep, 3), 'endu', c.endu, 'endurance_ms', public._sm_end(c.dep, c.endu), 'puffs', c.puffs, 'level', n, 'lvl_claimed', c.lvl_claimed,
    'since_s', case when c.last_smoke is null then null else round(extract(epoch from now() - c.last_smoke)) end,
    'owned', coalesce((select jsonb_agg(public._sm_def(i.code) order by s.price) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = auth.uid()), '[]'::jsonb),
    'tricks', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'uses', uses) order by code) from public.smoke_trick_inv where user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_state() from public, anon;
grant execute on function public.smoke_state() to authenticated;

-- bouffée : les cônes (puissance > 100) comptent comme 2,5 fois une puissance de 100 et montent le plafond d'endurance (jusqu'à 2050)
create or replace function public.smoke_puff(p_code text, p_q numeric, p_ms int) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_items; q numeric := greatest(0, least(1, coalesce(p_q, 0))); gain numeric; nd numeric; ne numeric; pf numeric; lv int;
begin
  perform public.rate_ok('smpuff', 120, 60);
  if c.rehab_last is not null and c.rehab_last > now() - interval '60 seconds' then raise exception 'En réhabilitation : impossible de fumer'; end if;
  select * into s from public.smoke_items where code = p_code;
  if not found or not exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Objet non possédé'; end if;
  if coalesce(p_ms, 0) > public._sm_end(c.dep, c.endu) + 2500 then q := 0; end if;
  pf := least(s.power, 100) / 100.0 * (case when s.kind = 'cone' then 2.5 else 1 end);
  gain := pf * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  nd := least(100, c.dep + gain);
  ne := case when s.kind = 'cone' and q >= 0.2 then least(2050, c.endu + s.power / 50.0 * q) else c.endu end;
  update public.smoke_chars set dep = nd, endu = ne, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid() returning * into c;
  lv := public._sm_lvl_upd(c);
  return jsonb_build_object('dep', round(nd, 3), 'endu', ne, 'endurance_ms', public._sm_end(nd, ne), 'level', lv,
    'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - coalesce(c.last_smoke, now()))) end);
end $$;
revoke all on function public.smoke_puff(text, numeric, int) from public, anon;
grant execute on function public.smoke_puff(text, numeric, int) to authenticated;

-- ============================================================================
-- Lot 18d-bis : la puissance d'un objet créé est calculée par ses effets ; fumée personnalisable
-- ============================================================================
create or replace function public._sm_power(p_fx jsonb) returns int language sql immutable as $f$
  select greatest(1, least(100, round(100 * (select coalesce(sum(v::numeric), 0) from jsonb_each_text(p_fx) as e(k, v)) / 15)))::int $f$;

create or replace function public._sm_smoke(p jsonb) returns jsonb language plpgsql immutable as $$
declare col text := coalesce(p->>'color', '#ffffff'); d numeric := coalesce((p->>'density')::numeric, 1); s numeric := coalesce((p->>'size')::numeric, 1); v numeric := coalesce((p->>'speed')::numeric, 1);
begin
  if p is not null and jsonb_typeof(p) <> 'object' then raise exception 'Fumée invalide'; end if;
  if col !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur de fumée invalide'; end if;
  if d < 0.2 or d > 2 or s < 0.5 or s > 2 or v < 0.5 or v > 2 then raise exception 'Densité, taille et vitesse de fumée : de 0,2 à 2 (taille et vitesse de 0,5 à 2)'; end if;
  return jsonb_build_object('color', lower(col), 'density', round(d, 2), 'size', round(s, 2), 'speed', round(v, 2));
end $$;

create or replace function public.smoke_item_create(p_name text, p_kind text, p_price numeric, p_power int, p_fx jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name,'')); c text; vfx jsonb;
begin
  perform public._sm_row();
  if not public._has_vaze(auth.uid()) then raise exception 'Il faut le pass VAZE+'; end if;
  perform public.rate_ok('smnew', 30, 3600);
  if char_length(n) < 3 or char_length(n) > 30 then raise exception 'Nom de 3 à 30 caractères'; end if;
  if p_kind not in ('vape','cigar','cigarette','joint') then raise exception 'Type inconnu'; end if;
  if p_price is null or p_price < 10 or p_price > 100000 or p_price <> round(p_price, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if;
  if (select count(*) from public.smoke_items where creator = auth.uid()) >= 20 then raise exception '20 objets au maximum'; end if;
  vfx := public._sm_fx(p_fx);
  c := 'u' || substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 1, 10);
  insert into public.smoke_items(code, kind, name, price, power, fx, smoke, creator) values (c, p_kind, n, p_price, public._sm_power(vfx), vfx, public._sm_smoke(p_fx->'smoke'), auth.uid());
  insert into public.smoke_inv(user_id, code) values (auth.uid(), c);
  return public._sm_def(c);
end $$;
revoke all on function public.smoke_item_create(text, text, numeric, int, jsonb) from public, anon;
grant execute on function public.smoke_item_create(text, text, numeric, int, jsonb) to authenticated;

create or replace function public.smoke_item_update(p_code text, p_price numeric, p_power int, p_fx jsonb, p_active boolean) returns void language plpgsql security definer set search_path = public as $$
declare vfx jsonb;
begin
  perform public._sm_row();
  if not exists(select 1 from public.smoke_items where code = p_code and creator = auth.uid() and not system) then raise exception 'Objet introuvable'; end if;
  if p_price is null or p_price < 10 or p_price > 100000 or p_price <> round(p_price, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if;
  vfx := public._sm_fx(p_fx);
  update public.smoke_items set price = p_price, power = public._sm_power(vfx), fx = vfx, smoke = public._sm_smoke(p_fx->'smoke'), active = coalesce(p_active, true) where code = p_code;
end $$;
revoke all on function public.smoke_item_update(text, numeric, int, jsonb, boolean) from public, anon;
grant execute on function public.smoke_item_update(text, numeric, int, jsonb, boolean) to authenticated;
notify pgrst, 'reload schema';

-- ============================================================================
-- Lot 18e : état en direct du personnage (profil), overdose, mort, sauvetage
-- ============================================================================
alter table public.smoke_chars add column if not exists live jsonb not null default '{}'::jsonb;
alter table public.smoke_chars add column if not exists live_at timestamptz;
alter table public.smoke_chars add column if not exists od_start timestamptz;
alter table public.smoke_chars add column if not exists rescued_at timestamptz;
alter table public.smoke_chars add column if not exists died_at timestamptz;
create table if not exists public.smoke_deaths (id bigserial primary key, user_id uuid not null references public.profiles(id) on delete cascade, name text, at timestamptz not null default now(), lost numeric not null default 0);
create table if not exists public.smoke_rescue (target uuid not null references public.profiles(id) on delete cascade, rescuer uuid not null references public.profiles(id) on delete cascade, started timestamptz not null default now(), primary key (target, rescuer));
alter table public.smoke_deaths enable row level security; alter table public.smoke_rescue enable row level security;
revoke all on public.smoke_deaths, public.smoke_rescue from anon, authenticated;

-- mort : -30 % des jetons, objets, tricks, VAZE+ perdus, personnage supprimé, statistiques remises à zéro sauf les bouffées
create or replace function public._sm_die(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars; b numeric := 0; lost numeric := 0;
begin
  select * into c from public.smoke_chars where user_id = p_user for update;
  if not found then return; end if;
  select coalesce(balance, 0) into b from public.wallets where user_id = p_user;
  lost := round(coalesce(b, 0) * 0.3, 1);
  if lost > 0 then perform public.tok_add(p_user, -lost, 'overdose : mauvais traitement', null); end if;
  delete from public.smoke_inv where user_id = p_user;
  delete from public.smoke_trick_inv where user_id = p_user;
  delete from public.smoke_pill_inv where user_id = p_user;
  delete from public.inventory where user_id = p_user and code = 'vaze_plus';
  insert into public.smoke_deaths(user_id, name, lost) values (p_user, c.name, lost);
  delete from public.smoke_rescue where target = p_user;
  delete from public.smoke_chars where user_id = p_user;
  insert into public.smoke_chars(user_id, puffs, died_at) values (p_user, c.puffs, now());
  insert into public.smoke_inv(user_id, code) values (p_user, 'vape_basic') on conflict do nothing;
end $$;
revoke all on function public._sm_die(uuid) from public, anon, authenticated;

create or replace function public._sm_row() returns public.smoke_chars language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars; d numeric; e numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.smoke_chars(user_id) values (auth.uid()) on conflict do nothing;
  insert into public.smoke_inv(user_id, code) values (auth.uid(), 'vape_basic') on conflict do nothing;
  select * into c from public.smoke_chars where user_id = auth.uid() for update;
  if c.od_start is not null and now() > c.od_start + interval '2 minutes' then
    perform public._sm_die(auth.uid());
    select * into c from public.smoke_chars where user_id = auth.uid() for update;
  end if;
  d := greatest(0, c.dep - 6 * extract(epoch from now() - c.dep_at) / 3600);
  e := greatest(0, coalesce(c.endu, 0) - 3 * extract(epoch from now() - c.dep_at) / 3600);
  if d <> c.dep or e <> c.endu or c.dep_at < now() - interval '1 minute' then update public.smoke_chars set dep = d, endu = e, dep_at = now() where user_id = auth.uid() returning * into c; end if;
  return c;
end $$;
revoke all on function public._sm_row() from public, anon, authenticated;

-- état : ajoute l'overdose et la mort récente
create or replace function public.smoke_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); n int;
begin
  n := public._sm_lvl_upd(c);
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', c.item, 'show', c.show,
    'dep', round(c.dep, 3), 'endu', c.endu, 'endurance_ms', public._sm_end(c.dep, c.endu), 'puffs', c.puffs, 'level', n, 'lvl_claimed', c.lvl_claimed,
    'since_s', case when c.last_smoke is null then null else round(extract(epoch from now() - c.last_smoke)) end,
    'od_left', case when c.od_start is null then null else greatest(0, round(120 - extract(epoch from now() - c.od_start))) end,
    'vaze', public._has_vaze(auth.uid()), 'pills', public._sm_pills_active(c.pills),
    'rescued_s', case when c.rescued_at is null then null else round(extract(epoch from now() - c.rescued_at)) end,
    'died_s', case when c.died_at is null then null else round(extract(epoch from now() - c.died_at)) end,
    'owned', coalesce((select jsonb_agg(public._sm_def(i.code) order by s.price) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = auth.uid()), '[]'::jsonb),
    'tricks', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'uses', uses) order by code) from public.smoke_trick_inv where user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_state() from public, anon;
grant execute on function public.smoke_state() to authenticated;

-- le joueur envoie son état visible (mode de la bouche, intoxication, paranoïa…) ; refusé si le personnage n'est pas affiché
create or replace function public.smoke_live_set(p_live jsonb) returns void language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); l jsonb := '{}'::jsonb; m text;
begin
  perform public.rate_ok('smlive', 120, 60);
  if p_live is null or jsonb_typeof(p_live) <> 'object' then raise exception 'État invalide'; end if;
  m := coalesce(p_live->>'mode', '');
  if m not in ('', 'smoke', 'exh', 'hold', 'cough', 'angry', 'sad') then m := ''; end if;
  l := jsonb_build_object('mode', m,
    'ef', round(greatest(0, least(1.2, coalesce((p_live->>'ef')::numeric, 0))), 2),
    'par', round(greatest(0, least(1, coalesce((p_live->>'par')::numeric, 0))), 2),
    'crav', round(greatest(0, least(1, coalesce((p_live->>'crav')::numeric, 0))), 2),
    'tox', round(greatest(0, least(1, coalesce((p_live->>'tox')::numeric, 0))), 2),
    'ix', round(greatest(0, least(1, coalesce((p_live->>'ix')::numeric, 0))), 2),
    'bad', coalesce((p_live->>'bad')::boolean, false),
    'fx', coalesce((select jsonb_object_agg(k, round(least(1.2, greatest(0, v::numeric)), 2)) from jsonb_each_text(coalesce(p_live->'fx', '{}'::jsonb)) as e(k, v) where k ~ '^[a-z]{2,8}$' and v ~ '^[0-9.]+$'), '{}'::jsonb));
  update public.smoke_chars set live = l, live_at = now() where user_id = auth.uid();
end $$;
revoke all on function public.smoke_live_set(jsonb) from public, anon;
grant execute on function public.smoke_live_set(jsonb) to authenticated;

-- le visiteur lit l'état en direct (volatile : applique la mort si les 2 minutes sont écoulées)
create or replace function public.smoke_live(p_username text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid; c public.smoke_chars; i public.smoke_items; d numeric; lv jsonb; od int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select id into u from public.profiles where lower(username) = lower(btrim(coalesce(p_username,'')));
  if u is null then return null; end if;
  select * into c from public.smoke_chars where user_id = u;
  if not found then return null; end if;
  if c.od_start is not null and now() > c.od_start + interval '2 minutes' then
    perform public._sm_die(u);
    select * into c from public.smoke_chars where user_id = u;
  end if;
  od := case when c.od_start is null then null else greatest(0, round(120 - extract(epoch from now() - c.od_start)))::int end;
  if not c.show and u <> auth.uid() then
    if od is null then return null; end if;
    return jsonb_build_object('shown', false, 'name', c.name, 'od_left', od, 'self', false, 'live', '{}'::jsonb, 'rescuing', exists(select 1 from public.smoke_rescue r where r.target = u and r.rescuer = auth.uid()));
  end if;
  select * into i from public.smoke_items where code = c.item;
  d := greatest(0, c.dep - 6 * extract(epoch from now() - c.dep_at) / 3600);
  lv := case when c.live_at is not null and c.live_at > now() - interval '15 seconds' then c.live else '{}'::jsonb end;
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'dep', round(d, 1), 'endurance_ms', public._sm_end(d, c.endu), 'level', c.lvl_top,
    'power', i.power, 'item', i.name, 'kind', i.kind, 'code', i.code, 'smoke', i.smoke, 'puffs', c.puffs, 'owned', (select count(*) from public.smoke_inv where user_id = u), 'shown', c.show,
    'live', lv, 'online', c.live_at is not null and c.live_at > now() - interval '15 seconds', 'od_left', od, 'self', u = auth.uid(),
    'rescuing', exists(select 1 from public.smoke_rescue r where r.target = u and r.rescuer = auth.uid()));
end $$;
revoke all on function public.smoke_live(text) from public, anon;
grant execute on function public.smoke_live(text) to authenticated;

-- le joueur constate lui-même son overdose (intoxication à 100 % et très au-dessus de sa limite) : possible seulement s'il vient de fumer
create or replace function public.smoke_od_start() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  perform public.rate_ok('smod', 10, 3600);
  if c.last_smoke is null or c.last_smoke < now() - interval '3 minutes' then raise exception 'Aucune bouffée récente'; end if;
  if c.od_start is null then update public.smoke_chars set od_start = now(), rescued_at = null where user_id = auth.uid() returning * into c; end if;
  return jsonb_build_object('od_left', greatest(0, round(120 - extract(epoch from now() - c.od_start))));
end $$;
revoke all on function public.smoke_od_start() from public, anon;
grant execute on function public.smoke_od_start() to authenticated;

-- sauvetage : démarrer (le visiteur est sur le profil pendant l'overdose), puis valider après le mini-jeu (30 s environ)
create or replace function public.smoke_rescue_start(p_username text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid; c public.smoke_chars;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('smresc', 30, 3600);
  select id into u from public.profiles where lower(username) = lower(btrim(coalesce(p_username,'')));
  if u is null or u = auth.uid() then raise exception 'Personnage introuvable'; end if;
  select * into c from public.smoke_chars where user_id = u for update;
  if not found or c.od_start is null or now() > c.od_start + interval '2 minutes' then raise exception 'Cette personne n’est pas en overdose'; end if;
  insert into public.smoke_rescue(target, rescuer) values (u, auth.uid()) on conflict (target, rescuer) do update set started = now();
  return jsonb_build_object('od_left', greatest(0, round(120 - extract(epoch from now() - c.od_start))));
end $$;
revoke all on function public.smoke_rescue_start(text) from public, anon;
grant execute on function public.smoke_rescue_start(text) to authenticated;

create or replace function public.smoke_rescue_done(p_username text, p_ok boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid; r public.smoke_rescue; c public.smoke_chars; el numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select id into u from public.profiles where lower(username) = lower(btrim(coalesce(p_username,'')));
  select * into r from public.smoke_rescue where target = u and rescuer = auth.uid() for update;
  if not found then raise exception 'Sauvetage non démarré'; end if;
  delete from public.smoke_rescue where target = u and rescuer = auth.uid();
  el := extract(epoch from now() - r.started);
  if not coalesce(p_ok, false) then return jsonb_build_object('saved', false); end if;
  if el < 20 then raise exception 'Réanimation trop rapide'; end if;
  select * into c from public.smoke_chars where user_id = u for update;
  if not found or c.od_start is null or now() > c.od_start + interval '2 minutes' then return jsonb_build_object('saved', false, 'late', true); end if;
  update public.smoke_chars set od_start = null, rescued_at = now() where user_id = u;
  return jsonb_build_object('saved', true);
end $$;
revoke all on function public.smoke_rescue_done(text, boolean) from public, anon;
grant execute on function public.smoke_rescue_done(text, boolean) to authenticated;
notify pgrst, 'reload schema';


-- ============================================================================
-- Lot 18f : pilules (familles Altos, Endormissants, Endo-Zacalins, Activants)
-- ============================================================================
create table if not exists public.smoke_pills (code text primary key, family text not null check (family in ('altos','endormissants','endozacalins','activants')), name text not null, price numeric not null check (price > 0),
  descr text not null, eff jsonb not null default '{}'::jsonb, dur int not null default 300 check (dur between 30 and 3600));
create table if not exists public.smoke_pill_inv (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.smoke_pills(code) on update cascade,
  qty int not null default 0 check (qty >= 0), known boolean not null default false, primary key (user_id, code));
alter table public.smoke_chars add column if not exists pills jsonb not null default '[]'::jsonb;
alter table public.smoke_pills enable row level security; alter table public.smoke_pill_inv enable row level security;
revoke all on public.smoke_pills, public.smoke_pill_inv from anon, authenticated;
insert into public.smoke_pills(code, family, name, price, descr, eff, dur) values
 ('altodemine','altos','Altodémine',300,'Réduit considérablement la paranoïa (-80).','{"par":0.8}',300),
 ('altodemine_x2','altos','Altodémine X2',700,'Réduit considérablement la paranoïa (-95).','{"par":0.95}',300),
 ('xanenomine','endormissants','Xanénomine',400,'Anesthésie temporairement le manque : aucune crise pendant 5 minutes.','{"nocrisis":1}',300),
 ('zicodaine','endormissants','Zicodaïne',500,'Augmente l’endurance (x1,3).','{"end":1.3}',300),
 ('utemadeine','endormissants','Utémadéïne',450,'Augmente la résistance aux intoxications pendant 3 minutes.','{"res":2.5}',180),
 ('garjonine','endormissants','Garjonine',450,'Augmente la limite de fumée en bouche (x1,6).','{"mouth":1.6}',300),
 ('bydrogene','endormissants','Bydrogène',350,'Atténue les effets de 40 %.','{"fx":0.6}',300),
 ('dibydrogene_alcalin','endormissants','Dibydrogène-Alcalin',600,'Ralentit l’augmentation de la dépendance.','{"dep":0.5}',300),
 ('garjo_dizicodaine','endozacalins','Garjo-Dizicodaïne',1200,'Endurance x1,45 et limite de fumée en bouche x1,45.','{"end":1.45,"mouth":1.45}',300),
 ('trizicodaine','endozacalins','Trizicodaïne',1500,'Augmente l’endurance (x1,6).','{"end":1.6}',300),
 ('tanzanine','activants','Tanzanine',900,'Augmente considérablement les effets de 40 %, même au-delà de la limite.','{"fx":1.4}',300)
on conflict (code) do update set family = excluded.family, name = excluded.name, price = excluded.price, descr = excluded.descr, eff = excluded.eff, dur = excluded.dur;

create or replace function public._sm_pills_active(p jsonb) returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', a->>'code', 'until', (a->>'until')::bigint, 'family', s.family, 'eff', s.eff) order by (a->>'until')::bigint), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p, '[]'::jsonb)) a join public.smoke_pills s on s.code = a->>'code'
  where (a->>'until')::bigint > (extract(epoch from now()) * 1000)::bigint $$;

create or replace function public._sm_depmul(p jsonb) returns numeric language sql stable set search_path = public as $$
  with a as (select * from jsonb_to_recordset(public._sm_pills_active(p)) as x(code text, until bigint, family text, eff jsonb))
  select coalesce(exp(sum(ln(coalesce((eff->>'dep')::numeric, 1)))), 1) * (case when exists(select 1 from a where family = 'activants') and exists(select 1 from a where family = 'endormissants') then 1.35 else 1 end) from a $$;

create or replace function public.smoke_pills_list() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  return jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0), 'active', public._sm_pills_active(c.pills),
    'pills', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'family', s.family, 'name', s.name, 'price', s.price, 'dur', s.dur, 'qty', coalesce(i.qty, 0), 'known', coalesce(i.known, false),
      'descr', case when coalesce(i.known, false) then s.descr else null end) order by case s.family when 'altos' then 1 when 'endormissants' then 2 when 'endozacalins' then 3 else 4 end, s.price)
      from public.smoke_pills s left join public.smoke_pill_inv i on i.code = s.code and i.user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_pills_list() from public, anon;
grant execute on function public.smoke_pills_list() to authenticated;

create or replace function public.smoke_pill_buy(p_code text, p_qty int) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_pills; b numeric; tot numeric; q int := coalesce(p_qty, 1);
begin
  perform public.rate_ok('smpill', 60, 3600);
  if q < 1 or q > 10 then raise exception 'Quantité de 1 à 10'; end if;
  select * into s from public.smoke_pills where code = p_code;
  if not found then raise exception 'Pilule inconnue'; end if;
  tot := s.price * q;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select balance into b from public.wallets where user_id = auth.uid() for update;
  if b < tot then raise exception 'Jetons insuffisants'; end if;
  perform public.tok_add(auth.uid(), -tot, 'achat pilule ' || s.name, null);
  perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, tot, 'achat pilule ' || s.name, null);
  insert into public.smoke_pill_inv(user_id, code, qty) values (auth.uid(), p_code, q) on conflict (user_id, code) do update set qty = public.smoke_pill_inv.qty + q;
  return jsonb_build_object('qty', (select qty from public.smoke_pill_inv where user_id = auth.uid() and code = p_code));
end $$;
revoke all on function public.smoke_pill_buy(text, int) from public, anon;
grant execute on function public.smoke_pill_buy(text, int) to authenticated;

create or replace function public.smoke_pill_take(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_pills; act jsonb;
begin
  perform public.rate_ok('smtake', 40, 600);
  select * into s from public.smoke_pills where code = p_code;
  if not found then raise exception 'Pilule inconnue'; end if;
  update public.smoke_pill_inv set qty = qty - 1, known = true where user_id = auth.uid() and code = p_code and qty > 0;
  if not found then raise exception 'Vous n’avez plus cette pilule'; end if;
  act := (select coalesce(jsonb_agg(jsonb_build_object('code', x->>'code', 'until', (x->>'until')::bigint)), '[]'::jsonb) from jsonb_array_elements(public._sm_pills_active(c.pills)) x);
  if jsonb_array_length(act) >= 12 then raise exception 'Trop de pilules actives (12 au maximum)'; end if;
  act := act || jsonb_build_object('code', p_code, 'until', (extract(epoch from now()) * 1000)::bigint + s.dur * 1000);
  update public.smoke_chars set pills = act where user_id = auth.uid();
  return jsonb_build_object('name', s.name, 'descr', s.descr, 'active', public._sm_pills_active(act));
end $$;
revoke all on function public.smoke_pill_take(text) from public, anon;
grant execute on function public.smoke_pill_take(text) to authenticated;

-- bouffée : la dépendance tient compte des pilules actives
create or replace function public.smoke_puff(p_code text, p_q numeric, p_ms int) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_items; q numeric := greatest(0, least(1, coalesce(p_q, 0))); gain numeric; nd numeric; ne numeric; pf numeric; lv int;
begin
  perform public.rate_ok('smpuff', 120, 60);
  if c.rehab_last is not null and c.rehab_last > now() - interval '60 seconds' then raise exception 'En réhabilitation : impossible de fumer'; end if;
  select * into s from public.smoke_items where code = p_code;
  if not found or not exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Objet non possédé'; end if;
  if coalesce(p_ms, 0) > public._sm_end(c.dep, c.endu) + 2500 then q := 0; end if;
  pf := least(s.power, 100) / 100.0 * (case when s.kind = 'cone' then 2.5 else 1 end);
  gain := pf * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  gain := gain * public._sm_depmul(c.pills);
  nd := least(100, c.dep + gain);
  ne := case when s.kind = 'cone' and q >= 0.2 then least(2050, c.endu + s.power / 50.0 * q) else c.endu end;
  update public.smoke_chars set dep = nd, endu = ne, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid() returning * into c;
  lv := public._sm_lvl_upd(c);
  return jsonb_build_object('dep', round(nd, 3), 'endu', ne, 'endurance_ms', public._sm_end(nd, ne), 'level', lv,
    'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - coalesce(c.last_smoke, now()))) end);
end $$;
revoke all on function public.smoke_puff(text, numeric, int) from public, anon;
grant execute on function public.smoke_puff(text, numeric, int) to authenticated;
notify pgrst, 'reload schema';

-- ============================================================================
-- Lot 18f-2 : 16 nouveaux effets (hallucinations et comportements)
-- ============================================================================
create or replace function public._sm_fx(p jsonb) returns jsonb language plpgsql immutable as $$
declare k text; o jsonb := '{}'; v numeric;
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Effets invalides'; end if;
  foreach k in array array['scr','mouse','delay','anim','warp','psy','obj','hal','fau','ill','scrl','blur','keys','coord','att',
      'chro','acou','echo','dist','hyper','lent','pers','bav','mut','imp','irr','eup','apa','mef','trem','susc'] loop
    v := coalesce((p->>k)::numeric, 0);
    if v < 0 or v > 1 then raise exception 'Chaque effet doit être entre 0 et 1'; end if;
    o := o || jsonb_build_object(k, round(v, 2));
  end loop;
  return o;
end $$;

-- objets du système : profils de nouveaux effets selon le type, proportionnels à la puissance
update public.smoke_items s set fx = s.fx || (
  select jsonb_object_agg(e.key, round(least(1, (e.value)::numeric * least(1, s.power / 60.0)), 2))
  from jsonb_each_text(case s.kind
    when 'vape' then '{"chro":0.6,"echo":0.5,"hyper":0.4,"eup":0.3,"trem":0.2,"bav":0.3,"acou":0.2}'::jsonb
    when 'cigarette' then '{"acou":0.5,"lent":0.5,"pers":0.4,"mef":0.5,"irr":0.4,"apa":0.2,"susc":0.3}'::jsonb
    when 'cigar' then '{"lent":0.7,"apa":0.5,"mut":0.4,"dist":0.5,"pers":0.3,"mef":0.3}'::jsonb
    when 'joint' then '{"eup":0.7,"chro":0.6,"echo":0.6,"dist":0.5,"bav":0.5,"imp":0.5,"acou":0.4,"hyper":0.5,"trem":0.3}'::jsonb
    else '{"chro":0.7,"acou":0.7,"echo":0.7,"dist":0.7,"hyper":0.7,"lent":0.7,"pers":0.7,"bav":0.7,"mut":0.3,"imp":0.7,"irr":0.7,"eup":0.7,"apa":0.3,"mef":0.7,"trem":0.7,"susc":0.7}'::jsonb end) as e(key, value))
where s.system and not (s.fx ? 'chro');

-- mode visible : nouvelles humeurs
create or replace function public.smoke_live_set(p_live jsonb) returns void language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); l jsonb := '{}'::jsonb; m text;
begin
  perform public.rate_ok('smlive', 120, 60);
  if p_live is null or jsonb_typeof(p_live) <> 'object' then raise exception 'État invalide'; end if;
  m := coalesce(p_live->>'mode', '');
  if m not in ('', 'smoke', 'exh', 'hold', 'cough', 'angry', 'sad', 'happy', 'apa', 'mef', 'od') then m := ''; end if;
  l := jsonb_build_object('mode', m,
    'ef', round(greatest(0, least(1.5, coalesce((p_live->>'ef')::numeric, 0))), 2),
    'par', round(greatest(0, least(1, coalesce((p_live->>'par')::numeric, 0))), 2),
    'crav', round(greatest(0, least(1, coalesce((p_live->>'crav')::numeric, 0))), 2),
    'tox', round(greatest(0, least(1, coalesce((p_live->>'tox')::numeric, 0))), 2),
    'ix', round(greatest(0, least(1, coalesce((p_live->>'ix')::numeric, 0))), 2),
    'bad', coalesce((p_live->>'bad')::boolean, false),
    'fx', coalesce((select jsonb_object_agg(k, round(least(1.5, greatest(0, v::numeric)), 2)) from jsonb_each_text(coalesce(p_live->'fx', '{}'::jsonb)) as e(k, v) where k ~ '^[a-z]{2,8}$' and v ~ '^[0-9.]+$'), '{}'::jsonb));
  update public.smoke_chars set live = l, live_at = now() where user_id = auth.uid();
end $$;
revoke all on function public.smoke_live_set(jsonb) from public, anon;
grant execute on function public.smoke_live_set(jsonb) to authenticated;
notify pgrst, 'reload schema';

-- ============================================================================
-- Lot 18g-1/2 : barre de base de 8 s, récompenses de niveau une seule fois, mort annoncée une fois, cimetière
-- ============================================================================
create or replace function public._sm_end(p_dep numeric, p_endu numeric) returns int language sql immutable as $f$ select 8000 + round(coalesce(p_dep, 0) * 20)::int + round(coalesce(p_endu, 0) * 4)::int $f$;

alter table public.smoke_deaths add column if not exists look jsonb not null default '{}'::jsonb;
alter table public.smoke_deaths add column if not exists stats jsonb not null default '{}'::jsonb;

create table if not exists public.smoke_flags (k text primary key);
alter table public.smoke_flags enable row level security; revoke all on public.smoke_flags from anon, authenticated;
-- une seule fois : les anciens morts ont déjà récupéré leurs récompenses
do $$ begin
  if not exists(select 1 from public.smoke_flags where k = 'lvl_claim_once') then
    update public.smoke_chars set lvl_claimed = greatest(lvl_claimed, lvl_top) where user_id in (select user_id from public.smoke_deaths);
    insert into public.smoke_flags(k) values ('lvl_claim_once');
  end if;
end $$;

create or replace function public._sm_die(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars; b numeric := 0; lost numeric := 0; it int; tk int; bp int; vz boolean;
begin
  select * into c from public.smoke_chars where user_id = p_user for update;
  if not found then return; end if;
  select coalesce(balance, 0) into b from public.wallets where user_id = p_user;
  lost := round(coalesce(b, 0) * 0.3, 1);
  if lost > 0 then perform public.tok_add(p_user, -lost, 'overdose : mauvais traitement', null); end if;
  select count(*) into it from public.smoke_inv where user_id = p_user;
  select count(*) into tk from public.smoke_trick_inv where user_id = p_user;
  select coalesce(max(s.power), 0) into bp from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = p_user;
  vz := public._has_vaze(p_user);
  insert into public.smoke_deaths(user_id, name, lost, look, stats) values (p_user, c.name, lost,
    jsonb_build_object('hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin),
    jsonb_build_object('dep', round(c.dep, 1), 'endu', round(c.endu, 1), 'endurance_ms', public._sm_end(c.dep, c.endu), 'level', c.lvl_top, 'puffs', c.puffs, 'items', it, 'tricks', tk, 'best_power', bp, 'vaze', vz,
      'born', c.created_at, 'lost', lost));
  delete from public.smoke_inv where user_id = p_user;
  delete from public.smoke_trick_inv where user_id = p_user;
  delete from public.smoke_pill_inv where user_id = p_user;
  delete from public.smoke_powder where user_id = p_user;
  delete from public.inventory where user_id = p_user and code = 'vaze_plus';
  delete from public.smoke_rescue where target = p_user;
  delete from public.smoke_chars where user_id = p_user;
  insert into public.smoke_chars(user_id, puffs, died_at, lvl_top, lvl_claimed) values (p_user, c.puffs, now(), c.lvl_top, greatest(c.lvl_claimed, c.lvl_claimed));
  insert into public.smoke_inv(user_id, code) values (p_user, 'vape_basic') on conflict do nothing;
end $$;
revoke all on function public._sm_die(uuid) from public, anon, authenticated;

create or replace function public.smoke_died_ack() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  update public.smoke_chars set died_at = null where user_id = auth.uid();
end $$;
revoke all on function public.smoke_died_ack() from public, anon;
grant execute on function public.smoke_died_ack() to authenticated;

create or replace function public.smoke_cemetery(p_limit int) returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'at') desc) from (
    select jsonb_build_object('name', d.name, 'username', (select username from public.profiles where id = d.user_id), 'at', d.at, 'look', d.look, 'stats', d.stats) as x
    from public.smoke_deaths d order by d.at desc limit greatest(1, least(coalesce(p_limit, 60), 200))) q), '[]'::jsonb);
end $$;
revoke all on function public.smoke_cemetery(int) from public, anon;
grant execute on function public.smoke_cemetery(int) to authenticated;
notify pgrst, 'reload schema';


-- ============================================================================
-- Lot 18g-3 : atelier VAZE+ v2 — effets par paliers, durée de vie, pilules en poudre, look, modèle dessiné, commandant sans limites
-- ============================================================================
alter table public.smoke_items add column if not exists life int check (life is null or life between 1 and 1000000);
alter table public.smoke_items add column if not exists look jsonb not null default '{}'::jsonb;
alter table public.smoke_items add column if not exists content jsonb not null default '[]'::jsonb;
alter table public.smoke_items add column if not exists prod_cost numeric not null default 0;
alter table public.smoke_items add column if not exists pill_cost numeric not null default 0;
alter table public.smoke_items add column if not exists free boolean not null default false;
alter table public.smoke_inv add column if not exists puffs_left int;
alter table public.smoke_items drop constraint if exists smoke_items_power_check;
alter table public.smoke_items add constraint smoke_items_power_check check (power between 1 and 5000);
create table if not exists public.smoke_powder (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.smoke_pills(code) on update cascade,
  qty int not null default 0 check (qty >= 0), primary key (user_id, code));
alter table public.smoke_powder enable row level security; revoke all on public.smoke_powder from anon, authenticated;

-- prix des paliers d'effet : 10 paliers par effet, de 1 jeton à 200 jetons pour le dernier
create or replace function public._sm_fx2(p jsonb, cmd boolean) returns jsonb language plpgsql immutable as $f$
declare k text; o jsonb := '{}'; v numeric;
begin
  if not cmd then return public._sm_fx(p); end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Effets invalides'; end if;
  foreach k in array array['scr','mouse','delay','anim','warp','psy','obj','hal','fau','ill','scrl','blur','keys','coord','att',
      'chro','acou','echo','dist','hyper','lent','pers','bav','mut','imp','irr','eup','apa','mef','trem','susc'] loop
    v := coalesce((p->>k)::numeric, 0);
    if v < 0 or v > 100 then raise exception 'Chaque effet doit être entre 0 et 10000 %%'; end if;
    o := o || jsonb_build_object(k, round(v, 2));
  end loop;
  return o;
end $f$;
create or replace function public._sm_stepcost(v numeric) returns numeric language sql immutable as $f$
  select coalesce(sum(c), 0) from unnest(array[1,2,3,5,9,16,30,55,100,200]) with ordinality as t(c, i) where i <= round(coalesce(v, 0) * 10) $f$;
create or replace function public._sm_prod(p_fx jsonb) returns numeric language sql immutable as $f$
  select coalesce(sum(public._sm_stepcost(v::numeric)), 0) from jsonb_each_text(p_fx) as e(k, v) where k <> 'smoke' $f$;

create or replace function public._sm_smoke2(p jsonb, cmd boolean) returns jsonb language plpgsql immutable as $$
declare col text := coalesce(p->>'color', '#ffffff'); d numeric := coalesce((p->>'density')::numeric, 1); s numeric := coalesce((p->>'size')::numeric, 1); v numeric := coalesce((p->>'speed')::numeric, 1);
begin
  if not cmd then return public._sm_smoke(p); end if;
  if p is not null and jsonb_typeof(p) <> 'object' then raise exception 'Fumée invalide'; end if;
  if col !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur de fumée invalide'; end if;
  if d < 0.05 or d > 30 or s < 0.1 or s > 30 or v < 0.1 or v > 30 then raise exception 'Densité, taille et vitesse de fumée : de 0,05 à 30'; end if;
  return jsonb_build_object('color', lower(col), 'density', round(d, 2), 'size', round(s, 2), 'speed', round(v, 2));
end $$;

create or replace function public._sm_look(p jsonb) returns jsonb language plpgsql immutable as $$
declare o jsonb := '{}'::jsonb; m jsonb; k text;
begin
  if p is null or p = 'null'::jsonb then return o; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'Apparence invalide'; end if;
  foreach k in array array['body','tip'] loop
    if p ? k then
      if (p->>k) !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
      o := o || jsonb_build_object(k, lower(p->>k));
    end if;
  end loop;
  if p ? 'model' and jsonb_typeof(p->'model') = 'object' then
    m := p->'model';
    if coalesce(m->>'idle','') !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$' or coalesce(m->>'smoke','') !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$' then raise exception 'Images du modèle invalides'; end if;
    if length(m->>'idle') > 60000 or length(m->>'smoke') > 60000 then raise exception 'Image trop lourde (60 000 caractères au maximum)'; end if;
    if jsonb_typeof(m->'mouth') <> 'array' or jsonb_array_length(m->'mouth') <> 2 or jsonb_typeof(m->'tip') <> 'array' or jsonb_array_length(m->'tip') <> 2 then raise exception 'Positions de la bouche et du bout manquantes'; end if;
    if (m->'mouth'->>0)::numeric not between 0 and 1 or (m->'mouth'->>1)::numeric not between 0 and 1 or (m->'tip'->>0)::numeric not between 0 and 1 or (m->'tip'->>1)::numeric not between 0 and 1 then raise exception 'Positions hors de l’image'; end if;
    o := o || jsonb_build_object('model', jsonb_build_object('idle', m->>'idle', 'smoke', m->>'smoke', 'mouth', m->'mouth', 'tip', m->'tip'));
  end if;
  return o;
end $$;

create or replace function public._sm_def(p_code text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('code', i.code, 'kind', i.kind, 'name', i.name, 'price', i.price, 'power', i.power, 'fx', i.fx, 'smoke', i.smoke, 'life', i.life, 'look', i.look, 'free', i.free,
    'content', coalesce((select jsonb_agg(jsonb_build_object('pill', e->>'pill', 'n', (e->>'n')::int, 'eff', p.eff, 'family', p.family)) from jsonb_array_elements(i.content) e join public.smoke_pills p on p.code = e->>'pill'), '[]'::jsonb))
  from public.smoke_items i where i.code = p_code $$;
revoke all on function public._sm_def(text) from public, anon, authenticated;

create or replace function public.smoke_shop() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0), 'vaze', public._has_vaze(auth.uid()), 'cmd', public.staff_rank_me() >= 4,
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'kind', s.kind, 'name', s.name, 'price', s.price, 'power', s.power, 'fx', s.fx, 'smoke', s.smoke, 'active', s.active, 'system', s.system,
        'life', s.life, 'look', s.look, 'free', s.free,
        'owned', exists(select 1 from public.smoke_inv i where i.user_id = auth.uid() and i.code = s.code), 'left', (select i.puffs_left from public.smoke_inv i where i.user_id = auth.uid() and i.code = s.code),
        'mine', s.creator = auth.uid(), 'sold', s.sold,
        'content', case when s.creator = auth.uid() then s.content else null end, 'prod_cost', case when s.creator = auth.uid() then s.prod_cost else null end, 'pill_cost', case when s.creator = auth.uid() then s.pill_cost else null end,
        'by', case when s.system then null else (select username from public.profiles where id = s.creator) end) order by s.system desc, s.price, s.name)
      from public.smoke_items s where s.active or s.creator = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_shop() from public, anon;
grant execute on function public.smoke_shop() to authenticated;

-- poudres
create or replace function public.smoke_powder_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return jsonb_build_object('cmd', public.staff_rank_me() >= 4, 'powders', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'family', p.family,
      'qty', case when public.staff_rank_me() >= 4 then 99999 else coalesce(w.qty, 0) end) order by p.family, p.price)
    from public.smoke_pills p left join public.smoke_powder w on w.code = p.code and w.user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_powder_list() from public, anon;
grant execute on function public.smoke_powder_list() to authenticated;

create or replace function public.smoke_pill_crush(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  perform public.rate_ok('smcrush', 120, 3600);
  update public.smoke_pill_inv set qty = qty - 1 where user_id = auth.uid() and code = p_code and qty > 0;
  if not found then raise exception 'Vous n’avez pas cette pilule'; end if;
  insert into public.smoke_powder(user_id, code, qty) values (auth.uid(), p_code, 1) on conflict (user_id, code) do update set qty = public.smoke_powder.qty + 1;
  return jsonb_build_object('qty', (select qty from public.smoke_powder where user_id = auth.uid() and code = p_code));
end $$;
revoke all on function public.smoke_pill_crush(text) from public, anon;
grant execute on function public.smoke_pill_crush(text) to authenticated;

-- création / modification complète d'un objet de fumeur (VAZE+ ; le commandant n'a aucune restriction)
create or replace function public.smoke_item_save(p_code text, p_name text, p_kind text, p_price numeric, p_life int, p_power int, p_fx jsonb, p_look jsonb, p_content jsonb, p_active boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare cmd boolean := public.staff_rank_me() >= 4; n text := btrim(coalesce(p_name, '')); vfx jsonb; pw int; sm jsonb; lk jsonb; ct jsonb := '[]'::jsonb; e jsonb; pc numeric := 0; c text; old public.smoke_items;
        v numeric; k text; life int; pr numeric; oldn int; newn int; pl public.smoke_pills; pp numeric; cnt int := 0;
begin
  perform public._sm_row();
  if not (cmd or public._has_vaze(auth.uid())) then raise exception 'Il faut le pass VAZE+'; end if;
  perform public.rate_ok('smsave', 80, 3600);
  if char_length(n) < 3 or char_length(n) > 30 then raise exception 'Nom de 3 à 30 caractères'; end if;
  if p_kind not in ('vape','cigar','cigarette','joint') then raise exception 'Type inconnu'; end if;
  pr := p_price;
  if cmd then if pr is null or pr < 0 or pr > 99999999 then raise exception 'Prix invalide'; end if;
  else if pr is null or pr < 10 or pr > 100000 or pr <> round(pr, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if; end if;
  if cmd then life := case when coalesce(p_life, 0) <= 0 then null else least(p_life, 1000000) end;
  else if p_life is null or p_life < 50 or p_life > 600 then raise exception 'Durée de vie de 50 à 600 bouffées'; end if; life := p_life; end if;
  vfx := public._sm_fx2(p_fx, cmd);
  if not cmd then
    for k, v in select key, value::numeric from jsonb_each_text(vfx) loop
      if abs(v * 10 - round(v * 10)) > 0.001 then raise exception 'Les effets s’achètent par paliers de 10 %%'; end if;
    end loop;
    pw := public._sm_power(vfx);
  else
    if p_power is null or p_power < 1 or p_power > 5000 then raise exception 'Puissance de 1 à 5000'; end if; pw := p_power;
  end if;
  sm := public._sm_smoke2(p_fx->'smoke', cmd);
  lk := public._sm_look(p_look);
  if p_content is not null and jsonb_typeof(p_content) <> 'array' then raise exception 'Contenu invalide'; end if;
  if p_code is not null then
    select * into old from public.smoke_items where code = p_code and creator = auth.uid() and not system for update;
    if not found then raise exception 'Objet introuvable'; end if;
  elsif not cmd and (select count(*) from public.smoke_items where creator = auth.uid()) >= 20 then raise exception '20 objets au maximum'; end if;
  for e in select * from jsonb_array_elements(coalesce(p_content, '[]'::jsonb)) loop
    cnt := cnt + 1;
    if cnt > 8 then raise exception '8 molécules au maximum par objet'; end if;
    select * into pl from public.smoke_pills where code = e->>'pill';
    if not found then raise exception 'Pilule inconnue'; end if;
    newn := coalesce((e->>'n')::int, 0);
    if newn < 1 or newn > (case when cmd then 9999 else 20 end) then raise exception 'Quantité de pilules invalide'; end if;
    if exists(select 1 from jsonb_array_elements(ct) x where x->>'pill' = pl.code) then raise exception 'Molécule en double'; end if;
    ct := ct || jsonb_build_object('pill', pl.code, 'n', newn);
    pc := pc + newn * round(pl.price / 4.0, 1);
    if not cmd then
      oldn := coalesce((select (x->>'n')::int from jsonb_array_elements(case when p_code is not null then old.content else '[]'::jsonb end) x where x->>'pill' = pl.code), 0);
      if newn > oldn then
        update public.smoke_powder set qty = qty - (newn - oldn) where user_id = auth.uid() and code = pl.code and qty >= (newn - oldn);
        if not found then raise exception 'Pas assez de poudre de %', pl.name; end if;
      elsif newn < oldn then
        insert into public.smoke_powder(user_id, code, qty) values (auth.uid(), pl.code, oldn - newn) on conflict (user_id, code) do update set qty = public.smoke_powder.qty + (oldn - newn);
      end if;
    end if;
  end loop;
  if not cmd and p_code is not null then
    for e in select * from jsonb_array_elements(old.content) loop
      if not exists(select 1 from jsonb_array_elements(ct) x where x->>'pill' = e->>'pill') then
        insert into public.smoke_powder(user_id, code, qty) values (auth.uid(), e->>'pill', (e->>'n')::int) on conflict (user_id, code) do update set qty = public.smoke_powder.qty + (e->>'n')::int;
      end if;
    end loop;
  end if;
  if p_code is null then
    c := 'u' || substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 1, 10);
    insert into public.smoke_items(code, kind, name, price, power, fx, smoke, creator, life, look, content, prod_cost, pill_cost, free, active)
      values (c, p_kind, n, pr, pw, vfx, sm, auth.uid(), life, lk, ct, case when cmd then 0 else public._sm_prod(vfx) end, case when cmd then 0 else pc end, cmd, coalesce(p_active, true));
    insert into public.smoke_inv(user_id, code, puffs_left) values (auth.uid(), c, life);
  else
    c := p_code;
    update public.smoke_items set price = pr, power = pw, fx = vfx, smoke = sm, life = life, look = lk, content = ct, prod_cost = case when cmd then 0 else public._sm_prod(vfx) end,
      pill_cost = case when cmd then 0 else pc end, free = cmd, active = coalesce(p_active, true) where code = c;
  end if;
  return public._sm_def(c) || jsonb_build_object('prod_cost', case when cmd then 0 else public._sm_prod(vfx) end, 'pill_cost', case when cmd then 0 else pc end);
end $$;
revoke all on function public.smoke_item_save(text, text, text, numeric, int, int, jsonb, jsonb, jsonb, boolean) from public, anon;
grant execute on function public.smoke_item_save(text, text, text, numeric, int, int, jsonb, jsonb, jsonb, boolean) to authenticated;

-- achat : le vendeur paie le coût de production et les pilules (prix / 4), puis encaisse la vente ; durée de vie en bouffées
create or replace function public.smoke_buy(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.smoke_items; b numeric; net numeric; cost numeric; sb numeric; pl int;
begin
  perform public._sm_row();
  perform public.rate_ok('smbuy', 40, 3600);
  select * into s from public.smoke_items where code = p_code for update;
  if not found or not s.active then raise exception 'Objet indisponible'; end if;
  select puffs_left into pl from public.smoke_inv where user_id = auth.uid() and code = p_code;
  if found then
    if s.life is null then raise exception 'Déjà possédé'; end if;
    if coalesce(pl, 0) > 0 then raise exception 'Il vous reste encore % bouffées sur cet objet', pl; end if;
  end if;
  if s.price > 0 then
    insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
    select balance into b from public.wallets where user_id = auth.uid() for update;
    if b < s.price then raise exception 'Jetons insuffisants'; end if;
    cost := case when s.creator is null or s.free or s.creator = auth.uid() then 0 else s.prod_cost + s.pill_cost end;
    if cost > 0 then
      select coalesce(balance, 0) into sb from public.wallets where user_id = s.creator for update;
      if coalesce(sb, 0) < cost then raise exception 'Cet objet est momentanément indisponible (le vendeur n’a pas de quoi le produire)'; end if;
      perform public.tok_add(s.creator, -cost, 'production ' || s.name, null);
      perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, cost, 'production ' || s.name, null);
    end if;
    perform public.tok_add(auth.uid(), -s.price, 'achat ' || s.name, null);
    if s.creator is not null and s.creator <> auth.uid() then
      net := round(s.price * 0.9, 1);
      perform public.tok_add(s.creator, net, 'vente ' || s.name, null);
      perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, s.price - net, 'frais de vente ' || s.name, null);
    else
      perform public.tok_add('aaaaaaaa-0000-4000-8000-000000000001'::uuid, s.price, 'achat ' || s.name, null);
    end if;
  end if;
  insert into public.smoke_inv(user_id, code, puffs_left) values (auth.uid(), p_code, s.life)
    on conflict (user_id, code) do update set puffs_left = s.life, bought_at = now();
  update public.smoke_items set sold = sold + 1 where code = p_code;
  return public._sm_def(p_code) || jsonb_build_object('left', s.life);
end $$;
revoke all on function public.smoke_buy(text) from public, anon;
grant execute on function public.smoke_buy(text) to authenticated;

-- état : bouffées restantes par objet
create or replace function public.smoke_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); n int;
begin
  n := public._sm_lvl_upd(c);
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', c.item, 'show', c.show,
    'dep', round(c.dep, 3), 'endu', c.endu, 'endurance_ms', public._sm_end(c.dep, c.endu), 'puffs', c.puffs, 'level', n, 'lvl_claimed', c.lvl_claimed,
    'since_s', case when c.last_smoke is null then null else round(extract(epoch from now() - c.last_smoke)) end,
    'od_left', case when c.od_start is null then null else greatest(0, round(120 - extract(epoch from now() - c.od_start))) end,
    'rescued_s', case when c.rescued_at is null then null else round(extract(epoch from now() - c.rescued_at)) end,
    'died_s', case when c.died_at is null then null else round(extract(epoch from now() - c.died_at)) end,
    'vaze', public._has_vaze(auth.uid()), 'cmd', public.staff_rank_me() >= 4, 'pills', public._sm_pills_active(c.pills),
    'owned', coalesce((select jsonb_agg(public._sm_def(i.code) || jsonb_build_object('left', i.puffs_left) order by s.price) from public.smoke_inv i join public.smoke_items s on s.code = i.code where i.user_id = auth.uid()), '[]'::jsonb),
    'tricks', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'uses', uses) order by code) from public.smoke_trick_inv where user_id = auth.uid()), '[]'::jsonb));
end $$;
revoke all on function public.smoke_state() from public, anon;
grant execute on function public.smoke_state() to authenticated;

-- bouffée : décompte de la durée de vie, molécules du contenu découvertes
create or replace function public.smoke_puff(p_code text, p_q numeric, p_ms int) returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row(); s public.smoke_items; q numeric := greatest(0, least(1, coalesce(p_q, 0))); gain numeric; nd numeric; ne numeric; pf numeric; lv int;
begin
  perform public.rate_ok('smpuff', 120, 60);
  if c.rehab_last is not null and c.rehab_last > now() - interval '60 seconds' then raise exception 'En réhabilitation : impossible de fumer'; end if;
  select * into s from public.smoke_items where code = p_code;
  if s.life is not null then
    update public.smoke_inv set puffs_left = puffs_left - 1 where user_id = auth.uid() and code = p_code and coalesce(puffs_left, 0) > 0;
    if not found then raise exception 'Plus de bouffées : rachetez cet objet'; end if;
    insert into public.smoke_pill_inv(user_id, code, qty, known) select auth.uid(), e->>'pill', 0, true from jsonb_array_elements(s.content) e on conflict (user_id, code) do update set known = true;
  end if;
  if not found or not exists(select 1 from public.smoke_inv where user_id = auth.uid() and code = p_code) then raise exception 'Objet non possédé'; end if;
  if coalesce(p_ms, 0) > public._sm_end(c.dep, c.endu) + 2500 then q := 0; end if;
  pf := least(s.power, 100) / 100.0 * (case when s.kind = 'cone' then 2.5 else 1 end);
  gain := pf * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  gain := gain * public._sm_depmul(c.pills);
  nd := least(100, c.dep + gain);
  ne := case when s.kind = 'cone' and q >= 0.2 then least(2050, c.endu + s.power / 50.0 * q) else c.endu end;
  update public.smoke_chars set dep = nd, endu = ne, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid() returning * into c;
  lv := public._sm_lvl_upd(c);
  return jsonb_build_object('left', (select puffs_left from public.smoke_inv where user_id = auth.uid() and code = p_code), 'dep', round(nd, 3), 'endu', ne, 'endurance_ms', public._sm_end(nd, ne), 'level', lv,
    'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - coalesce(c.last_smoke, now()))) end);
end $$;
revoke all on function public.smoke_puff(text, numeric, int) from public, anon;
grant execute on function public.smoke_puff(text, numeric, int) to authenticated;
notify pgrst, 'reload schema';
