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
declare n text := btrim(coalesce(p_name,'')); c text; fx jsonb;
begin
  perform public._sm_row();
  if not public._has_vaze(auth.uid()) then raise exception 'Il faut le pass VAZE+'; end if;
  perform public.rate_ok('smnew', 30, 3600);
  if char_length(n) < 3 or char_length(n) > 30 then raise exception 'Nom de 3 à 30 caractères'; end if;
  if p_kind not in ('vape','cigar','cigarette','joint') then raise exception 'Type inconnu'; end if;
  if p_price is null or p_price < 10 or p_price > 100000 or p_price <> round(p_price, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if;
  if (select count(*) from public.smoke_items where creator = auth.uid()) >= 20 then raise exception '20 objets au maximum'; end if;
  fx := public._sm_fx(p_fx);
  c := 'u' || substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 1, 10);
  insert into public.smoke_items(code, kind, name, price, power, fx, smoke, creator) values (c, p_kind, n, p_price, public._sm_power(fx), fx, public._sm_smoke(p_fx->'smoke'), auth.uid());
  insert into public.smoke_inv(user_id, code) values (auth.uid(), c);
  return public._sm_def(c);
end $$;
revoke all on function public.smoke_item_create(text, text, numeric, int, jsonb) from public, anon;
grant execute on function public.smoke_item_create(text, text, numeric, int, jsonb) to authenticated;

create or replace function public.smoke_item_update(p_code text, p_price numeric, p_power int, p_fx jsonb, p_active boolean) returns void language plpgsql security definer set search_path = public as $$
declare fx jsonb;
begin
  perform public._sm_row();
  if not exists(select 1 from public.smoke_items where code = p_code and creator = auth.uid() and not system) then raise exception 'Objet introuvable'; end if;
  if p_price is null or p_price < 10 or p_price > 100000 or p_price <> round(p_price, 1) then raise exception 'Prix entre 10 et 100 000 jetons'; end if;
  fx := public._sm_fx(p_fx);
  update public.smoke_items set price = p_price, power = public._sm_power(fx), fx = fx, smoke = public._sm_smoke(p_fx->'smoke'), active = coalesce(p_active, true) where code = p_code;
end $$;
revoke all on function public.smoke_item_update(text, numeric, int, jsonb, boolean) from public, anon;
grant execute on function public.smoke_item_update(text, numeric, int, jsonb, boolean) to authenticated;
notify pgrst, 'reload schema';
