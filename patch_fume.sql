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
  foreach k in array array['scr','mouse','delay','anim','warp','psy','obj','hal','fau','ill'] loop
    v := coalesce((p->>k)::numeric, 0);
    if v < 0 or v > 1 then raise exception 'Chaque effet doit être entre 0 et 1'; end if;
    o := o || jsonb_build_object(k, round(v, 2));
  end loop;
  return o;
end $$;

create or replace function public._sm_row() returns public.smoke_chars language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars; d numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.smoke_chars(user_id) values (auth.uid()) on conflict do nothing;
  insert into public.smoke_inv(user_id, code) values (auth.uid(), 'vape_basic') on conflict do nothing;
  select * into c from public.smoke_chars where user_id = auth.uid() for update;
  d := greatest(0, c.dep - 6 * extract(epoch from now() - c.dep_at) / 3600);
  if d <> c.dep or c.dep_at < now() - interval '1 minute' then update public.smoke_chars set dep = d, dep_at = now() where user_id = auth.uid() returning * into c; end if;
  return c;
end $$;
revoke all on function public._sm_row() from public, anon, authenticated;

create or replace function public._sm_def(p_code text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('code', code, 'kind', kind, 'name', name, 'price', price, 'power', power, 'fx', fx) from public.smoke_items where code = p_code $$;
revoke all on function public._sm_def(text) from public, anon, authenticated;

-- ---------- état du personnage ----------
create or replace function public.smoke_state() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', c.item, 'show', c.show,
    'dep', round(c.dep, 3), 'endurance_ms', 2000 + round(c.dep * 40)::int, 'puffs', c.puffs,
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
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'kind', s.kind, 'name', s.name, 'price', s.price, 'power', s.power, 'fx', s.fx, 'active', s.active, 'system', s.system,
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
  if coalesce(p_ms, 0) > 2000 + round(c.dep * 40) + 1500 then q := 0; end if;
  gain := s.power / 100.0 * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  nd := least(100, c.dep + gain);
  update public.smoke_chars set dep = nd, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid();
  return jsonb_build_object('dep', round(nd, 3), 'endurance_ms', 2000 + round(nd * 40)::int, 'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - c.last_smoke)) end);
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
  return jsonb_build_object('name', c.name, 'hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'dep', round(d, 1), 'endurance_ms', 2000 + round(d * 40)::int,
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
    'dep', round(c.dep, 3), 'endurance_ms', 2000 + round(c.dep * 40)::int, 'puffs', c.puffs,
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
  return jsonb_build_object('dep', round(nd, 3), 'endurance_ms', 2000 + round(nd * 40)::int, 'active', true);
end $$;
create or replace function public.smoke_rehab_stop() returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.smoke_chars := public._sm_row();
begin
  update public.smoke_chars set rehab_last = null where user_id = auth.uid();
  return jsonb_build_object('dep', round(c.dep, 3), 'endurance_ms', 2000 + round(c.dep * 40)::int);
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
  if coalesce(p_ms, 0) > 2000 + round(c.dep * 40) + 2500 then q := 0; end if;
  gain := s.power / 100.0 * (case when q >= 0.2 then 6 * (0.4 + 0.6 * q) else 1.2 end);
  nd := least(100, c.dep + gain);
  update public.smoke_chars set dep = nd, dep_at = now(), item = p_code, puffs = puffs + 1, last_smoke = case when q >= 0.2 then now() else last_smoke end where user_id = auth.uid();
  return jsonb_build_object('dep', round(nd, 3), 'endurance_ms', 2000 + round(nd * 40)::int, 'since_s', case when q >= 0.2 then 0 else round(extract(epoch from now() - c.last_smoke)) end);
end $$;
revoke all on function public.smoke_puff(text, numeric, int) from public, anon;
grant execute on function public.smoke_puff(text, numeric, int) to authenticated;
notify pgrst, 'reload schema';
