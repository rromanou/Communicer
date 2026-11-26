-- ============================================================================
-- Communicer! — patch_casino.sql (additif, relançable) : casino en ligne (poker, blackjack, roulette,
-- machines à sous) et loterie Lot-Au-MAX! (Zimemberg, Tanhgokrom, Tomateeom, Poutinà).
-- Dépend de patch_jetons_v2, patch_apparence, patch_fume.
-- Tout le hasard est tiré côté serveur (gen_random_bytes). Aucune table n'est lisible par le client :
-- tout passe par des fonctions RPC (security definer). Les jetons passent par tok_add (« casino : … »).
-- ============================================================================

-- ---------- A) Configuration, secrets, banque de la maison ----------
create table if not exists public.casino_cfg (k text primary key, v text not null);
create table if not exists public.casino_secret (k text primary key, v text not null);
create table if not exists public.casino_bank (id bigint generated always as identity primary key, delta numeric(16,1) not null, reason text, at timestamptz not null default now());
alter table public.casino_cfg enable row level security;
alter table public.casino_secret enable row level security;
alter table public.casino_bank enable row level security;
revoke all on public.casino_cfg, public.casino_secret, public.casino_bank from anon, authenticated;

insert into public.casino_cfg(k, v) values
 -- horloge de test (secondes ajoutées à l'heure serveur) : toujours 0 en production
 ('test_clock_offset_s', '0'),
 -- poker
 ('poker_bb', '10'), ('poker_buyin_min', '200'), ('poker_buyin_max', '2000'), ('poker_act_s', '20'), ('poker_showdown_s', '6'),
 ('poker_between_s', '5'), ('poker_start_s', '3'), ('poker_runout_s', '2'), ('poker_dealer_stack', '2000'),
 -- blackjack
 ('bj_min', '10'), ('bj_max', '1000'), ('bj_bet_s', '15'), ('bj_play_s', '15'), ('bj_deal_s', '2'), ('bj_payout_s', '6'), ('bj_dealer_step_s', '1'),
 -- roulette
 ('rl_min', '5'), ('rl_max', '500'), ('rl_bet_s', '25'), ('rl_spin_s', '8'), ('rl_result_s', '6'),
 -- bots et sièges
 ('bot_min_delay_ms', '1000'), ('bot_max_delay_ms', '3000'), ('bot_max', '4'), ('bot_vote_pct', '70'), ('seat_idle_s', '120'),
 -- triche au poker
 ('cheat_ignore_block', '0'), ('cheat_cooldown_s', '60'), ('cheat_secs', '20'), ('cheat_need', '70'), ('cheat_bot_p', '0.35'), ('cheat_max_cps', '12'),
 -- machines à sous
 ('slot_rate_per_min', '90'),
 -- Lot-Au-MAX!
 ('lot_min_price', '5'), ('lot_price_pct', '0.25'), ('lot_pot_pct', '0.7'), ('lot_fake_p', '0.001'), ('zim_win_p', '0.0002'), ('zim_slot_s', '213'),
 ('zim_wrong_penalty', 'all'), ('zim_min_ahead_s', '600'), ('zim_max_ahead_s', '259200'),
 ('tom_p_ticket', '0.025'), ('tom_p_25', '0.018'), ('tom_p_50', '0.01'), ('tom_p_500', '0.0025'), ('tom_p_10000', '0.0002'), ('tom_p_25000', '0.00005'),
 ('pou_possible_p', '0.002'), ('pou_colors_dist', '6:70,7:20,8:7,9:2,10:0.7,11:0.3')
on conflict (k) do nothing;

create or replace function public._casino_cc(p_k text) returns text language sql stable security definer set search_path = public, extensions as $$
  select v from public.casino_cfg where k = p_k $$;
create or replace function public._casino_ccn(p_k text) returns numeric language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select v::numeric from public.casino_cfg where k = p_k), 0) $$;
-- heure du casino (horloge de test réglable ; offset = 0 en production)
create or replace function public._casino_now() returns timestamptz language sql volatile security definer set search_path = public, extensions as $$
  select clock_timestamp() + make_interval(secs => coalesce((select v::numeric from public.casino_cfg where k = 'test_clock_offset_s'), 0)::double precision) $$;

-- secrets (clé de chiffrement des billets, clé HMAC) créés au premier usage
create or replace function public._casino_key(p_k text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare v text;
begin
  select s.v into v from public.casino_secret s where s.k = p_k;
  if v is null then
    insert into public.casino_secret(k, v) values (p_k, encode(gen_random_bytes(32), 'hex')) on conflict do nothing;
    select s.v into v from public.casino_secret s where s.k = p_k;
  end if;
  return v;
end $$;

-- mouvement de la banque (positif = la banque encaisse, négatif = la banque paie)
create or replace function public._casino_bank(p_delta numeric, p_reason text) returns void language sql security definer set search_path = public, extensions as $$
  insert into public.casino_bank(delta, reason) select p_delta, left(p_reason, 120) where p_delta <> 0 $$;

-- ---------- B) Hasard serveur ----------
-- entier uniforme 0..n-1 (rejet pour éviter le biais du modulo)
create or replace function public._casino_rand(n int) returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare lim bigint; x bigint; b bytea;
begin
  if n <= 1 then return 0; end if;
  lim := 4294967296 - (4294967296 % n);
  loop
    b := gen_random_bytes(4);
    x := get_byte(b, 0)::bigint * 16777216 + get_byte(b, 1) * 65536 + get_byte(b, 2) * 256 + get_byte(b, 3);
    exit when x < lim;
  end loop;
  return (x % n)::int;
end $$;
-- réel uniforme [0,1) sur 48 bits
create or replace function public._casino_rfloat() returns double precision language plpgsql volatile security definer set search_path = public, extensions as $$
declare b bytea := gen_random_bytes(6);
begin
  return ((get_byte(b,0)::bigint << 40) + (get_byte(b,1)::bigint << 32) + (get_byte(b,2)::bigint << 24) + (get_byte(b,3)::bigint << 16) + (get_byte(b,4)::bigint << 8) + get_byte(b,5))::double precision / 281474976710656;
end $$;
-- chaîne aléatoire sur un alphabet
create or replace function public._casino_rstr(p_len int, p_alpha text default 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare s text := ''; i int; n int := length(p_alpha);
begin
  for i in 1..p_len loop s := s || substr(p_alpha, _casino_rand(n) + 1, 1); end loop;
  return s;
end $$;
-- mélange de Fisher-Yates
create or replace function public._casino_shuffle(a text[]) returns text[] language plpgsql volatile security definer set search_path = public, extensions as $$
declare i int; j int; t text; n int := coalesce(array_length(a, 1), 0);
begin
  for i in reverse n..2 loop
    j := _casino_rand(i) + 1;
    t := a[i]; a[i] := a[j]; a[j] := t;
  end loop;
  return a;
end $$;
create or replace function public._casino_deck(p_decks int default 1) returns text[] language plpgsql volatile security definer set search_path = public, extensions as $$
declare d text[] := '{}'; r text; s text; k int;
begin
  for k in 1..p_decks loop
    foreach r in array array['2','3','4','5','6','7','8','9','T','J','Q','K','A'] loop
      foreach s in array array['s','h','d','c'] loop d := d || (r || s); end loop;
    end loop;
  end loop;
  return _casino_shuffle(d);
end $$;

-- ---------- C) Noms et apparences ----------
create or replace function public._casino_bot_name() returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare n text[] := array['Marc-André','Sophie','Luc','Mélanie','Étienne','Jasmin','Catherine','Gaston','Mireille','Raphaël','Noémie','Frédéric','Annick','Olivier','Brigitte','Maxime','Cécile','Yannick','Josée','Dominique','Alexis','Isabelle','Simon','Valérie'];
begin return n[_casino_rand(array_length(n, 1)) + 1]; end $$;
create or replace function public._casino_look_random(p_outfit text default null) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  hair text[] := array['court','longs','frange','chignon','tresses','cret','afro','chauve'];
  hcs text[] := array['#3b2a1d','#1c1c1c','#8a5a2b','#d9b44a','#b0452a','#9aa0a6'];
  eyes text[] := array['ronds','fins','grands','endormis','joyeux'];
  ecs text[] := array['#2a1d12','#2d5b8a','#3b7a3b','#6b4a2b','#5a5a5a'];
  skins text[] := array['#f1c9a5','#e0ac82','#c68642','#8d5524','#f5d7c0'];
  items text[] := array['vape','cigar','cigarette','joint'];
  it text;
begin
  if p_outfit is null and _casino_rand(3) = 0 then it := items[_casino_rand(4) + 1]; end if;
  return jsonb_build_object('hair', hair[_casino_rand(8) + 1], 'hc', hcs[_casino_rand(6) + 1], 'eyes', eyes[_casino_rand(5) + 1],
    'ec', ecs[_casino_rand(5) + 1], 'skin', skins[_casino_rand(5) + 1], 'item', it, 'outfit', p_outfit);
end $$;
-- apparence d'un humain : personnage fumeur s'il existe, sinon dérivée du nom d'utilisateur
create or replace function public._casino_look(p_user uuid) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; k text; h int; u text;
  hair text[] := array['court','longs','frange','chignon','tresses','cret','afro','chauve'];
  hcs text[] := array['#3b2a1d','#1c1c1c','#8a5a2b','#d9b44a','#b0452a','#9aa0a6'];
  eyes text[] := array['ronds','fins','grands','endormis','joyeux'];
  ecs text[] := array['#2a1d12','#2d5b8a','#3b7a3b','#6b4a2b','#5a5a5a'];
  skins text[] := array['#f1c9a5','#e0ac82','#c68642','#8d5524','#f5d7c0'];
begin
  select * into c from public.smoke_chars where user_id = p_user;
  if found then
    select kind into k from public.smoke_items where code = c.item;
    return jsonb_build_object('hair', c.hair, 'hc', c.hc, 'eyes', c.eyes, 'ec', c.ec, 'skin', c.skin, 'item', k, 'outfit', null);
  end if;
  select username into u from public.profiles where id = p_user;
  h := abs(hashtext(coalesce(u, p_user::text)));
  return jsonb_build_object('hair', hair[h % 8 + 1], 'hc', hcs[(h / 8) % 6 + 1], 'eyes', eyes[(h / 48) % 5 + 1],
    'ec', ecs[(h / 240) % 5 + 1], 'skin', skins[(h / 1200) % 5 + 1], 'item', null, 'outfit', null);
end $$;

-- ---------- D) Tables de jeu (poker, blackjack, roulette), sièges, journal, votes, mises ----------
create table if not exists public.casino_tables (
  id bigint generated always as identity primary key,
  game text not null check (game in ('poker','blackjack','roulette')),
  name text not null, min_bet numeric not null, max_bet numeric not null,
  phase text not null default 'waiting', phase_total_ms int, deadline timestamptz,
  version bigint not null default 0, hand_no int not null default 0,
  data jsonb not null default '{}', deck text[] not null default '{}',
  created_at timestamptz not null default now(), unique (game, name));
create table if not exists public.casino_seats (
  table_id bigint not null references public.casino_tables(id) on delete cascade, seat int not null,
  kind text not null check (kind in ('human','bot','dealer','left')), user_id uuid references public.profiles(id) on delete set null,
  name text not null, look jsonb not null default '{}',
  stack numeric(14,1) not null default 0, bet numeric(14,1) not null default 0, contrib numeric(14,1) not null default 0,
  status text not null default 'sitting', cards text[] not null default '{}', last text, winner boolean not null default false,
  acted boolean not null default false, seen_at timestamptz not null default now(), due timestamptz, extra jsonb not null default '{}',
  primary key (table_id, seat));
create unique index if not exists casino_seats_user_uq on public.casino_seats(user_id) where user_id is not null;
create table if not exists public.casino_log (id bigint generated always as identity primary key, table_id bigint not null references public.casino_tables(id) on delete cascade, t timestamptz not null default now(), msg text not null);
create index if not exists casino_log_t on public.casino_log(table_id, id desc);
create table if not exists public.casino_votes (table_id bigint not null references public.casino_tables(id) on delete cascade, user_id uuid not null references public.profiles(id) on delete cascade, yes boolean not null default true, primary key (table_id, user_id));
create table if not exists public.casino_bets (table_id bigint not null references public.casino_tables(id) on delete cascade, round int not null, seat int not null, user_id uuid, kind text not null, value text not null default '', amount numeric(14,1) not null,
  primary key (table_id, round, seat, kind, value));
-- triche au poker
create table if not exists public.casino_cheats (
  id bigint generated always as identity primary key, table_id bigint not null references public.casino_tables(id) on delete cascade, hand_no int not null,
  cheater uuid not null references public.profiles(id) on delete cascade, cheater_seat int, target_seat int not null, target_user uuid, target_bot boolean not null default false,
  need int not null, started timestamptz not null, ends timestamptz not null, clicks int not null default 0, last_click timestamptz,
  catch_at timestamptz, status text not null default 'running', card text, idx int);
create index if not exists casino_cheats_cheater on public.casino_cheats(cheater, started desc);
create index if not exists casino_cheats_tbl on public.casino_cheats(table_id, hand_no);
create table if not exists public.casino_peeks (cheater uuid not null references public.profiles(id) on delete cascade, table_id bigint not null references public.casino_tables(id) on delete cascade, hand_no int not null, seat int not null, idx int not null, card text not null,
  primary key (cheater, table_id, hand_no, seat, idx));
-- machines à sous
create table if not exists public.casino_slots (id bigint generated always as identity primary key, name text not null unique, theme text not null, min_bet numeric not null default 1, max_bet numeric not null default 500);
-- Lot-Au-MAX!
create table if not exists public.casino_pot (id bigint generated always as identity primary key, delta numeric(16,1) not null, reason text, at timestamptz not null default now());
create table if not exists public.casino_burn (id bigint generated always as identity primary key, delta numeric(16,1) not null, reason text, at timestamptz not null default now());
create table if not exists public.casino_periods (period date primary key, pot numeric(16,1) not null default 0, winner_ticket bigint, winner_h text, drawn_at timestamptz, claimed boolean not null default false, expired boolean not null default false);
create sequence if not exists public.casino_ticket_seq;
create table if not exists public.casino_tickets (
  id bigint generated always as identity primary key, no int not null unique default nextval('public.casino_ticket_seq'), owner uuid not null references public.profiles(id) on delete cascade,
  bought_at timestamptz not null, period date not null, fake boolean not null default false, payload bytea not null,
  h_zim text not null, h_tan text not null, h_tom text not null, h_pou text not null,
  opened boolean not null default false, seed int not null default 0, scr_zim boolean not null default false, scr_tan boolean not null default false, scr_tom boolean not null default false, scr_pou boolean not null default false,
  pou_done boolean not null default false, pou_solved boolean not null default false,
  zim_claimed boolean not null default false, tan_claimed boolean not null default false, tom_claimed boolean not null default false, pou_claimed boolean not null default false, confiscated boolean not null default false);
create index if not exists casino_tickets_owner on public.casino_tickets(owner, id desc);
create index if not exists casino_tickets_period on public.casino_tickets(period);
create index if not exists casino_tickets_hzim on public.casino_tickets(h_zim);
create index if not exists casino_tickets_htan on public.casino_tickets(h_tan);
create index if not exists casino_tickets_htom on public.casino_tickets(h_tom);
create index if not exists casino_tickets_hpou on public.casino_tickets(h_pou);
do $$ declare t text; begin
  foreach t in array array['casino_tables','casino_seats','casino_log','casino_votes','casino_bets','casino_cheats','casino_peeks','casino_slots','casino_pot','casino_burn','casino_periods','casino_tickets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on sequence public.casino_ticket_seq from anon, authenticated;

-- ---------- E) Outils communs : jetons, journal, version ----------
-- débite un joueur (échoue si solde insuffisant) ; positif = crédite
create or replace function public._casino_move(p_user uuid, p_delta numeric, p_reason text) returns numeric language plpgsql security definer set search_path = public, extensions as $$
declare b numeric;
begin
  if p_delta < 0 then
    select balance into b from public.wallets where user_id = p_user for update;
    if coalesce(b, 0) < -p_delta then raise exception 'Solde insuffisant'; end if;
  end if;
  return public.tok_add(p_user, p_delta, p_reason, null);
end $$;
create or replace function public._casino_log(p_t bigint, p_msg text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.casino_log(table_id, t, msg) values (p_t, _casino_now(), p_msg);
  if _casino_rand(20) = 0 then delete from public.casino_log where table_id = p_t and id < (select max(id) - 60 from public.casino_log where table_id = p_t); end if;
end $$;
create or replace function public._casino_touch(p_t bigint) returns void language sql security definer set search_path = public, extensions as $$
  update public.casino_tables set version = version + 1 where id = p_t $$;
-- phase suivante avec échéance
create or replace function public._casino_phase(p_t bigint, p_phase text, p_ms int) returns void language sql security definer set search_path = public, extensions as $$
  update public.casino_tables set phase = p_phase, phase_total_ms = p_ms, deadline = case when p_ms is null then null else _casino_now() + make_interval(secs => p_ms / 1000.0) end, version = version + 1 where id = p_t $$;
create or replace function public._casino_ms(p_s numeric) returns int language sql immutable as $$ select round(p_s * 1000)::int $$;
-- délai aléatoire d'un bot (1 à 3 s par défaut)
create or replace function public._casino_botdue() returns timestamptz language sql volatile security definer set search_path = public, extensions as $$
  select _casino_now() + make_interval(secs => (_casino_ccn('bot_min_delay_ms') + _casino_rfloat() * greatest(_casino_ccn('bot_max_delay_ms') - _casino_ccn('bot_min_delay_ms'), 0)) / 1000.0) $$;

-- ---------- F) Évaluateur de mains de poker (5 à 7 cartes) ----------
-- Score = catégorie * 15^5 + 5 rangs de départage en base 15.
-- Catégories : 0 carte haute, 1 paire, 2 double paire, 3 brelan, 4 quinte, 5 couleur, 6 full, 7 carré, 8 quinte flush, 9 quinte flush royale.
create or replace function public._pk_straight_high(h boolean[]) returns int language plpgsql immutable as $$
declare r int;
begin
  for r in reverse 14..6 loop
    if h[r] and h[r-1] and h[r-2] and h[r-3] and h[r-4] then return r; end if;
  end loop;
  if h[14] and h[2] and h[3] and h[4] and h[5] then return 5; end if;
  return 0;
end $$;
create or replace function public._pk_eval(p_cards text[]) returns bigint language plpgsql immutable set search_path = public, extensions as $$
declare
  cnt int[] := array_fill(0, array[15]); sc int[] := array_fill(0, array[5]); has boolean[] := array_fill(false, array[15]);
  hasf boolean[] := array_fill(false, array[15]);
  c text; r int; s int; fs int := 0; sf int; sh int; r1 int := 0; r2 int := 0; k int[] := '{}'; cat int; i int;
  trips int := 0; trips2 int := 0; p1 int := 0; p2 int := 0; p3 int := 0; quad int := 0; B5 bigint := 759375;
begin
  foreach c in array p_cards loop
    r := position(substr(c, 1, 1) in '23456789TJQKA') + 1; s := position(substr(c, 2, 1) in 'shdc');
    cnt[r] := cnt[r] + 1; sc[s] := sc[s] + 1; has[r] := true;
  end loop;
  for s in 1..4 loop if sc[s] >= 5 then fs := s; end if; end loop;
  if fs > 0 then
    foreach c in array p_cards loop
      if position(substr(c, 2, 1) in 'shdc') = fs then hasf[position(substr(c, 1, 1) in '23456789TJQKA') + 1] := true; end if;
    end loop;
    sf := _pk_straight_high(hasf);
    if sf > 0 then return (case when sf = 14 then 9 else 8 end) * B5 + sf::bigint * 50625; end if;
  end if;
  for r in reverse 14..2 loop
    if cnt[r] = 4 and quad = 0 then quad := r;
    elsif cnt[r] >= 3 and trips = 0 then trips := r;
    elsif cnt[r] >= 3 and trips2 = 0 then trips2 := r;
    elsif cnt[r] >= 2 then if p1 = 0 then p1 := r; elsif p2 = 0 then p2 := r; elsif p3 = 0 then p3 := r; end if;
    end if;
  end loop;
  if quad > 0 then
    for r in reverse 14..2 loop if r <> quad and cnt[r] > 0 then r1 := r; exit; end if; end loop;
    return 7 * B5 + quad::bigint * 50625 + r1 * 3375;
  end if;
  if trips > 0 and (trips2 > 0 or p1 > 0) then
    return 6 * B5 + trips::bigint * 50625 + greatest(trips2, p1) * 3375;
  end if;
  if fs > 0 then
    i := 0; k := '{}';
    for r in reverse 14..2 loop if hasf[r] and i < 5 then k := k || r; i := i + 1; end if; end loop;
    return 5 * B5 + k[1]::bigint * 50625 + k[2] * 3375 + k[3] * 225 + k[4] * 15 + k[5];
  end if;
  sh := _pk_straight_high(has);
  if sh > 0 then return 4 * B5 + sh::bigint * 50625; end if;
  if trips > 0 then
    i := 0; k := '{}';
    for r in reverse 14..2 loop if r <> trips and cnt[r] > 0 and i < 2 then k := k || r; i := i + 1; end if; end loop;
    return 3 * B5 + trips::bigint * 50625 + k[1] * 3375 + k[2] * 225;
  end if;
  if p2 > 0 then
    for r in reverse 14..2 loop if r <> p1 and r <> p2 and cnt[r] > 0 then r1 := r; exit; end if; end loop;
    return 2 * B5 + p1::bigint * 50625 + p2 * 3375 + r1 * 225;
  end if;
  if p1 > 0 then
    i := 0; k := '{}';
    for r in reverse 14..2 loop if r <> p1 and cnt[r] > 0 and i < 3 then k := k || r; i := i + 1; end if; end loop;
    return 1 * B5 + p1::bigint * 50625 + k[1] * 3375 + k[2] * 225 + k[3] * 15;
  end if;
  i := 0; k := '{}';
  for r in reverse 14..2 loop if cnt[r] > 0 and i < 5 then k := k || r; i := i + 1; end if; end loop;
  return k[1]::bigint * 50625 + k[2] * 3375 + k[3] * 225 + k[4] * 15 + coalesce(k[5], 0);
end $$;
-- nom français d'une main
create or replace function public._pk_name(p_score bigint) returns text language plpgsql immutable set search_path = public, extensions as $$
declare
  cat int := (p_score / 759375)::int; k1 int := ((p_score / 50625) % 15)::int; k2 int := ((p_score / 3375) % 15)::int;
  pl text[] := array['Deux','Trois','Quatre','Cinq','Six','Sept','Huit','Neuf','Dix','Valets','Dames','Rois','As'];
  sg text[] := array['Deux','Trois','Quatre','Cinq','Six','Sept','Huit','Neuf','Dix','Valet','Dame','Roi','As'];
begin
  return case cat
    when 9 then 'Quinte flush royale'
    when 8 then 'Quinte flush (haute ' || sg[k1 - 1] || ')'
    when 7 then 'Carré ' || case when k1 = 14 then 'd''As' else 'de ' || pl[k1 - 1] end
    when 6 then 'Full (' || pl[k1 - 1] || ' par ' || pl[k2 - 1] || ')'
    when 5 then 'Couleur (haute ' || sg[k1 - 1] || ')'
    when 4 then 'Quinte (haute ' || sg[k1 - 1] || ')'
    when 3 then 'Brelan ' || case when k1 = 14 then 'd''As' else 'de ' || pl[k1 - 1] end
    when 2 then 'Double paire (' || pl[k1 - 1] || ' et ' || pl[k2 - 1] || ')'
    when 1 then 'Paire ' || case when k1 = 14 then 'd''As' else 'de ' || pl[k1 - 1] end
    else 'Carte haute ' || sg[k1 - 1] end;
end $$;

-- ---------- G) Tables : création, sièges, bots, vote, entrée/sortie, état ----------
create or replace function public._casino_uid() returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return auth.uid();
end $$;
create or replace function public._casino_lock(p_t bigint) returns void language sql security definer set search_path = public, extensions as $$
  select pg_advisory_xact_lock(hashtextextended('casino:t:' || p_t::text, 0)) $$;
create or replace function public._casino_members() returns int language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from public.profiles $$;
create or replace function public._casino_ms_left(p_d timestamptz) returns int language sql volatile security definer set search_path = public, extensions as $$
  select case when p_d is null then null else greatest(0, round(extract(epoch from (p_d - _casino_now())) * 1000))::int end $$;
create or replace function public._casino_nowms() returns bigint language sql volatile security definer set search_path = public, extensions as $$
  select floor(extract(epoch from _casino_now()) * 1000)::bigint $$;

-- crée les tables et machines manquantes (jamais de suppression)
create or replace function public._casino_ensure() returns void language plpgsql security definer set search_path = public, extensions as $$
declare m int := public._casino_members(); nt int := greatest(1, ceil(m / 10.0)::int); ns int := greatest(4, ceil(m / 10.0)::int * 3);
  g text; lbl text; have int; i int; tid bigint; themes text[] := array['fruits','diamants','tresor','cosmos']; mn numeric; mx numeric; ph text;
begin
  perform pg_advisory_xact_lock(hashtextextended('casino:ensure', 0));
  foreach g in array array['poker','blackjack','roulette'] loop
    select count(*) into have from public.casino_tables where game = g;
    lbl := case g when 'poker' then 'Poker' when 'blackjack' then 'Blackjack' else 'Roulette' end;
    mn := case g when 'poker' then _casino_ccn('poker_bb') when 'blackjack' then _casino_ccn('bj_min') else _casino_ccn('rl_min') end;
    mx := case g when 'poker' then _casino_ccn('poker_buyin_max') when 'blackjack' then _casino_ccn('bj_max') else _casino_ccn('rl_max') end;
    ph := case g when 'poker' then 'waiting' else 'betting' end;
    for i in have + 1 .. nt loop
      tid := null;
      insert into public.casino_tables(game, name, min_bet, max_bet, phase) values (g, lbl || ' ' || i, mn, mx, ph) on conflict do nothing returning id into tid;
      if tid is not null then
        insert into public.casino_seats(table_id, seat, kind, name, look, status) values (tid, 10, 'dealer', _casino_bot_name(), _casino_look_random('croupier'), 'waiting');
      end if;
    end loop;
  end loop;
  select count(*) into have from public.casino_slots;
  for i in have + 1 .. ns loop
    insert into public.casino_slots(name, theme) values ('Machine ' || i, themes[(i - 1) % 4 + 1]) on conflict do nothing;
  end loop;
end $$;

-- siège libre au hasard (0..9)
create or replace function public._casino_free_seat(p_t bigint) returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare f int[]; begin
  select array_agg(s) into f from generate_series(0, 9) s where not exists(select 1 from public.casino_seats x where x.table_id = p_t and x.seat = s);
  if f is null then return null; end if;
  return f[_casino_rand(array_length(f, 1)) + 1];
end $$;

-- ---------- départ d'un siège (selon le jeu) ----------
-- renvoie les jetons rendus au portefeuille
create or replace function public._casino_drop_seat(p_t bigint, p_seat int) returns numeric language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s public.casino_seats; ref numeric := 0;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat;
  if not found then return 0; end if;
  if s.kind = 'bot' then
    perform _casino_bank(s.stack, 'bot quitte ' || t.name);
    delete from public.casino_seats where table_id = p_t and seat = p_seat;
    perform _casino_touch(p_t);
    return 0;
  end if;
  if t.game = 'poker' then return _pk_leave(p_t, p_seat); end if;
  if t.game = 'blackjack' then return _bj_leave(p_t, p_seat); end if;
  return _rl_leave(p_t, p_seat);
end $$;

-- remise à zéro quand plus aucun humain n'est assis : les bots et le croupier rendent tout à la banque
create or replace function public._casino_empty_reset(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables;
begin
  select * into t from public.casino_tables where id = p_t;
  perform _casino_bank(coalesce(sum(stack + contrib), 0), 'table vide ' || t.name) from public.casino_seats where table_id = p_t and kind in ('bot', 'dealer', 'left');
  delete from public.casino_seats where table_id = p_t and kind in ('bot', 'left');
  update public.casino_seats set stack = 0, bet = 0, contrib = 0, cards = '{}', status = 'waiting', last = null, winner = false, acted = false, due = null, extra = '{}' where table_id = p_t;
  delete from public.casino_votes where table_id = p_t;
  if t.game = 'roulette' then
    update public.casino_tables set phase = 'betting', phase_total_ms = null, deadline = null, data = data - 'result' || jsonb_build_object('payouts', '{}'::jsonb), version = version + 1 where id = p_t;
  else
    update public.casino_tables set phase = case when t.game = 'poker' then 'waiting' else 'betting' end, phase_total_ms = null, deadline = null, deck = '{}',
      data = jsonb_build_object('btn', coalesce((t.data->>'btn')::int, -1)), version = version + 1 where id = p_t;
  end if;
end $$;

-- ---------- tick paresseux ----------
create or replace function public._casino_tick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s record; hum int;
begin
  select * into t from public.casino_tables where id = p_t;
  if not found then return; end if;
  -- sièges abandonnés (sans sondage depuis 120 s)
  for s in select seat from public.casino_seats where table_id = p_t and kind = 'human' and seen_at < _casino_now() - make_interval(secs => _casino_ccn('seat_idle_s')::double precision) order by seat loop
    perform _casino_drop_seat(p_t, s.seat);
  end loop;
  select count(*) into hum from public.casino_seats where table_id = p_t and kind = 'human';
  if hum = 0 then
    if exists(select 1 from public.casino_seats where table_id = p_t and (kind in ('bot', 'left') or stack > 0 or contrib > 0)) or t.deadline is not null or t.phase not in ('waiting', 'betting') then
      perform _casino_empty_reset(p_t);
    end if;
    return;
  end if;
  if t.game = 'poker' then perform _pk_tick(p_t);
  elsif t.game = 'blackjack' then perform _bj_tick(p_t);
  else perform _rl_tick(p_t); end if;
end $$;

-- ---------- bots : ajout et vote ----------
create or replace function public._casino_add_bot(p_t bigint) returns int language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; sn int; res numeric; nm text;
begin
  select * into t from public.casino_tables where id = p_t;
  sn := _casino_free_seat(p_t);
  if sn is null then return null; end if;
  res := case t.game
    when 'poker' then _casino_ccn('poker_bb') * (40 + _casino_rand(81))
    when 'blackjack' then 1000 + _casino_rand(5001)
    else 500 + _casino_rand(3501) end;
  nm := _casino_bot_name();
  perform _casino_bank(-res, 'réserve de bot ' || t.name);
  insert into public.casino_seats(table_id, seat, kind, name, look, stack, status, seen_at, due)
    values (p_t, sn, 'bot', nm, _casino_look_random(), res, 'waiting', _casino_now(), case when t.game = 'poker' then null else _casino_botdue() end);
  perform _casino_log(p_t, nm || ' (bot) s’assoit.');
  perform _casino_touch(p_t);
  return sn;
end $$;

create or replace function public._casino_vote_info(p_t bigint, p_uid uuid) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare hum int; ny int; need int; bots int;
begin
  select count(*) into hum from public.casino_seats where table_id = p_t and kind = 'human';
  select count(*) into ny from public.casino_votes v join public.casino_seats s on s.table_id = v.table_id and s.user_id = v.user_id where v.table_id = p_t and v.yes;
  select count(*) into bots from public.casino_seats where table_id = p_t and kind = 'bot';
  need := greatest(1, ceil(hum * _casino_ccn('bot_vote_pct') / 100.0)::int);
  return jsonb_build_object('yes', ny, 'humans', hum, 'needed', need, 'voted', exists(select 1 from public.casino_votes where table_id = p_t and user_id = p_uid and yes),
    'bots', bots, 'max_bots', _casino_ccn('bot_max')::int);
end $$;

create or replace function public.casino_bot_vote(p_table bigint, p_yes boolean default true) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); v jsonb; added boolean := false; sn int;
begin
  perform public.rate_ok('casino_vote', 60, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  if not exists(select 1 from public.casino_seats where table_id = p_table and user_id = uid) then raise exception 'Vous devez être assis à cette table'; end if;
  insert into public.casino_votes(table_id, user_id, yes) values (p_table, uid, coalesce(p_yes, true)) on conflict (table_id, user_id) do update set yes = excluded.yes;
  v := _casino_vote_info(p_table, uid);
  if (v->>'yes')::int >= (v->>'needed')::int and (v->>'bots')::int < (v->>'max_bots')::int then
    sn := _casino_add_bot(p_table);
    if sn is null then raise exception 'Table pleine'; end if;
    added := true;
    delete from public.casino_votes where table_id = p_table;
    v := _casino_vote_info(p_table, uid);
    perform _casino_wake(p_table);
  elsif (v->>'yes')::int >= (v->>'needed')::int then
    raise exception 'Nombre maximal de bots atteint';
  end if;
  perform _casino_touch(p_table);
  return jsonb_build_object('yes', v->'yes', 'humans', v->'humans', 'needed', v->'needed', 'added', added);
end $$;

-- réveille la machine à états d'une table quand quelqu'un arrive
create or replace function public._casino_wake(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables;
begin
  select * into t from public.casino_tables where id = p_t;
  if t.game = 'poker' then perform _pk_kick(p_t);
  elsif t.game = 'blackjack' then perform _bj_kick(p_t);
  else perform _rl_kick(p_t); end if;
end $$;

-- ---------- entrer / quitter ----------
create or replace function public.casino_join(p_table bigint, p_seat int default null, p_buyin numeric default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; me public.casino_seats; sn int; b numeric; un text; other record; bmin numeric; bmax numeric;
begin
  perform public.rate_ok('casino_join', 60, 60);
  select * into t from public.casino_tables where id = p_table;
  if not found then raise exception 'Table introuvable'; end if;
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  select * into me from public.casino_seats where table_id = p_table and user_id = uid;
  if found then
    -- déjà assis ici : recharge de jetons au poker entre deux mains
    if t.game = 'poker' and p_buyin is not null then
      if me.status in ('active', 'allin') then raise exception 'Phase incorrecte'; end if;
      b := floor(p_buyin);
      if b <= 0 or me.stack + b > _casino_ccn('poker_buyin_max') then raise exception 'Mise hors limites'; end if;
      perform _casino_move(uid, -b, 'casino : recharge ' || t.name);
      update public.casino_seats set stack = stack + b, seen_at = _casino_now() where table_id = p_table and seat = me.seat;
      perform _casino_touch(p_table);
      perform _pk_kick(p_table);
    end if;
    return jsonb_build_object('seat', me.seat);
  end if;
  -- déjà assis ailleurs : on quitte l'autre table d'abord
  select * into other from public.casino_seats where user_id = uid;
  if found then
    perform _casino_lock(other.table_id);
    perform _casino_drop_seat(other.table_id, other.seat);
  end if;
  if p_seat is null then sn := _casino_free_seat(p_table);
  else
    if p_seat < 0 or p_seat > 9 then raise exception 'Place invalide'; end if;
    if exists(select 1 from public.casino_seats where table_id = p_table and seat = p_seat) then raise exception 'Place déjà prise'; end if;
    sn := p_seat;
  end if;
  if sn is null then raise exception 'Table pleine'; end if;
  b := 0;
  if t.game = 'poker' then
    bmin := _casino_ccn('poker_buyin_min'); bmax := _casino_ccn('poker_buyin_max');
    b := floor(coalesce(p_buyin, bmin));
    if b < bmin or b > bmax then raise exception 'Mise hors limites'; end if;
    perform _casino_move(uid, -b, 'casino : quitte-ou-double ' || t.name);
  end if;
  select username into un from public.profiles where id = uid;
  insert into public.casino_seats(table_id, seat, kind, user_id, name, look, stack, status, seen_at)
    values (p_table, sn, 'human', uid, coalesce(un, 'joueur'), _casino_look(uid), b, 'waiting', _casino_now());
  perform _casino_log(p_table, coalesce(un, 'joueur') || ' s’assoit.');
  perform _casino_touch(p_table);
  perform _casino_wake(p_table);
  return jsonb_build_object('seat', sn);
end $$;

create or replace function public.casino_leave(p_table bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); s public.casino_seats; r numeric := 0;
begin
  perform _casino_lock(p_table);
  select * into s from public.casino_seats where table_id = p_table and user_id = uid;
  if not found then return jsonb_build_object('refunded', 0); end if;
  r := _casino_drop_seat(p_table, s.seat);
  perform _casino_tick(p_table);
  return jsonb_build_object('refunded', coalesce(r, 0));
end $$;

-- ---------- état d'une table ----------
create or replace function public._casino_seat_json(p_s public.casino_seats, p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare j jsonb;
begin
  j := jsonb_build_object('seat', p_s.seat, 'kind', p_s.kind, 'name', p_s.name, 'look', p_s.look, 'stack', p_s.stack, 'bet', p_s.bet, 'status', p_s.status, 'last', p_s.last, 'winner', p_s.winner);
  if p_t.game = 'poker' then return j || _pk_seat_extra(p_s, p_t, p_uid);
  elsif p_t.game = 'blackjack' then return j || _bj_seat_extra(p_s, p_t, p_uid);
  else return j; end if;
end $$;

create or replace function public.casino_state(p_table bigint, p_since bigint default 0) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; s public.casino_seats; seats jsonb := '[]'::jsonb; arr jsonb[] := array_fill(null::jsonb, array[10]); me jsonb; ex jsonb; d public.casino_seats; dj jsonb; lg jsonb; i int;
begin
  perform public.rate_ok('casino_state', 600, 60);
  select * into t from public.casino_tables where id = p_table;
  if not found then raise exception 'Table introuvable'; end if;
  perform _casino_lock(p_table);
  update public.casino_seats set seen_at = _casino_now() where table_id = p_table and user_id = uid;
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if p_since is not null and p_since = t.version then
    return jsonb_build_object('ok', true, 'unchanged', true, 'version', t.version, 'now_ms', _casino_nowms(), 'me', _casino_me_light(t, uid));
  end if;
  for s in select * from public.casino_seats where table_id = p_table and seat between 0 and 9 and kind in ('human', 'bot') order by seat loop
    arr[s.seat + 1] := _casino_seat_json(s, t, uid);
  end loop;
  for i in 1..10 loop seats := seats || jsonb_build_array(arr[i]); end loop;
  select * into d from public.casino_seats where table_id = p_table and seat = 10;
  dj := jsonb_build_object('name', d.name, 'look', d.look);
  me := _casino_me(t, uid);
  ex := case t.game when 'poker' then _pk_extra(t, uid) when 'blackjack' then _bj_extra(t, uid) else _rl_extra(t, uid) end;
  select coalesce(jsonb_agg(jsonb_build_object('t', floor(extract(epoch from l.t) * 1000)::bigint, 'msg', l.msg) order by l.id), '[]'::jsonb) into lg
    from (select * from public.casino_log where table_id = p_table order by id desc limit 12) l;
  return jsonb_build_object('ok', true, 'version', t.version, 'now_ms', _casino_nowms(), 'game', t.game,
    'table', jsonb_build_object('id', t.id, 'name', t.name, 'min_bet', t.min_bet, 'max_bet', t.max_bet,
       'buyin_min', case when t.game = 'poker' then _casino_ccn('poker_buyin_min') end, 'buyin_max', case when t.game = 'poker' then _casino_ccn('poker_buyin_max') end, 'seats', 10),
    'phase', t.phase, 'phase_left_ms', _casino_ms_left(t.deadline), 'phase_total_ms', t.phase_total_ms,
    'me', me || coalesce(ex->'me', '{}'::jsonb), 'seats', seats, 'dealer', dj || coalesce(ex->'dealer', '{}'::jsonb), 'log', lg) || (ex - 'me' - 'dealer');
end $$;

-- partie « moi » commune
create or replace function public._casino_me(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; w numeric;
begin
  select balance into w from public.wallets where user_id = p_uid;
  select * into s from public.casino_seats where table_id = p_t.id and user_id = p_uid;
  return jsonb_build_object('seat', case when found then s.seat end, 'wallet', coalesce(w, 0), 'stack', case when found then s.stack else 0 end,
    'cards', '[]'::jsonb, 'to_act', false, 'peeks', '[]'::jsonb, 'bets', '[]'::jsonb, 'bot_vote', _casino_vote_info(p_t.id, p_uid)) || _casino_me_light(p_t, p_uid);
end $$;
create or replace function public._casino_me_light(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_t.game = 'poker' then return _pk_cheat_me(p_t, p_uid); end if;
  return jsonb_build_object('alarms', '[]'::jsonb, 'cheat', jsonb_build_object('cooldown_ms', 0, 'blocked_seats', '[]'::jsonb, 'attempt', null));
end $$;

-- ---------- lobby ----------
create or replace function public.casino_lobby() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); m int := _casino_members(); w record; games jsonb := '[]'::jsonb; g text; lbl text; tb jsonb; sl jsonb; r record;
begin
  perform public.rate_ok('casino_lobby', 120, 60);
  perform _lot_period_close();
  perform _casino_ensure();
  for r in select distinct table_id from public.casino_seats where kind = 'human' and seen_at < _casino_now() - make_interval(secs => _casino_ccn('seat_idle_s')::double precision) loop
    perform _casino_lock(r.table_id);
    perform _casino_tick(r.table_id);
  end loop;
  select coalesce(balance, 0) as b, coalesce(medals, 0) as md into w from (select 1) x left join public.wallets on user_id = uid;
  foreach g in array array['poker', 'blackjack', 'roulette'] loop
    lbl := case g when 'poker' then 'Poker' when 'blackjack' then 'Blackjack' else 'Roulette' end;
    select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name,
        'humans', (select count(*) from public.casino_seats s where s.table_id = t.id and s.kind = 'human'),
        'bots', (select count(*) from public.casino_seats s where s.table_id = t.id and s.kind = 'bot'),
        'seats', 10, 'phase', t.phase, 'min_bet', t.min_bet, 'max_bet', t.max_bet) order by t.id), '[]'::jsonb) into tb from public.casino_tables t where t.game = g;
    games := games || jsonb_build_array(jsonb_build_object('game', g, 'label', lbl, 'tables', tb));
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'theme', theme, 'min_bet', min_bet, 'max_bet', max_bet) order by id), '[]'::jsonb) into sl from public.casino_slots;
  return jsonb_build_object('members', m, 'per_table', 10, 'balance', w.b, 'medals', w.md, 'games', games, 'slots', sl, 'lot', _lot_info_json(uid));
end $$;

-- ---------- H) Poker Texas Hold'em ----------
-- Sièges 0..9 = joueurs/bots, siège 10 = croupier (« La Maison », joue comme un joueur, stack rechargé depuis la banque à chaque main).
-- tables.data : btn, cur (mise actuelle), minr (relance minimale), to_act (siège ou null), community[], pot_final, last_hand, reveal.
-- status des sièges : waiting (hors main), active, allin, folded.

create or replace function public._pk_set_due(p_t bigint, p_seat int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; d timestamptz; tot int;
begin
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat;
  if s.kind = 'human' then tot := _casino_ms(_casino_ccn('poker_act_s')); d := _casino_now() + make_interval(secs => tot / 1000.0);
  else tot := null; d := _casino_botdue(); end if;
  update public.casino_seats set due = d where table_id = p_t and seat = p_seat;
  update public.casino_tables set deadline = d, phase_total_ms = tot, data = data || jsonb_build_object('to_act', p_seat), version = version + 1 where id = p_t;
end $$;

create or replace function public._pk_post(p_t bigint, p_seat int, p_amt numeric, p_label text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare a numeric;
begin
  select least(p_amt, stack) into a from public.casino_seats where table_id = p_t and seat = p_seat;
  update public.casino_seats set stack = stack - a, bet = bet + a, contrib = contrib + a, last = p_label || ' ' || a::bigint, status = case when stack - a <= 0 then 'allin' else status end
    where table_id = p_t and seat = p_seat;
end $$;

create or replace function public._pk_start_hand(p_t bigint) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; bb numeric := _casino_ccn('poker_bb'); sb numeric; ord int[]; n int; old int; btn int; sbs int; bbs int; r record; d text[]; i int;
  dstack numeric := _casino_ccn('poker_dealer_stack'); a numeric; hum int;
begin
  select * into t from public.casino_tables where id = p_t;
  sb := floor(bb / 2);
  for r in select seat from public.casino_seats where table_id = p_t and kind = 'bot' and stack < bb loop perform _casino_drop_seat(p_t, r.seat); end loop;
  delete from public.casino_seats where table_id = p_t and kind = 'left';
  select stack into a from public.casino_seats where table_id = p_t and seat = 10;
  perform _casino_bank(coalesce(a, 0) - dstack, 'croupier ' || t.name);
  update public.casino_seats set stack = dstack where table_id = p_t and seat = 10;
  select array_agg(seat order by seat), count(*) filter (where kind = 'human') into ord, hum from public.casino_seats
    where table_id = p_t and ((kind in ('human', 'bot') and stack >= bb) or seat = 10);
  if coalesce(hum, 0) = 0 then return false; end if;
  n := array_length(ord, 1);
  update public.casino_seats set bet = 0, contrib = 0, cards = '{}', last = null, winner = false, acted = false, due = null, extra = '{}',
    status = case when seat = any(ord) then 'active' else 'waiting' end where table_id = p_t;
  old := coalesce((t.data->>'btn')::int, -1);
  btn := coalesce((select min(x) from unnest(ord) x where x > old), ord[1]);
  if n = 2 then sbs := btn; bbs := (select x from unnest(ord) x where x <> btn);
  else
    sbs := coalesce((select min(x) from unnest(ord) x where x > btn), ord[1]);
    bbs := coalesce((select min(x) from unnest(ord) x where x > sbs), ord[1]);
  end if;
  d := _casino_deck(1);
  for i in 1..n loop
    update public.casino_seats set cards = array[d[i], d[n + i]] where table_id = p_t and seat = ord[i];
  end loop;
  d := d[(2 * n + 1):array_length(d, 1)];
  perform _pk_post(p_t, sbs, sb, 'Petite blinde');
  perform _pk_post(p_t, bbs, bb, 'Grosse blinde');
  update public.casino_tables set deck = d, hand_no = hand_no + 1,
    data = jsonb_build_object('btn', btn, 'cur', bb, 'minr', bb, 'to_act', null, 'community', '[]'::jsonb, 'pot_final', null, 'last_hand', null, 'reveal', false) where id = p_t;
  perform _casino_phase(p_t, 'preflop', null);
  perform _casino_log(p_t, 'Main n° ' || (t.hand_no + 1) || ' : les cartes sont distribuées.');
  perform _pk_advance(p_t, bbs);
  return true;
end $$;

-- évalue l'état : un seul joueur restant, tour fermé, ou prochain à parler
create or replace function public._pk_advance(p_t bigint, p_from int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; nf int; na int; cur numeric; closed boolean; nxt int; i int; sn int;
begin
  select * into t from public.casino_tables where id = p_t;
  cur := (t.data->>'cur')::numeric;
  select count(*) filter (where status in ('active', 'allin')), count(*) filter (where status = 'active') into nf, na from public.casino_seats where table_id = p_t;
  if nf <= 1 then perform _pk_showdown(p_t, false); return; end if;
  select coalesce(bool_and(acted and bet >= cur), true) into closed from public.casino_seats where table_id = p_t and status = 'active';
  if not closed and na = 1 then
    select (bet >= cur) into closed from public.casino_seats where table_id = p_t and status = 'active';
  end if;
  if not closed then
    for i in 1..11 loop
      sn := (p_from + i) % 11;
      if exists(select 1 from public.casino_seats where table_id = p_t and seat = sn and status = 'active' and (not acted or bet < cur)) then nxt := sn; exit; end if;
    end loop;
  end if;
  if closed or nxt is null then
    if jsonb_array_length(t.data->'community') >= 5 then perform _pk_showdown(p_t, true); else perform _pk_next_street(p_t); end if;
    return;
  end if;
  perform _pk_set_due(p_t, nxt);
end $$;

create or replace function public._pk_next_street(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; comm jsonb; n int; d text[]; nw text[]; ph text; na int; bb numeric := _casino_ccn('poker_bb');
begin
  select * into t from public.casino_tables where id = p_t;
  comm := t.data->'community'; n := jsonb_array_length(comm);
  if n >= 5 then perform _pk_showdown(p_t, true); return; end if;
  d := t.deck; d := d[2:array_length(d, 1)];
  if n = 0 then nw := d[1:3]; d := d[4:array_length(d, 1)]; ph := 'flop';
  elsif n = 3 then nw := d[1:1]; d := d[2:array_length(d, 1)]; ph := 'turn';
  else nw := d[1:1]; d := d[2:array_length(d, 1)]; ph := 'river'; end if;
  update public.casino_seats set bet = 0, acted = false, due = null where table_id = p_t;
  update public.casino_tables set deck = d, data = data || jsonb_build_object('community', comm || to_jsonb(nw), 'cur', 0, 'minr', bb, 'to_act', null) where id = p_t;
  perform _casino_phase(p_t, ph, _casino_ms(_casino_ccn('poker_runout_s')));
  select count(*) into na from public.casino_seats where table_id = p_t and status = 'active';
  if na >= 2 then perform _pk_advance(p_t, (t.data->>'btn')::int); end if;
end $$;

-- partage des pots (pots annexes), paiement, drapeaux de gagnants
create or replace function public._pk_showdown(p_t bigint, p_eval boolean) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; comm text[]; levels numeric[]; lv numeric; prev numeric := 0; pot numeric; elig int[]; best bigint; wins int[]; n int; share numeric; rem numeric; i int;
  r record; sc jsonb := '{}'; pay jsonb := '{}'; won jsonb := '{}'; total numeric; nf int; btn int; reveal boolean; lh jsonb := '[]'; k text; amt numeric; bb numeric := _casino_ccn('poker_bb');
begin
  select * into t from public.casino_tables where id = p_t;
  btn := coalesce((t.data->>'btn')::int, 0);
  comm := array(select jsonb_array_elements_text(t.data->'community'));
  select count(*) into nf from public.casino_seats where table_id = p_t and status in ('active', 'allin');
  reveal := p_eval and nf >= 2 and array_length(comm, 1) = 5;
  select coalesce(sum(contrib), 0) into total from public.casino_seats where table_id = p_t;
  if reveal then
    for r in select seat, cards from public.casino_seats where table_id = p_t and status in ('active', 'allin') loop
      sc := sc || jsonb_build_object(r.seat::text, _pk_eval(r.cards || comm));
    end loop;
  end if;
  levels := array(select distinct contrib from public.casino_seats where table_id = p_t and contrib > 0 order by contrib);
  foreach lv in array coalesce(levels, '{}'::numeric[]) loop
    select coalesce(sum(least(contrib, lv) - least(contrib, prev)), 0) into pot from public.casino_seats where table_id = p_t;
    elig := array(select seat from public.casino_seats where table_id = p_t and status in ('active', 'allin') and contrib >= lv order by seat);
    if elig is null or array_length(elig, 1) is null then
      for r in select seat, least(contrib, lv) - prev as a from public.casino_seats where table_id = p_t and contrib > prev loop
        pay := jsonb_set(pay, array[r.seat::text], to_jsonb(coalesce((pay->>r.seat::text)::numeric, 0) + r.a));
      end loop;
    else
      if reveal then
        select max((sc->>(x::text))::bigint) into best from unnest(elig) x;
        wins := array(select x from unnest(elig) x where (sc->>(x::text))::bigint = best order by (x - btn - 1 + 22) % 11);
      else wins := array[elig[1]]; end if;
      n := array_length(wins, 1);
      share := floor(pot / n); rem := pot - share * n;
      for i in 1..n loop
        amt := share + case when i = 1 then rem else 0 end;
        pay := jsonb_set(pay, array[wins[i]::text], to_jsonb(coalesce((pay->>wins[i]::text)::numeric, 0) + amt));
        won := jsonb_set(won, array[wins[i]::text], 'true'::jsonb);
      end loop;
    end if;
    prev := lv;
  end loop;
  for k in select jsonb_object_keys(pay) loop
    update public.casino_seats set stack = stack + (pay->>k)::numeric where table_id = p_t and seat = k::int;
  end loop;
  for r in select * from public.casino_seats where table_id = p_t and seat between 0 and 10 order by seat loop
    if won ? r.seat::text then
      lh := lh || jsonb_build_array(jsonb_build_object('seat', case when r.seat = 10 then to_jsonb('dealer'::text) else to_jsonb(r.seat) end, 'name', r.name,
        'amount', (pay->>r.seat::text)::numeric, 'hand', case when reveal then _pk_name((sc->>r.seat::text)::bigint) end));
      perform _casino_log(p_t, r.name || ' remporte ' || ((pay->>r.seat::text)::numeric)::bigint || case when reveal then ' (' || _pk_name((sc->>r.seat::text)::bigint) || ')' else '' end || '.');
    end if;
    if reveal and sc ? r.seat::text then
      update public.casino_seats set extra = jsonb_build_object('hand', _pk_name((sc->>r.seat::text)::bigint)) where table_id = p_t and seat = r.seat;
    end if;
  end loop;
  update public.casino_seats set winner = (won ? seat::text), contrib = 0, bet = 0, due = null where table_id = p_t;
  update public.casino_tables set data = data || jsonb_build_object('pot_final', total, 'to_act', null, 'last_hand', jsonb_build_object('winners', lh), 'reveal', reveal) where id = p_t;
  perform _casino_phase(p_t, 'showdown', _casino_ms(_casino_ccn('poker_showdown_s')));
end $$;

create or replace function public._pk_to_between(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  delete from public.casino_seats where table_id = p_t and kind = 'left';
  for r in select seat from public.casino_seats where table_id = p_t and kind = 'bot' and stack < _casino_ccn('poker_bb') loop perform _casino_drop_seat(p_t, r.seat); end loop;
  update public.casino_seats set cards = '{}', winner = false, status = 'waiting', acted = false, due = null where table_id = p_t;
  update public.casino_tables set deck = '{}', data = data || jsonb_build_object('community', '[]'::jsonb, 'reveal', false, 'to_act', null) where id = p_t;
  perform _casino_phase(p_t, 'between', _casino_ms(_casino_ccn('poker_between_s')));
end $$;

-- applique une action (fold / check / call / raise / allin)
create or replace function public._pk_apply(p_t bigint, p_seat int, p_act text, p_amt numeric) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s public.casino_seats; cur numeric; minr numeric; amt numeric; r numeric; mx numeric; lbl text;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat for update;
  cur := (t.data->>'cur')::numeric; minr := (t.data->>'minr')::numeric; mx := s.bet + s.stack;
  if p_act = 'fold' then
    update public.casino_seats set status = 'folded', acted = true, last = 'Se couche', due = null where table_id = p_t and seat = p_seat;
    perform _casino_log(p_t, s.name || ' se couche.');
  elsif p_act = 'check' then
    if s.bet < cur then raise exception 'Vous ne pouvez pas checker'; end if;
    update public.casino_seats set acted = true, last = 'Check', due = null where table_id = p_t and seat = p_seat;
  else
    if p_act = 'call' then r := least(cur, mx);
    elsif p_act = 'allin' then r := mx;
    elsif p_act = 'raise' then r := floor(coalesce(p_amt, 0));
    else raise exception 'Action invalide'; end if;
    if r > mx then raise exception 'Mise hors limites'; end if;
    if p_act = 'raise' and r <= cur then raise exception 'La relance doit dépasser la mise actuelle'; end if;
    if r <= cur then
      -- suivre (ou tapis trop court pour relancer)
      amt := least(cur - s.bet, s.stack);
      if amt <= 0 then raise exception 'Rien à suivre : checkez'; end if;
      update public.casino_seats set stack = stack - amt, bet = bet + amt, contrib = contrib + amt, acted = true, due = null,
        status = case when stack - amt <= 0 then 'allin' else status end, last = case when stack - amt <= 0 then 'Tapis ' || (bet + amt)::bigint else 'Suit ' || amt::bigint end where table_id = p_t and seat = p_seat;
    else
      if r < cur + minr and r < mx then raise exception 'Relance minimale : %', (cur + minr)::bigint; end if;
      amt := r - s.bet;
      if r - cur >= minr then minr := r - cur; end if;
      update public.casino_seats set stack = stack - amt, bet = r, contrib = contrib + amt, acted = true, due = null,
        status = case when stack - amt <= 0 then 'allin' else status end, last = case when stack - amt <= 0 then 'Tapis ' || r::bigint else 'Relance à ' || r::bigint end where table_id = p_t and seat = p_seat;
      update public.casino_seats set acted = false where table_id = p_t and seat <> p_seat and status = 'active';
      cur := r;
      update public.casino_tables set data = data || jsonb_build_object('cur', cur, 'minr', minr) where id = p_t;
    end if;
  end if;
  perform _pk_advance(p_t, p_seat);
end $$;

-- force d'une main 0..1 pour les bots
create or replace function public._pk_strength(p_cards text[], p_comm text[]) returns numeric language plpgsql immutable set search_path = public, extensions as $$
declare a int; b int; hi int; lo int; s numeric; sc bigint; cat int; rk text := '23456789TJQKA';
begin
  a := position(substr(p_cards[1], 1, 1) in rk) + 1; b := position(substr(p_cards[2], 1, 1) in rk) + 1;
  hi := greatest(a, b); lo := least(a, b);
  if coalesce(array_length(p_comm, 1), 0) < 3 then
    if a = b then s := 0.5 + a / 28.0;
    else s := 0.12 + (hi - 2) / 12.0 * 0.38 + (lo - 2) / 12.0 * 0.2 + case when substr(p_cards[1], 2, 1) = substr(p_cards[2], 2, 1) then 0.05 else 0 end + case when hi - lo <= 2 then 0.05 else 0 end; end if;
    return least(s, 1);
  end if;
  sc := _pk_eval(p_cards || p_comm); cat := (sc / 759375)::int;
  return case cat when 0 then 0.1 + hi / 100.0 when 1 then 0.42 + (sc / 50625 % 15) / 100.0 when 2 then 0.66 when 3 then 0.76 when 4 then 0.83 when 5 then 0.87 when 6 then 0.93 else 0.98 end;
end $$;

create or replace function public._pk_bot_act(p_t bigint, p_seat int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s public.casino_seats; cur numeric; minr numeric; tc numeric; st numeric; pot numeric; comm text[]; rr numeric; to_r numeric;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat;
  cur := (t.data->>'cur')::numeric; minr := (t.data->>'minr')::numeric; tc := cur - s.bet;
  comm := array(select jsonb_array_elements_text(t.data->'community'));
  st := _pk_strength(s.cards, comm) + (_casino_rfloat() - 0.5) * 0.16;
  select coalesce(sum(contrib), 0) into pot from public.casino_seats where table_id = p_t;
  to_r := cur + greatest(minr, round(pot * (0.4 + _casino_rfloat() * 0.5)));
  if tc <= 0 then
    if st > 0.72 and _casino_rfloat() < 0.6 and s.stack > minr then
      if to_r >= s.bet + s.stack then perform _pk_apply(p_t, p_seat, 'allin', 0); else perform _pk_apply(p_t, p_seat, 'raise', to_r); end if;
    else perform _pk_apply(p_t, p_seat, 'check', 0); end if;
  elsif st < 0.27 and not (tc <= _casino_ccn('poker_bb') and _casino_rfloat() < 0.3) then perform _pk_apply(p_t, p_seat, 'fold', 0);
  elsif st < 0.55 then
    if tc <= s.stack * 0.15 or st > 0.45 then perform _pk_apply(p_t, p_seat, 'call', 0); else perform _pk_apply(p_t, p_seat, 'fold', 0); end if;
  elsif st > 0.9 and _casino_rfloat() < 0.35 then perform _pk_apply(p_t, p_seat, 'allin', 0);
  elsif st > 0.68 and _casino_rfloat() < 0.35 and to_r < s.bet + s.stack then perform _pk_apply(p_t, p_seat, 'raise', to_r);
  else perform _pk_apply(p_t, p_seat, 'call', 0); end if;
end $$;

create or replace function public._pk_kick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables;
begin
  select * into t from public.casino_tables where id = p_t;
  if t.phase = 'waiting' and exists(select 1 from public.casino_seats where table_id = p_t and kind = 'human' and stack >= _casino_ccn('poker_bb')) then
    perform _casino_phase(p_t, 'between', _casino_ms(_casino_ccn('poker_start_s')));
  end if;
end $$;

create or replace function public._pk_tick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; v0 bigint; i int; s public.casino_seats; ta int;
begin
  for i in 1..6 loop
    select * into t from public.casino_tables where id = p_t; v0 := t.version;
    if t.phase = 'waiting' then perform _pk_kick(p_t);
    elsif t.phase = 'between' then
      if t.deadline is not null and t.deadline <= _casino_now() then
        if not _pk_start_hand(p_t) then perform _casino_phase(p_t, 'waiting', null); end if;
      end if;
    elsif t.phase = 'showdown' then
      if t.deadline is not null and t.deadline <= _casino_now() then perform _pk_to_between(p_t); end if;
    elsif t.phase in ('preflop', 'flop', 'turn', 'river') then
      ta := (t.data->>'to_act')::int;
      if ta is not null then
        select * into s from public.casino_seats where table_id = p_t and seat = ta;
        if not found then perform _pk_advance(p_t, ta);
        elsif s.due is not null and s.due <= _casino_now() then
          if s.kind = 'human' then
            if s.bet >= (t.data->>'cur')::numeric then perform _pk_apply(p_t, ta, 'check', 0); else perform _pk_apply(p_t, ta, 'fold', 0); end if;
            update public.casino_seats set last = 'Temps écoulé' where table_id = p_t and seat = ta;
          else perform _pk_bot_act(p_t, ta); end if;
        end if;
      elsif t.deadline is not null and t.deadline <= _casino_now() then perform _pk_next_street(p_t);
      end if;
    end if;
    exit when (select version from public.casino_tables where id = p_t) = v0;
  end loop;
end $$;

-- départ d'un joueur : le stack revient au portefeuille ; la main en cours est couchée (ses mises restent au pot)
create or replace function public._pk_leave(p_t bigint, p_seat int) returns numeric language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s public.casino_seats; ref numeric; ta int; inhand boolean;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat for update;
  if not found then return 0; end if;
  ref := s.stack;
  inhand := t.phase in ('preflop', 'flop', 'turn', 'river') and s.status in ('active', 'allin', 'folded') and s.contrib > 0;
  ta := (t.data->>'to_act')::int;
  if ref > 0 and s.user_id is not null then perform _casino_move(s.user_id, ref, 'casino : quitte ' || t.name); end if;
  if inhand then
    update public.casino_seats set kind = 'left', user_id = null, stack = 0, status = 'folded', cards = '{}', due = null, bet = bet where table_id = p_t and seat = p_seat;
    perform _casino_log(p_t, s.name || ' quitte la table.');
    perform _pk_advance(p_t, p_seat);
  else
    delete from public.casino_seats where table_id = p_t and seat = p_seat;
    perform _casino_log(p_t, s.name || ' quitte la table.');
    if t.phase in ('preflop', 'flop', 'turn', 'river') and ta = p_seat then perform _pk_advance(p_t, p_seat); end if;
  end if;
  delete from public.casino_votes where table_id = p_t and user_id = s.user_id;
  perform _casino_touch(p_t);
  return ref;
end $$;

-- ---------- état poker ----------
create or replace function public._pk_seat_extra(p_s public.casino_seats, p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare cards jsonb; ingame boolean := p_s.status in ('active', 'allin'); rev boolean := coalesce((p_t.data->>'reveal')::boolean, false);
begin
  if array_length(p_s.cards, 1) is null then cards := '[]'::jsonb;
  elsif p_s.user_id = p_uid then cards := to_jsonb(p_s.cards);
  elsif rev and ingame and p_t.phase = 'showdown' then cards := to_jsonb(p_s.cards);
  elsif ingame or (p_s.status = 'folded' and false) then cards := '["??","??"]'::jsonb;
  else cards := '[]'::jsonb; end if;
  return jsonb_build_object('cards', cards, 'button', p_s.seat = coalesce((p_t.data->>'btn')::int, -1),
    'hand', case when rev and p_t.phase = 'showdown' then p_s.extra->>'hand' end);
end $$;

create or replace function public._pk_extra(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; d public.casino_seats; ta int; cur numeric; mine jsonb; pk jsonb; pot numeric; tc numeric;
begin
  select * into s from public.casino_seats where table_id = p_t.id and user_id = p_uid;
  select * into d from public.casino_seats where table_id = p_t.id and seat = 10;
  ta := (p_t.data->>'to_act')::int; cur := coalesce((p_t.data->>'cur')::numeric, 0);
  if p_t.phase in ('showdown', 'between') and p_t.data->>'pot_final' is not null then pot := (p_t.data->>'pot_final')::numeric;
  else select coalesce(sum(contrib), 0) into pot from public.casino_seats where table_id = p_t.id; end if;
  select coalesce(jsonb_agg(jsonb_build_object('seat', seat, 'cards', cs, 'hand_no', p_t.hand_no) order by seat), '[]'::jsonb) into pk
    from (select seat, jsonb_agg(card order by idx) cs from public.casino_peeks where cheater = p_uid and table_id = p_t.id and hand_no = p_t.hand_no group by seat) q;
  mine := jsonb_build_object('peeks', pk, 'to_act', s.seat is not null and ta is not distinct from s.seat);
  if s.seat is not null then
    tc := greatest(0, cur - s.bet);
    mine := mine || jsonb_build_object('cards', to_jsonb(s.cards), 'bet', s.bet, 'call_amt', least(tc, s.stack), 'min_raise_to', least(cur + coalesce((p_t.data->>'minr')::numeric, 0), s.bet + s.stack), 'max_raise_to', s.bet + s.stack);
  end if;
  return jsonb_build_object('me', mine,
    'dealer', jsonb_build_object('stack', d.stack, 'cards', _pk_seat_extra(d, p_t, p_uid)->'cards', 'status', d.status, 'bet', d.bet, 'last', d.last, 'winner', d.winner, 'button', d.seat = coalesce((p_t.data->>'btn')::int, -1),
      'hand', case when coalesce((p_t.data->>'reveal')::boolean, false) and p_t.phase = 'showdown' then d.extra->>'hand' end),
    'community', coalesce(p_t.data->'community', '[]'::jsonb), 'pot', pot, 'current_bet', cur,
    'to_act', case when ta is null then null when ta = 10 then to_jsonb('dealer'::text) else to_jsonb(ta) end,
    'button', coalesce((p_t.data->>'btn')::int, -1), 'hand_no', p_t.hand_no, 'last_hand', p_t.data->'last_hand');
end $$;

create or replace function public.poker_action(p_table bigint, p_action text, p_amount numeric default 0) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; s public.casino_seats;
begin
  perform public.rate_ok('casino_act', 240, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if not found or t.game <> 'poker' then raise exception 'Table introuvable'; end if;
  select * into s from public.casino_seats where table_id = p_table and user_id = uid;
  if not found then raise exception 'Vous devez être assis à cette table'; end if;
  if t.phase not in ('preflop', 'flop', 'turn', 'river') then raise exception 'Phase incorrecte'; end if;
  if (t.data->>'to_act')::int is distinct from s.seat then raise exception 'Ce n’est pas votre tour'; end if;
  if p_action not in ('fold', 'check', 'call', 'raise', 'allin') then raise exception 'Action invalide'; end if;
  update public.casino_seats set seen_at = _casino_now() where table_id = p_table and seat = s.seat;
  perform _pk_apply(p_table, s.seat, p_action, p_amount);
  perform _casino_tick(p_table);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- triche au poker ----------
create or replace function public._pk_cheat_me(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare cd int := 0; bl jsonb; att jsonb; al jsonb; last_st timestamptz; r record;
begin
  -- détections de bots arrivées à échéance
  update public.casino_cheats set status = 'caught' where table_id = p_t.id and status = 'running' and target_bot and catch_at is not null and catch_at <= _casino_now();
  select max(started) into last_st from public.casino_cheats where cheater = p_uid;
  if last_st is not null then cd := greatest(0, round(extract(epoch from (last_st + make_interval(secs => _casino_ccn('cheat_cooldown_s')::double precision) - _casino_now())) * 1000))::int; end if;
  select coalesce(jsonb_agg(distinct target_seat), '[]'::jsonb) into bl from public.casino_cheats where cheater = p_uid and table_id = p_t.id and hand_no = p_t.hand_no and status in ('caught', 'failed');
  select jsonb_build_object('id', id, 'seat', target_seat, 'left_ms', _casino_ms_left(ends), 'clicks', clicks, 'need', need) into att
    from public.casino_cheats where cheater = p_uid and table_id = p_t.id and status = 'running' order by id desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('attempt', c.id, 'seat', coalesce(c.cheater_seat, -1), 'username', pr.username, 'left_ms', _casino_ms_left(c.ends)) order by c.id), '[]'::jsonb) into al
    from public.casino_cheats c join public.profiles pr on pr.id = c.cheater where c.table_id = p_t.id and c.target_user = p_uid and c.status = 'running' and c.ends > _casino_now();
  return jsonb_build_object('alarms', al, 'cheat', jsonb_build_object('cooldown_ms', cd, 'blocked_seats', bl, 'attempt', att));
end $$;

create or replace function public.casino_cheat_start(p_table bigint, p_seat int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; tg public.casino_seats; me public.casino_seats; last_st timestamptz; pidx int; aid bigint; isbot boolean; secs numeric := _casino_ccn('cheat_secs'); need int := _casino_ccn('cheat_need')::int;
begin
  perform public.rate_ok('casino_cheat', 20, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if not found or t.game <> 'poker' then raise exception 'On ne triche qu’au poker'; end if;
  if t.phase not in ('preflop', 'flop', 'turn', 'river') then raise exception 'Aucune main en cours'; end if;
  select * into tg from public.casino_seats where table_id = p_table and seat = p_seat;
  if not found or tg.status not in ('active', 'allin') or array_length(tg.cards, 1) is null then raise exception 'Cette personne n’a pas de cartes en jeu'; end if;
  select * into me from public.casino_seats where table_id = p_table and user_id = uid;
  if found and me.seat = p_seat then raise exception 'Vous ne pouvez pas vous observer vous-même'; end if;
  if exists(select 1 from public.casino_cheats where cheater = uid and status = 'running' and ends > _casino_now()) then raise exception 'Une observation est déjà en cours'; end if;
  select max(started) into last_st from public.casino_cheats where cheater = uid;
  if last_st is not null and last_st + make_interval(secs => _casino_ccn('cheat_cooldown_s')::double precision) > _casino_now() then raise exception 'Triche en recharge, patientez'; end if;
  if _casino_ccn('cheat_ignore_block') = 0 and exists(select 1 from public.casino_cheats where cheater = uid and table_id = p_table and hand_no = t.hand_no and target_seat = p_seat and status in ('caught', 'failed')) then
    raise exception 'Vous ne pouvez plus observer cette personne pendant cette partie'; end if;
  select count(*) into pidx from public.casino_peeks where cheater = uid and table_id = p_table and hand_no = t.hand_no and seat = p_seat;
  if pidx >= 2 then raise exception 'Vous connaissez déjà ses deux cartes'; end if;
  isbot := tg.kind in ('bot', 'dealer');
  insert into public.casino_cheats(table_id, hand_no, cheater, cheater_seat, target_seat, target_user, target_bot, need, started, ends, catch_at)
    values (p_table, t.hand_no, uid, me.seat, p_seat, tg.user_id, isbot, need, _casino_now(), _casino_now() + make_interval(secs => secs::double precision),
      case when isbot and _casino_rfloat() < _casino_ccn('cheat_bot_p') then _casino_now() + make_interval(secs => (secs * (0.15 + _casino_rfloat() * 0.8))::double precision) end)
    returning casino_cheats.id into aid;
  perform _casino_touch(p_table);
  return jsonb_build_object('attempt', aid, 'secs', secs::int, 'need', need);
end $$;

create or replace function public.casino_cheat_click(p_attempt bigint, p_n int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); c public.casino_cheats; el numeric; cap int; n int := greatest(0, least(coalesce(p_n, 0), 12));
begin
  select * into c from public.casino_cheats where id = p_attempt and cheater = uid for update;
  if not found then raise exception 'Observation introuvable'; end if;
  if c.status = 'running' and c.target_bot and c.catch_at is not null and c.catch_at <= _casino_now() then update public.casino_cheats set status = 'caught' where id = c.id; c.status := 'caught'; end if;
  if c.status <> 'running' then return jsonb_build_object('clicks', c.clicks, 'left_ms', 0, 'status', c.status); end if;
  if c.ends <= _casino_now() then return jsonb_build_object('clicks', c.clicks, 'left_ms', 0, 'status', 'running'); end if;
  el := extract(epoch from (_casino_now() - c.started));
  cap := floor(_casino_ccn('cheat_max_cps') * el)::int + 12;
  update public.casino_cheats set clicks = least(clicks + n, cap), last_click = _casino_now() where id = c.id returning clicks into c.clicks;
  return jsonb_build_object('clicks', c.clicks, 'left_ms', _casino_ms_left(c.ends), 'status', 'running');
end $$;

create or replace function public.casino_cheat_catch(p_attempt bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); c public.casino_cheats;
begin
  select * into c from public.casino_cheats where id = p_attempt for update;
  if not found or c.target_user is distinct from uid then raise exception 'Observation introuvable'; end if;
  if c.status <> 'running' or c.ends <= _casino_now() then raise exception 'Trop tard'; end if;
  update public.casino_cheats set status = 'caught' where id = c.id;
  perform _casino_log(c.table_id, 'Un tricheur a été repéré.');
  perform _casino_touch(c.table_id);
  return jsonb_build_object('caught', true);
end $$;

create or replace function public.casino_cheat_result(p_attempt bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); c public.casino_cheats; t public.casino_tables; tg public.casino_seats; vidx int; vcard text;
begin
  select * into c from public.casino_cheats where id = p_attempt and cheater = uid for update;
  if not found then raise exception 'Observation introuvable'; end if;
  if c.status = 'running' and c.target_bot and c.catch_at is not null and c.catch_at <= c.ends and c.catch_at <= _casino_now() then update public.casino_cheats set status = 'caught' where id = c.id; c.status := 'caught'; end if;
  if c.status = 'running' then
    if c.ends > _casino_now() then return jsonb_build_object('status', 'running', 'card', null, 'index', null); end if;
    select * into t from public.casino_tables where id = c.table_id;
    select * into tg from public.casino_seats where table_id = c.table_id and seat = c.target_seat;
    if c.clicks >= c.need and t.hand_no = c.hand_no and found and tg.status in ('active', 'allin', 'folded') and array_length(tg.cards, 1) = 2 then
      select count(*) into vidx from public.casino_peeks where cheater = uid and table_id = c.table_id and hand_no = c.hand_no and seat = c.target_seat;
      if vidx >= 2 then update public.casino_cheats set status = 'failed' where id = c.id; return jsonb_build_object('status', 'failed', 'card', null, 'index', null); end if;
      vcard := tg.cards[vidx + 1];
      insert into public.casino_peeks(cheater, table_id, hand_no, seat, idx, card) values (uid, c.table_id, c.hand_no, c.target_seat, vidx, vcard) on conflict do nothing;
      update public.casino_cheats set status = 'success', card = vcard, idx = vidx where id = c.id;
      perform _casino_touch(c.table_id);
      return jsonb_build_object('status', 'success', 'card', vcard, 'index', vidx);
    end if;
    update public.casino_cheats set status = 'failed' where id = c.id;
    return jsonb_build_object('status', 'failed', 'card', null, 'index', null);
  end if;
  return jsonb_build_object('status', c.status, 'card', c.card, 'index', c.idx);
end $$;

-- ---------- I) Blackjack (21) : 6 jeux, le croupier tire jusqu'à 16 et reste sur 17 (même soft), blackjack 3:2, double sur 2 cartes ----------
-- Les mises sont débitées du portefeuille (humains) ou de la réserve (bots) et gardées dans seat.contrib / seat.bet jusqu'au paiement.

create or replace function public._bj_total(p_cards text[]) returns int language plpgsql immutable set search_path = public, extensions as $$
declare t int := 0; a int := 0; c text; r text;
begin
  foreach c in array coalesce(p_cards, '{}'::text[]) loop
    r := substr(c, 1, 1);
    if r = 'A' then a := a + 1; t := t + 11; elsif r in ('T', 'J', 'Q', 'K') then t := t + 10; else t := t + r::int; end if;
  end loop;
  while t > 21 and a > 0 loop t := t - 10; a := a - 1; end loop;
  return t;
end $$;

create or replace function public._bj_draw(p_t bigint) returns text language plpgsql security definer set search_path = public, extensions as $$
declare c text; d text[];
begin
  select deck into d from public.casino_tables where id = p_t;
  if d is null or array_length(d, 1) is null then d := _casino_deck(6); end if;
  c := d[1];
  update public.casino_tables set deck = case when array_length(d, 1) > 1 then d[2:array_length(d, 1)] else '{}'::text[] end where id = p_t;
  return c;
end $$;

create or replace function public._bj_new_round(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; r record; hum int;
begin
  select * into t from public.casino_tables where id = p_t;
  for r in select seat from public.casino_seats where table_id = p_t and kind = 'bot' and stack < t.min_bet loop perform _casino_drop_seat(p_t, r.seat); end loop;
  select count(*) into hum from public.casino_seats where table_id = p_t and kind = 'human';
  if coalesce(array_length(t.deck, 1), 0) < 80 then update public.casino_tables set deck = _casino_deck(6) where id = p_t; end if;
  update public.casino_seats set bet = 0, contrib = 0, cards = '{}', last = null, winner = false, acted = false, extra = '{}',
    status = case when kind in ('human', 'bot') then 'betting' else 'waiting' end,
    due = case when kind = 'bot' then _casino_botdue() else null end where table_id = p_t;
  update public.casino_tables set data = data || jsonb_build_object('round', coalesce((data->>'round')::int, 0) + 1, 'to_act', null, 'reveal', false) where id = p_t;
  if hum > 0 then perform _casino_phase(p_t, 'betting', _casino_ms(_casino_ccn('bj_bet_s')));
  else perform _casino_phase(p_t, 'betting', null); end if;
end $$;

create or replace function public._bj_kick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables;
begin
  select * into t from public.casino_tables where id = p_t;
  if t.phase = 'betting' and t.deadline is null then
    update public.casino_seats set due = _casino_botdue() where table_id = p_t and kind = 'bot' and due is null;
    perform _casino_phase(p_t, 'betting', _casino_ms(_casino_ccn('bj_bet_s')));
  end if;
end $$;

create or replace function public._bj_set_due(p_t bigint, p_seat int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; d timestamptz; tot int;
begin
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat;
  if s.kind = 'human' then tot := _casino_ms(_casino_ccn('bj_play_s')); d := _casino_now() + make_interval(secs => tot / 1000.0); else tot := null; d := _casino_botdue(); end if;
  update public.casino_seats set due = d where table_id = p_t and seat = p_seat;
  update public.casino_tables set deadline = d, phase_total_ms = tot, data = data || jsonb_build_object('to_act', p_seat), version = version + 1 where id = p_t;
end $$;

create or replace function public._bj_deal(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare seats int[]; sn int; k int; dn boolean;
begin
  seats := array(select seat from public.casino_seats where table_id = p_t and kind in ('human', 'bot') and bet > 0 order by seat);
  if array_length(seats, 1) is null then perform _bj_new_round(p_t); return; end if;
  update public.casino_seats set status = case when seat = any(seats) then 'playing' else 'waiting' end where table_id = p_t and seat <= 9;
  for k in 1..2 loop
    foreach sn in array seats loop
      update public.casino_seats set cards = cards || _bj_draw(p_t) where table_id = p_t and seat = sn;
    end loop;
    update public.casino_seats set cards = cards || _bj_draw(p_t) where table_id = p_t and seat = 10;
  end loop;
  update public.casino_seats set status = 'blackjack' where table_id = p_t and seat = any(seats) and _bj_total(cards) = 21;
  perform _casino_log(p_t, 'Distribution des cartes.');
  select _bj_total(cards) = 21 into dn from public.casino_seats where table_id = p_t and seat = 10;
  if dn then
    update public.casino_tables set data = data || jsonb_build_object('reveal', true, 'to_act', null) where id = p_t;
    perform _bj_resolve(p_t);
    return;
  end if;
  update public.casino_tables set data = data || jsonb_build_object('to_act', null) where id = p_t;
  perform _casino_phase(p_t, 'dealing', _casino_ms(_casino_ccn('bj_deal_s')));
end $$;

create or replace function public._bj_next(p_t bigint, p_from int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare nxt int;
begin
  select min(seat) into nxt from public.casino_seats where table_id = p_t and seat > p_from and seat <= 9 and status = 'playing';
  if nxt is not null then
    if (select phase from public.casino_tables where id = p_t) <> 'playing' then perform _casino_phase(p_t, 'playing', null); end if;
    perform _bj_set_due(p_t, nxt);
  else
    update public.casino_tables set data = data || jsonb_build_object('reveal', true, 'to_act', null) where id = p_t;
    perform _casino_phase(p_t, 'dealer', _casino_ms(_casino_ccn('bj_dealer_step_s')));
  end if;
end $$;

create or replace function public._bj_do(p_t bigint, p_seat int, p_act text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; c text; tot int; t public.casino_tables;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat for update;
  if p_act = 'stand' then
    update public.casino_seats set status = 'stand', last = 'Reste', due = null where table_id = p_t and seat = p_seat;
  elsif p_act = 'hit' then
    c := _bj_draw(p_t);
    update public.casino_seats set cards = cards || c, last = 'Tire' where table_id = p_t and seat = p_seat returning _bj_total(cards) into tot;
    if tot > 21 then update public.casino_seats set status = 'bust', last = 'Brûlé', due = null where table_id = p_t and seat = p_seat;
    elsif tot = 21 then update public.casino_seats set status = 'stand', due = null where table_id = p_t and seat = p_seat;
    else perform _bj_set_due(p_t, p_seat); return; end if;
  elsif p_act = 'double' then
    if array_length(s.cards, 1) <> 2 then raise exception 'Doubler n’est possible qu’avec deux cartes'; end if;
    if s.kind = 'human' then perform _casino_move(s.user_id, -s.bet, 'casino : double ' || t.name);
    else
      if s.stack < s.bet then raise exception 'Solde insuffisant'; end if;
      update public.casino_seats set stack = stack - s.bet where table_id = p_t and seat = p_seat;
    end if;
    c := _bj_draw(p_t);
    update public.casino_seats set cards = cards || c, contrib = contrib + bet, bet = bet * 2, extra = extra || '{"doubled":true}'::jsonb, last = 'Double' where table_id = p_t and seat = p_seat returning _bj_total(cards) into tot;
    update public.casino_seats set status = case when tot > 21 then 'bust' else 'stand' end, due = null where table_id = p_t and seat = p_seat;
  else raise exception 'Action invalide'; end if;
  perform _bj_next(p_t, p_seat);
end $$;

create or replace function public._bj_bot_act(p_t bigint, p_seat int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; tot int; up int; dc text;
begin
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat;
  select cards[1] into dc from public.casino_seats where table_id = p_t and seat = 10;
  up := _bj_total(array[dc]); tot := _bj_total(s.cards);
  if array_length(s.cards, 1) = 2 and tot in (10, 11) and s.stack >= s.bet and _casino_rfloat() < 0.4 then perform _bj_do(p_t, p_seat, 'double');
  elsif tot <= 11 then perform _bj_do(p_t, p_seat, 'hit');
  elsif tot >= 17 then perform _bj_do(p_t, p_seat, 'stand');
  elsif up >= 7 then perform _bj_do(p_t, p_seat, 'hit');
  else perform _bj_do(p_t, p_seat, 'stand'); end if;
end $$;

create or replace function public._bj_resolve(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; r record; dc text[]; dt int; dbj boolean; pt int; pay numeric; res text; uid uuid; total_bank numeric := 0;
begin
  select * into t from public.casino_tables where id = p_t;
  select cards into dc from public.casino_seats where table_id = p_t and seat = 10;
  dt := _bj_total(dc); dbj := array_length(dc, 1) = 2 and dt = 21;
  for r in select * from public.casino_seats where table_id = p_t and seat <= 9 and kind in ('human', 'bot') and bet > 0 loop
    pt := _bj_total(r.cards);
    if r.status = 'blackjack' and array_length(r.cards, 1) = 2 then
      if dbj then pay := r.bet; res := 'push'; else pay := r.bet * 2.5; res := 'blackjack'; end if;
    elsif r.status = 'bust' or pt > 21 then pay := 0; res := 'lose';
    elsif dbj then pay := 0; res := 'lose';
    elsif dt > 21 or pt > dt then pay := r.bet * 2; res := 'win';
    elsif pt = dt then pay := r.bet; res := 'push';
    else pay := 0; res := 'lose'; end if;
    if pay > 0 then
      if r.kind = 'human' then perform _casino_move(r.user_id, pay, 'casino : gain 21 ' || t.name);
      else update public.casino_seats set stack = stack + pay where table_id = p_t and seat = r.seat; end if;
    end if;
    perform _casino_bank(r.contrib - pay, '21 ' || t.name);
    update public.casino_seats set contrib = 0, status = 'done', winner = res in ('win', 'blackjack'), extra = extra || jsonb_build_object('result', res, 'payout', pay),
      last = case res when 'win' then 'Gagne' when 'blackjack' then 'Blackjack' when 'push' then 'Égalité' else 'Perd' end where table_id = p_t and seat = r.seat;
  end loop;
  update public.casino_tables set data = data || jsonb_build_object('reveal', true, 'to_act', null) where id = p_t;
  perform _casino_phase(p_t, 'payout', _casino_ms(_casino_ccn('bj_payout_s')));
end $$;

create or replace function public._bj_tick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; v0 bigint; i int; s public.casino_seats; r record; ta int; dt int; alive boolean; a numeric; hum int;
begin
  for i in 1..6 loop
    select * into t from public.casino_tables where id = p_t; v0 := t.version;
    if t.phase = 'betting' then
      if t.deadline is null then perform _bj_kick(p_t); end if;
      for r in select * from public.casino_seats where table_id = p_t and kind = 'bot' and bet = 0 and due is not null and due <= _casino_now() loop
        if r.stack < t.min_bet then perform _casino_drop_seat(p_t, r.seat);
        else
          a := least(r.stack, t.min_bet * (1 + _casino_rand(5)));
          update public.casino_seats set stack = stack - a, bet = a, contrib = a, due = null, last = 'Mise ' || a::bigint where table_id = p_t and seat = r.seat;
          perform _casino_touch(p_t);
        end if;
      end loop;
      select * into t from public.casino_tables where id = p_t;
      if t.deadline is not null and t.deadline <= _casino_now() then perform _bj_deal(p_t); end if;
    elsif t.phase = 'dealing' then
      if t.deadline <= _casino_now() then perform _bj_next(p_t, -1); end if;
    elsif t.phase = 'playing' then
      ta := (t.data->>'to_act')::int;
      select * into s from public.casino_seats where table_id = p_t and seat = ta;
      if not found or s.status <> 'playing' then perform _bj_next(p_t, coalesce(ta, -1));
      elsif s.due is not null and s.due <= _casino_now() then
        if s.kind = 'human' then perform _bj_do(p_t, ta, 'stand'); else perform _bj_bot_act(p_t, ta); end if;
      end if;
    elsif t.phase = 'dealer' then
      if t.deadline <= _casino_now() then
        select _bj_total(cards) into dt from public.casino_seats where table_id = p_t and seat = 10;
        select exists(select 1 from public.casino_seats where table_id = p_t and seat <= 9 and status = 'stand') into alive;
        if alive and dt < 17 then
          update public.casino_seats set cards = cards || _bj_draw(p_t), last = 'Tire' where table_id = p_t and seat = 10;
          perform _casino_phase(p_t, 'dealer', _casino_ms(_casino_ccn('bj_dealer_step_s')));
        else perform _bj_resolve(p_t); end if;
      end if;
    elsif t.phase = 'payout' then
      if t.deadline <= _casino_now() then perform _bj_new_round(p_t); end if;
    end if;
    exit when (select version from public.casino_tables where id = p_t) = v0;
  end loop;
end $$;

create or replace function public._bj_leave(p_t bigint, p_seat int) returns numeric language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s public.casino_seats; ref numeric := 0; ta int;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat for update;
  if not found then return 0; end if;
  ta := (t.data->>'to_act')::int;
  if s.contrib > 0 then
    if t.phase = 'betting' then ref := s.contrib; perform _casino_move(s.user_id, ref, 'casino : mise rendue ' || t.name);
    else perform _casino_bank(s.contrib, '21 abandon ' || t.name); end if;
  end if;
  delete from public.casino_seats where table_id = p_t and seat = p_seat;
  delete from public.casino_votes where table_id = p_t and user_id = s.user_id;
  perform _casino_log(p_t, s.name || ' quitte la table.');
  if t.phase = 'playing' and ta = p_seat then perform _bj_next(p_t, p_seat); end if;
  perform _casino_touch(p_t);
  return ref;
end $$;

create or replace function public._bj_seat_extra(p_s public.casino_seats, p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  return jsonb_build_object('cards', to_jsonb(p_s.cards), 'hand', jsonb_build_object('cards', to_jsonb(p_s.cards), 'total', case when array_length(p_s.cards, 1) is null then null else _bj_total(p_s.cards) end,
    'bet', p_s.bet, 'doubled', coalesce((p_s.extra->>'doubled')::boolean, false), 'result', p_s.extra->>'result', 'payout', coalesce((p_s.extra->>'payout')::numeric, 0)));
end $$;

create or replace function public._bj_extra(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; d public.casino_seats; rev boolean := coalesce((p_t.data->>'reveal')::boolean, false); ta int; dcards jsonb; mine jsonb;
begin
  select * into s from public.casino_seats where table_id = p_t.id and user_id = p_uid;
  select * into d from public.casino_seats where table_id = p_t.id and seat = 10;
  ta := (p_t.data->>'to_act')::int;
  dcards := case when array_length(d.cards, 1) is null then '[]'::jsonb when rev then to_jsonb(d.cards) else jsonb_build_array(d.cards[1], '??') end;
  mine := jsonb_build_object('to_act', s.seat is not null and ta is not distinct from s.seat, 'cards', coalesce(to_jsonb(s.cards), '[]'::jsonb),
    'bets', case when s.seat is not null and s.contrib > 0 then jsonb_build_array(jsonb_build_object('kind', 'bj', 'value', '', 'amount', s.bet)) else '[]'::jsonb end,
    'can_double', s.seat is not null and ta is not distinct from s.seat and array_length(s.cards, 1) = 2);
  return jsonb_build_object('me', mine, 'dealer', jsonb_build_object('cards', dcards, 'total', case when array_length(d.cards, 1) is null then null when rev then _bj_total(d.cards) else null end, 'last', d.last),
    'to_act', ta, 'round', coalesce((p_t.data->>'round')::int, 0));
end $$;

create or replace function public.bj_bet(p_table bigint, p_amount numeric) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; s public.casino_seats; a numeric := floor(coalesce(p_amount, 0));
begin
  perform public.rate_ok('casino_bet', 240, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if not found or t.game <> 'blackjack' then raise exception 'Table introuvable'; end if;
  select * into s from public.casino_seats where table_id = p_table and user_id = uid;
  if not found then raise exception 'Vous devez être assis à cette table'; end if;
  if t.phase <> 'betting' then raise exception 'Phase incorrecte'; end if;
  if a <= 0 or s.bet + a > t.max_bet or (s.bet = 0 and a < t.min_bet) then raise exception 'Mise hors limites'; end if;
  perform _casino_move(uid, -a, 'casino : mise 21 ' || t.name);
  update public.casino_seats set bet = bet + a, contrib = contrib + a, seen_at = _casino_now(), last = 'Mise ' || (bet + a)::bigint, status = 'betting' where table_id = p_table and seat = s.seat;
  perform _casino_touch(p_table);
  return jsonb_build_object('ok', true, 'bet', s.bet + a);
end $$;

create or replace function public.bj_action(p_table bigint, p_action text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; s public.casino_seats;
begin
  perform public.rate_ok('casino_act', 240, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if not found or t.game <> 'blackjack' then raise exception 'Table introuvable'; end if;
  select * into s from public.casino_seats where table_id = p_table and user_id = uid;
  if not found then raise exception 'Vous devez être assis à cette table'; end if;
  if t.phase <> 'playing' then raise exception 'Phase incorrecte'; end if;
  if (t.data->>'to_act')::int is distinct from s.seat then raise exception 'Ce n’est pas votre tour'; end if;
  if p_action not in ('hit', 'stand', 'double') then raise exception 'Action invalide'; end if;
  update public.casino_seats set seen_at = _casino_now() where table_id = p_table and seat = s.seat;
  perform _bj_do(p_table, s.seat, p_action);
  perform _casino_tick(p_table);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- J) Roulette européenne (0..36) ----------
-- tables.data : round, result, history[], spin{id,duration_ms}, payouts{seat:montant}. Les mises sont gardées dans seat.contrib (et casino_bets) jusqu'au paiement.

create or replace function public._rl_mult(p_kind text, p_value text, p_n int) returns numeric language plpgsql immutable set search_path = public, extensions as $$
declare red int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]; a int; b int;
begin
  case p_kind
    when 'straight' then return case when p_n = p_value::int then 35 else -1 end;
    when 'red' then return case when p_n = any(red) then 1 else -1 end;
    when 'black' then return case when p_n > 0 and not p_n = any(red) then 1 else -1 end;
    when 'odd' then return case when p_n > 0 and p_n % 2 = 1 then 1 else -1 end;
    when 'even' then return case when p_n > 0 and p_n % 2 = 0 then 1 else -1 end;
    when 'low' then return case when p_n between 1 and 18 then 1 else -1 end;
    when 'high' then return case when p_n between 19 and 36 then 1 else -1 end;
    when 'dozen' then return case when p_n > 0 and (p_n - 1) / 12 + 1 = p_value::int then 2 else -1 end;
    when 'column' then return case when p_n > 0 and (case when p_n % 3 = 0 then 3 else p_n % 3 end) = p_value::int then 2 else -1 end;
    when 'split' then
      a := split_part(p_value, '-', 1)::int; b := split_part(p_value, '-', 2)::int;
      return case when p_n = a or p_n = b then 17 else -1 end;
    else return -1;
  end case;
end $$;

create or replace function public._rl_valid(p_kind text, p_value text) returns boolean language plpgsql immutable set search_path = public, extensions as $$
declare a int; b int; lo int; hi int;
begin
  if p_kind in ('red', 'black', 'odd', 'even', 'low', 'high') then return true; end if;
  if p_kind = 'straight' then return p_value ~ '^[0-9]{1,2}$' and p_value::int between 0 and 36; end if;
  if p_kind in ('dozen', 'column') then return p_value in ('1', '2', '3'); end if;
  if p_kind = 'split' then
    if p_value !~ '^[0-9]{1,2}-[0-9]{1,2}$' then return false; end if;
    a := split_part(p_value, '-', 1)::int; b := split_part(p_value, '-', 2)::int;
    lo := least(a, b); hi := greatest(a, b);
    if lo < 0 or hi > 36 or lo = hi then return false; end if;
    if lo = 0 then return hi in (1, 2, 3); end if;
    return (hi = lo + 1 and lo % 3 <> 0) or hi = lo + 3;
  end if;
  return false;
end $$;

create or replace function public._rl_kick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables;
begin
  select * into t from public.casino_tables where id = p_t;
  if t.phase = 'betting' and t.deadline is null then
    update public.casino_seats set due = _casino_botdue() where table_id = p_t and kind = 'bot' and due is null;
    perform _casino_phase(p_t, 'betting', _casino_ms(_casino_ccn('rl_bet_s')));
  end if;
end $$;

create or replace function public._rl_new_round(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; r record; hum int;
begin
  select * into t from public.casino_tables where id = p_t;
  delete from public.casino_seats where table_id = p_t and kind = 'human' and status = 'leaving';
  for r in select seat from public.casino_seats where table_id = p_t and kind = 'bot' and stack < t.min_bet loop perform _casino_drop_seat(p_t, r.seat); end loop;
  delete from public.casino_bets where table_id = p_t;
  update public.casino_seats set bet = 0, contrib = 0, last = null, winner = false, status = 'betting', extra = '{}', due = case when kind = 'bot' then _casino_botdue() else null end where table_id = p_t and seat <= 9;
  update public.casino_tables set data = data || jsonb_build_object('round', coalesce((data->>'round')::int, 0) + 1, 'result', null, 'payouts', '{}'::jsonb) where id = p_t;
  select count(*) into hum from public.casino_seats where table_id = p_t and kind = 'human';
  if hum > 0 then perform _casino_phase(p_t, 'betting', _casino_ms(_casino_ccn('rl_bet_s'))); else perform _casino_phase(p_t, 'betting', null); end if;
end $$;

-- le tirage : choisi côté serveur quand les mises sont closes
create or replace function public._rl_spin(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; n int := _casino_rand(37); h jsonb; dur int := _casino_ms(_casino_ccn('rl_spin_s')); rd int;
begin
  select * into t from public.casino_tables where id = p_t;
  rd := coalesce((t.data->>'round')::int, 1);
  h := (coalesce(t.data->'history', '[]'::jsonb) || to_jsonb(n));
  while jsonb_array_length(h) > 20 loop h := h - 0; end loop;
  update public.casino_tables set data = data || jsonb_build_object('result', n, 'history', h, 'spin', jsonb_build_object('id', rd, 'duration_ms', dur)) where id = p_t;
  perform _casino_log(p_t, 'La bille est lancée…');
  perform _casino_phase(p_t, 'spinning', dur);
end $$;

create or replace function public._rl_payout(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; n int; r record; b record; pay numeric; pays jsonb := '{}'; uid uuid;
begin
  select * into t from public.casino_tables where id = p_t;
  n := (t.data->>'result')::int;
  for r in select * from public.casino_seats where table_id = p_t and seat <= 9 and contrib > 0 loop
    pay := 0;
    for b in select * from public.casino_bets where table_id = p_t and seat = r.seat loop
      if _rl_mult(b.kind, b.value, n) >= 0 then pay := pay + b.amount * (_rl_mult(b.kind, b.value, n) + 1); end if;
    end loop;
    uid := coalesce(r.user_id, nullif(r.extra->>'uid', '')::uuid);
    if pay > 0 then
      if r.kind = 'human' and uid is not null then perform _casino_move(uid, pay, 'casino : gain roulette ' || t.name);
      elsif r.kind = 'bot' then update public.casino_seats set stack = stack + pay where table_id = p_t and seat = r.seat; end if;
    end if;
    perform _casino_bank(r.contrib - pay, 'roulette ' || t.name);
    pays := pays || jsonb_build_object(r.seat::text, pay);
    update public.casino_seats set contrib = 0, winner = pay > r.contrib, last = case when pay > r.contrib then 'Gagne ' || (pay - r.contrib)::bigint when pay > 0 then 'Récupère ' || pay::bigint else 'Perd ' || r.contrib::bigint end where table_id = p_t and seat = r.seat;
  end loop;
  update public.casino_tables set data = data || jsonb_build_object('payouts', pays) where id = p_t;
  perform _casino_log(p_t, 'Le ' || n || ' sort.');
  perform _casino_phase(p_t, 'result', _casino_ms(_casino_ccn('rl_result_s')));
end $$;

create or replace function public._rl_tick(p_t bigint) returns void language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; v0 bigint; i int; r record; a numeric; k text[] := array['red', 'black', 'odd', 'even', 'low', 'high']; nb int; bk text; bv text; nbets int; tot numeric;
begin
  for i in 1..6 loop
    select * into t from public.casino_tables where id = p_t; v0 := t.version;
    if t.phase = 'betting' then
      if t.deadline is null then perform _rl_kick(p_t); end if;
      for r in select * from public.casino_seats where table_id = p_t and kind = 'bot' and due is not null and due <= _casino_now() loop
        if r.stack < t.min_bet then perform _casino_drop_seat(p_t, r.seat);
        else
          nb := 1 + _casino_rand(3);
          for nbets in 1..nb loop
            select stack into tot from public.casino_seats where table_id = p_t and seat = r.seat;
            a := least(tot, t.min_bet * (1 + _casino_rand(8)));
            exit when a < t.min_bet;
            if _casino_rand(3) = 0 then bk := 'straight'; bv := _casino_rand(37)::text; else bk := k[_casino_rand(6) + 1]; bv := ''; end if;
            insert into public.casino_bets(table_id, round, seat, user_id, kind, value, amount) values (p_t, coalesce((t.data->>'round')::int, 1), r.seat, null, bk, bv, a)
              on conflict (table_id, round, seat, kind, value) do update set amount = least(casino_bets.amount + a, t.max_bet);
            update public.casino_seats set stack = stack - a, contrib = contrib + a, bet = bet + a where table_id = p_t and seat = r.seat;
          end loop;
          update public.casino_seats set due = null, last = 'Mise' where table_id = p_t and seat = r.seat;
          perform _casino_touch(p_t);
        end if;
      end loop;
      select * into t from public.casino_tables where id = p_t;
      if t.deadline is not null and t.deadline <= _casino_now() then
        if exists(select 1 from public.casino_seats where table_id = p_t and contrib > 0) then perform _rl_spin(p_t);
        else perform _casino_phase(p_t, 'betting', _casino_ms(_casino_ccn('rl_bet_s'))); end if;
      end if;
    elsif t.phase = 'spinning' then
      if t.deadline <= _casino_now() then perform _rl_payout(p_t); end if;
    elsif t.phase = 'result' then
      if t.deadline <= _casino_now() then perform _rl_new_round(p_t); end if;
    end if;
    exit when (select version from public.casino_tables where id = p_t) = v0;
  end loop;
end $$;

create or replace function public._rl_leave(p_t bigint, p_seat int) returns numeric language plpgsql security definer set search_path = public, extensions as $$
declare t public.casino_tables; s public.casino_seats; ref numeric := 0;
begin
  select * into t from public.casino_tables where id = p_t;
  select * into s from public.casino_seats where table_id = p_t and seat = p_seat for update;
  if not found then return 0; end if;
  if t.phase = 'spinning' and s.contrib > 0 then
    -- les mises restent jouées : le gain sera versé au paiement, puis le siège disparaît
    update public.casino_seats set status = 'leaving', extra = jsonb_build_object('uid', s.user_id), user_id = null where table_id = p_t and seat = p_seat;
    delete from public.casino_votes where table_id = p_t and user_id = s.user_id;
    perform _casino_touch(p_t);
    return 0;
  end if;
  if s.contrib > 0 and t.phase = 'betting' then
    ref := s.contrib; perform _casino_move(s.user_id, ref, 'casino : mises rendues ' || t.name);
    delete from public.casino_bets where table_id = p_t and seat = p_seat;
  end if;
  delete from public.casino_seats where table_id = p_t and seat = p_seat;
  delete from public.casino_votes where table_id = p_t and user_id = s.user_id;
  perform _casino_log(p_t, s.name || ' quitte la table.');
  perform _casino_touch(p_t);
  return ref;
end $$;

create or replace function public._rl_extra(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; mb jsonb := '[]'::jsonb; mine numeric := 0; tbl numeric := 0; lp numeric := 0; rd int := coalesce((p_t.data->>'round')::int, 1); shown boolean := p_t.phase in ('spinning', 'result');
begin
  select * into s from public.casino_seats where table_id = p_t.id and user_id = p_uid;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'value', value, 'amount', amount) order by kind, value), '[]'::jsonb), coalesce(sum(amount), 0) into mb, mine
      from public.casino_bets where table_id = p_t.id and seat = s.seat and round = rd;
    lp := coalesce((p_t.data->'payouts'->>(s.seat::text))::numeric, 0);
  end if;
  select coalesce(sum(amount), 0) into tbl from public.casino_bets where table_id = p_t.id and round = rd;
  return jsonb_build_object('me', jsonb_build_object('bets', mb, 'to_act', false, 'cards', '[]'::jsonb),
    'result', case when shown then p_t.data->'result' else null end, 'history', coalesce(p_t.data->'history', '[]'::jsonb), 'spin', p_t.data->'spin',
    'totals', jsonb_build_object('mine', mine, 'table', tbl), 'last_payout', case when p_t.phase = 'result' then lp else 0 end, 'round', rd);
end $$;

create or replace function public.roulette_bet(p_table bigint, p_kind text, p_value text, p_amount numeric) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; s public.casino_seats; a numeric := floor(coalesce(p_amount, 0)); rd int; cur numeric; v text := coalesce(p_value, '');
begin
  perform public.rate_ok('casino_bet', 240, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if not found or t.game <> 'roulette' then raise exception 'Table introuvable'; end if;
  select * into s from public.casino_seats where table_id = p_table and user_id = uid;
  if not found then raise exception 'Vous devez être assis à cette table'; end if;
  if t.phase <> 'betting' then raise exception 'Phase incorrecte'; end if;
  if not _rl_valid(p_kind, v) then raise exception 'Mise invalide'; end if;
  if p_kind in ('red', 'black', 'odd', 'even', 'low', 'high') then v := ''; end if;
  rd := coalesce((t.data->>'round')::int, 1);
  select coalesce(amount, 0) into cur from public.casino_bets where table_id = p_table and round = rd and seat = s.seat and kind = p_kind and value = v;
  cur := coalesce(cur, 0);
  if a < t.min_bet and cur = 0 then raise exception 'Mise hors limites'; end if;
  if a <= 0 or cur + a > t.max_bet or s.contrib + a > t.max_bet * 20 then raise exception 'Mise hors limites'; end if;
  perform _casino_move(uid, -a, 'casino : mise roulette ' || t.name);
  insert into public.casino_bets(table_id, round, seat, user_id, kind, value, amount) values (p_table, rd, s.seat, uid, p_kind, v, a)
    on conflict (table_id, round, seat, kind, value) do update set amount = casino_bets.amount + a;
  update public.casino_seats set contrib = contrib + a, bet = bet + a, seen_at = _casino_now(), last = 'Mise' where table_id = p_table and seat = s.seat;
  perform _casino_touch(p_table);
  return jsonb_build_object('ok', true, 'total', s.contrib + a);
end $$;

create or replace function public.roulette_clear(p_table bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; s public.casino_seats; ref numeric;
begin
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  select * into s from public.casino_seats where table_id = p_table and user_id = uid;
  if not found then raise exception 'Vous devez être assis à cette table'; end if;
  if t.phase <> 'betting' then raise exception 'Phase incorrecte'; end if;
  ref := s.contrib;
  if ref > 0 then
    perform _casino_move(uid, ref, 'casino : mises rendues ' || t.name);
    delete from public.casino_bets where table_id = p_table and seat = s.seat;
    update public.casino_seats set contrib = 0, bet = 0, last = null where table_id = p_table and seat = s.seat;
    perform _casino_touch(p_table);
  end if;
  return jsonb_build_object('refunded', ref);
end $$;

-- ---------- K) Machines à sous ----------
-- 3 rouleaux x 3 rangées, 5 lignes de gain (3 horizontales + 2 diagonales). Chaque rouleau tire 3 positions consécutives sur une bande de 20 cases.
-- Symboles : cherry, lemon, bell, bar, seven, diamond, star, joker (joker = remplace tout sauf diamant... voir paytable).
-- Le taux de retour (RTP) est calculé par énumération exacte dans _slots_rtp() ; la table de gains est ajustée pour 92 à 95 %.

create table if not exists public.casino_slot_cfg (k text primary key, v jsonb not null);
alter table public.casino_slot_cfg enable row level security;
revoke all on public.casino_slot_cfg from anon, authenticated;

-- Bande de 20 cases (identique pour les 3 rouleaux) et table de gains ; les gains sont des multiples de la mise PAR LIGNE (mise totale / 5).
-- RTP exact (énumération des 8 000 positions x 5 lignes) = 94,51 %.  Le joker remplace tout sauf le diamant ; deux cerises en début de ligne paient 1,5.
insert into public.casino_slot_cfg(k, v) values
 ('strip', '["cherry","lemon","bell","cherry","bar","lemon","cherry","seven","bell","lemon","cherry","joker","bar","lemon","cherry","diamond","bell","lemon","star","bar"]'),
 ('pay', '{"cherry":8,"lemon":6,"bell":12,"bar":20,"seven":50,"star":100,"diamond":250,"joker":500,"cherry2":1.5}'),
 ('bets', '[1,5,10,50,100,500]'),
 ('labels', '{"cherry":"Cerise","lemon":"Citron","bell":"Cloche","bar":"BAR","seven":"Sept","star":"Étoile","diamond":"Diamant","joker":"Joker"}')
on conflict (k) do update set v = excluded.v;

-- lignes de gain : [rangée, rouleau] ; rangée 0 = haut
create or replace function public._slots_lines() returns int[] language sql immutable as $$
  select array[0,0, 0,1, 0,2,  1,0, 1,1, 1,2,  2,0, 2,1, 2,2,  0,0, 1,1, 2,2,  2,0, 1,1, 0,2] $$;

-- multiplicateur (par ligne) de trois symboles lus de gauche à droite
create or replace function public._slots_pay(p_syms text[], p_pay jsonb) returns numeric language plpgsql immutable set search_path = public, extensions as $$
declare nj int := 0; s text; base text := null; mixed boolean := false;
begin
  foreach s in array p_syms loop
    if s = 'joker' then nj := nj + 1;
    elsif base is null then base := s;
    elsif base <> s then mixed := true; end if;
  end loop;
  if nj = 3 then return (p_pay->>'joker')::numeric; end if;
  if not mixed then
    if base = 'diamond' then return case when nj = 0 then (p_pay->>'diamond')::numeric else 0 end; end if;
    return (p_pay->>base)::numeric;
  end if;
  if p_syms[1] in ('cherry', 'joker') and p_syms[2] in ('cherry', 'joker') then return (p_pay->>'cherry2')::numeric; end if;
  return 0;
end $$;

-- RTP exact par énumération (outil de contrôle, non exposé)
create or replace function public._slots_rtp() returns numeric language plpgsql stable security definer set search_path = public, extensions as $$
declare strip jsonb := (select v from public.casino_slot_cfg where k = 'strip'); pay jsonb := (select v from public.casino_slot_cfg where k = 'pay'); st text[];
  a int; b int; c int; l int; ln int[] := _slots_lines(); tot numeric := 0; g text[]; i int;
begin
  st := array(select jsonb_array_elements_text(strip));
  for a in 0..19 loop for b in 0..19 loop for c in 0..19 loop
    g := array[st[(a) % 20 + 1], st[(b) % 20 + 1], st[(c) % 20 + 1], st[(a + 1) % 20 + 1], st[(b + 1) % 20 + 1], st[(c + 1) % 20 + 1], st[(a + 2) % 20 + 1], st[(b + 2) % 20 + 1], st[(c + 2) % 20 + 1]];
    for l in 0..4 loop
      tot := tot + _slots_pay(array[g[ln[l * 6 + 1] * 3 + ln[l * 6 + 2] + 1], g[ln[l * 6 + 3] * 3 + ln[l * 6 + 4] + 1], g[ln[l * 6 + 5] * 3 + ln[l * 6 + 6] + 1]], pay);
    end loop;
  end loop; end loop; end loop;
  return tot / 8000 / 5;
end $$;

create or replace function public.slots_info(p_machine bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m public.casino_slots; pay jsonb := (select v from public.casino_slot_cfg where k = 'pay'); lbl jsonb := (select v from public.casino_slot_cfg where k = 'labels'); sy jsonb := '[]'::jsonb; sk text; ln int[] := _slots_lines(); pl jsonb := '[]'::jsonb; l int;
begin
  perform _casino_uid();
  select * into m from public.casino_slots where id = p_machine;
  if not found then raise exception 'Machine introuvable'; end if;
  foreach sk in array array['cherry', 'lemon', 'bell', 'bar', 'seven', 'star', 'diamond', 'joker'] loop
    sy := sy || jsonb_build_array(jsonb_build_object('code', sk, 'label', lbl->>sk, 'pays', jsonb_build_object('3', round((pay->>sk)::numeric / 5, 2)) || case when sk = 'cherry' then jsonb_build_object('2', round((pay->>'cherry2')::numeric / 5, 2)) else '{}'::jsonb end));
  end loop;
  for l in 0..4 loop
    pl := pl || jsonb_build_array(jsonb_build_array(jsonb_build_array(ln[l*6+1], ln[l*6+2]), jsonb_build_array(ln[l*6+3], ln[l*6+4]), jsonb_build_array(ln[l*6+5], ln[l*6+6])));
  end loop;
  return jsonb_build_object('symbols', sy, 'paylines', pl, 'bets', (select v from public.casino_slot_cfg where k = 'bets'), 'theme', m.theme, 'name', m.name, 'min_bet', m.min_bet, 'max_bet', m.max_bet,
    'note', 'Les gains sont des multiples de la mise totale, par ligne gagnante (5 lignes).');
end $$;

create or replace function public.slots_spin(p_machine bigint, p_bet numeric) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); m public.casino_slots; st text[]; pay jsonb := (select v from public.casino_slot_cfg where k = 'pay'); bets jsonb := (select v from public.casino_slot_cfg where k = 'bets');
  p int[]; g text[]; l int; ln int[] := _slots_lines(); mult numeric; tot numeric := 0; lines jsonb := '[]'::jsonb; syms text[]; sy text; w numeric; bal numeric; reels jsonb := '[]'::jsonb; c int; r int; n int;
begin
  perform public.rate_ok('casino_slot', _casino_ccn('slot_rate_per_min')::int, 60);
  select * into m from public.casino_slots where id = p_machine;
  if not found then raise exception 'Machine introuvable'; end if;
  if p_bet is null or not bets @> to_jsonb(p_bet) or p_bet < m.min_bet or p_bet > m.max_bet then raise exception 'Mise hors limites'; end if;
  perform _casino_move(uid, -p_bet, 'casino : machine à sous ' || m.name);
  st := array(select jsonb_array_elements_text((select v from public.casino_slot_cfg where k = 'strip')));
  p := array[_casino_rand(20), _casino_rand(20), _casino_rand(20)];
  g := array[st[p[1] % 20 + 1], st[p[2] % 20 + 1], st[p[3] % 20 + 1], st[(p[1] + 1) % 20 + 1], st[(p[2] + 1) % 20 + 1], st[(p[3] + 1) % 20 + 1], st[(p[1] + 2) % 20 + 1], st[(p[2] + 2) % 20 + 1], st[(p[3] + 2) % 20 + 1]];
  for l in 0..4 loop
    syms := array[g[ln[l*6+1] * 3 + ln[l*6+2] + 1], g[ln[l*6+3] * 3 + ln[l*6+4] + 1], g[ln[l*6+5] * 3 + ln[l*6+6] + 1]];
    mult := _slots_pay(syms, pay);
    if mult > 0 then
      w := round(mult * p_bet / 5, 1);
      tot := tot + w;
      sy := coalesce((select s from unnest(syms) s where s <> 'joker' limit 1), 'joker');
      n := case when mult = (pay->>'cherry2')::numeric and not (syms[1] = syms[2] and syms[2] = syms[3]) and sy = 'cherry' and mult < (pay->>'cherry')::numeric then 2 else 3 end;
      lines := lines || jsonb_build_array(jsonb_build_object('line', l + 1, 'symbol', sy, 'n', n, 'pay', w));
    end if;
  end loop;
  if tot > 0 then bal := _casino_move(uid, tot, 'casino : gain machine ' || m.name); else select balance into bal from public.wallets where user_id = uid; end if;
  perform _casino_bank(p_bet - tot, 'machine ' || m.name);
  for c in 0..2 loop
    reels := reels || jsonb_build_array(jsonb_build_array(g[c + 1], g[c + 4], g[c + 7]));
  end loop;
  return jsonb_build_object('reels', reels, 'win', tot, 'lines', lines, 'balance', bal, 'big', tot >= p_bet * 20);
end $$;

-- ---------- L) Lot-Au-MAX! ----------
-- Chaque billet est généré à l'achat, chiffré (pgp_sym_encrypt, clé aléatoire dans casino_secret) et indexé par HMAC pour le scanner.
-- Il n'est déchiffré que pour : gratter une zone, scanner, réclamer. Jeter un billet = supprimer sa ligne.
alter table public.casino_tickets add column if not exists w_zim boolean not null default false;
alter table public.casino_tickets add column if not exists w_tom boolean not null default false;
alter table public.casino_tickets add column if not exists w_pou boolean not null default false;

create or replace function public._lot_label(p_no int) returns text language sql immutable as $$ select 'L-' || lpad(p_no::text, 6, '0') $$;
create or replace function public._lot_hmac(p_code text) returns text language sql stable security definer set search_path = public, extensions as $$
  select encode(hmac(convert_to(upper(p_code), 'UTF8'), convert_to(_casino_key('lot_hmac'), 'UTF8'), 'sha256'), 'hex') $$;
create or replace function public._lot_dec(p_id bigint) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare b bytea;
begin
  select payload into b from public.casino_tickets where id = p_id;
  if b is null then return null; end if;
  return pgp_sym_decrypt(b, _casino_key('lot_key'))::jsonb;
end $$;
create or replace function public._lot_period_of(p_ts timestamptz) returns date language sql immutable as $$ select date_trunc('month', p_ts at time zone 'UTC')::date $$;

-- télé Zimemberg : code de 20 caractères A-Z0-9 dérivé du créneau (213 s), sans table
create or replace function public._lot_zim_slot(p_ts timestamptz default null) returns bigint language sql stable security definer set search_path = public, extensions as $$
  select floor(extract(epoch from coalesce(p_ts, _casino_now())) / _casino_ccn('zim_slot_s'))::bigint $$;
create or replace function public._lot_zim_code(p_slot bigint) returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare h bytea; a text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'; s text := ''; i int;
begin
  h := hmac(convert_to('zim:' || p_slot::text, 'UTF8'), convert_to(_casino_key('lot_hmac'), 'UTF8'), 'sha256');
  for i in 0..19 loop s := s || substr(a, get_byte(h, i) % 36 + 1, 1); end loop;
  return s;
end $$;

-- prix du billet = (somme des cagnottes / nombre de joueurs) x 0,25
create or replace function public._lot_price() returns numeric language sql stable security definer set search_path = public, extensions as $$
  select greatest(_casino_ccn('lot_min_price'), ceil((select coalesce(sum(balance), 0) from public.wallets) / greatest((select count(*) from public.profiles), 1) * _casino_ccn('lot_price_pct'))) $$;
create or replace function public._lot_pot() returns numeric language sql stable security definer set search_path = public, extensions as $$
  select coalesce(sum(delta), 0) from public.casino_pot $$;

-- ---- génération du puzzle Poutinà ----
-- possible : chemins disjoints construits par marches aléatoires (une solution existe).
-- impossible : deux couleurs dont les extrémités sont ENTRELACÉES sur le bord de la grille (A B A B) : insoluble par planarité, quelles que soient les autres couleurs.
create or replace function public._lot_puzzle(p_possible boolean, p_colors int) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare n int; occ int[]; pairs jsonb := '[]'::jsonb; col int; tries int; path int[]; cur int; len int; step int; nb int[]; r int; c int; k int; cand int; ok boolean; guard int := 0;
  per int[] := '{}'; i int; pos int[]; tmp int; a_cell int; b_cell int; free int[]; ord int[]; j int;
begin
  n := case when p_colors <= 7 then 7 when p_colors <= 9 then 8 when p_colors = 10 then 9 else 10 end;
  <<again>>
  loop
    guard := guard + 1; if guard > 200 then raise exception 'Génération du puzzle impossible'; end if;
    occ := array_fill(0, array[n * n]); pairs := '[]'::jsonb;
    if p_possible then
      ok := true;
      for col in 0..p_colors - 1 loop
        tries := 0; path := null;
        while path is null and tries < 60 loop
          tries := tries + 1;
          cur := _casino_rand(n * n);
          if occ[cur + 1] <> 0 then continue; end if;
          path := array[cur]; len := 3 + _casino_rand(5);
          for step in 2..len loop
            r := cur / n; c := cur % n; nb := '{}';
            if r > 0 and occ[(cur - n) + 1] = 0 and not (cur - n) = any(path) then nb := nb || (cur - n); end if;
            if r < n - 1 and occ[(cur + n) + 1] = 0 and not (cur + n) = any(path) then nb := nb || (cur + n); end if;
            if c > 0 and occ[(cur - 1) + 1] = 0 and not (cur - 1) = any(path) then nb := nb || (cur - 1); end if;
            if c < n - 1 and occ[(cur + 1) + 1] = 0 and not (cur + 1) = any(path) then nb := nb || (cur + 1); end if;
            exit when array_length(nb, 1) is null;
            cur := nb[_casino_rand(array_length(nb, 1)) + 1];
            path := path || cur;
          end loop;
          if array_length(path, 1) < 3 then path := null; end if;
        end loop;
        if path is null then ok := false; exit; end if;
        for k in 1..array_length(path, 1) loop occ[path[k] + 1] := col + 1; end loop;
        pairs := pairs || jsonb_build_array(jsonb_build_object('c', col, 'a', jsonb_build_array(path[1] / n, path[1] % n), 'b', jsonb_build_array(path[array_length(path, 1)] / n, path[array_length(path, 1)] % n)));
      end loop;
      if ok then return jsonb_build_object('n', n, 'colors', p_colors, 'pairs', pairs); end if;
    else
      -- périmètre dans l'ordre cyclique
      per := '{}';
      for i in 0..n - 1 loop per := per || i; end loop;
      for i in 1..n - 1 loop per := per || (i * n + n - 1); end loop;
      for i in reverse n - 2..0 loop per := per || ((n - 1) * n + i); end loop;
      for i in reverse n - 2..1 loop per := per || (i * n); end loop;
      -- 4 positions distinctes triées
      pos := '{}';
      while coalesce(array_length(pos, 1), 0) < 4 loop
        tmp := _casino_rand(array_length(per, 1));
        if not tmp = any(pos) then pos := pos || tmp; end if;
      end loop;
      pos := array(select x from unnest(pos) x order by x);
      occ[per[pos[1] + 1] + 1] := 1; occ[per[pos[3] + 1] + 1] := 1; occ[per[pos[2] + 1] + 1] := 2; occ[per[pos[4] + 1] + 1] := 2;
      -- ordre des couleurs mélangé (les deux entrelacées ne sont pas toujours les premières)
      ord := array(select x from generate_series(0, p_colors - 1) x);
      for i in reverse p_colors - 1..1 loop j := _casino_rand(i + 1); tmp := ord[i + 1]; ord[i + 1] := ord[j + 1]; ord[j + 1] := tmp; end loop;
      pairs := pairs || jsonb_build_array(jsonb_build_object('c', ord[1], 'a', jsonb_build_array(per[pos[1] + 1] / n, per[pos[1] + 1] % n), 'b', jsonb_build_array(per[pos[3] + 1] / n, per[pos[3] + 1] % n)));
      pairs := pairs || jsonb_build_array(jsonb_build_object('c', ord[2], 'a', jsonb_build_array(per[pos[2] + 1] / n, per[pos[2] + 1] % n), 'b', jsonb_build_array(per[pos[4] + 1] / n, per[pos[4] + 1] % n)));
      for col in 3..p_colors loop
        loop a_cell := _casino_rand(n * n); exit when occ[a_cell + 1] = 0; end loop;
        occ[a_cell + 1] := col;
        loop b_cell := _casino_rand(n * n); exit when occ[b_cell + 1] = 0; end loop;
        occ[b_cell + 1] := col;
        pairs := pairs || jsonb_build_array(jsonb_build_object('c', ord[col], 'a', jsonb_build_array(a_cell / n, a_cell % n), 'b', jsonb_build_array(b_cell / n, b_cell % n)));
      end loop;
      pairs := (select jsonb_agg(x order by (x->>'c')::int) from jsonb_array_elements(pairs) x);
      return jsonb_build_object('n', n, 'colors', p_colors, 'pairs', pairs);
    end if;
  end loop;
end $$;

-- nombre de couleurs tiré selon la répartition configurée (plus de couleurs = plus rare)
create or replace function public._lot_colors() returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare d text[] := string_to_array(_casino_cc('pou_colors_dist'), ','); x double precision := _casino_rfloat() * 100; acc numeric := 0; e text;
begin
  foreach e in array d loop
    acc := acc + split_part(e, ':', 2)::numeric;
    if x < acc then return split_part(e, ':', 1)::int; end if;
  end loop;
  return 6;
end $$;

-- contenu complet d'un billet
create or replace function public._lot_gen(p_owner uuid) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare fake boolean := _casino_rfloat() < _casino_ccn('lot_fake_p'); zim jsonb; tan jsonb; tom jsonb; pou jsonb; r double precision; kind text := 'none'; amt numeric := 0; cells text[]; syms text[] := array['none','ticket','t25','t50','t500','t10000','t25000'];
  cum double precision := 0; poss boolean; cols int; pz jsonb; slot bigint; same boolean; k int; w_z boolean := false;
begin
  -- Zimemberg : le billet gagnant porte le code de la télé à un créneau futur
  if not fake and _casino_rfloat() < _casino_ccn('zim_win_p') then
    slot := _lot_zim_slot(_casino_now() + make_interval(secs => (_casino_ccn('zim_min_ahead_s') + _casino_rfloat() * (_casino_ccn('zim_max_ahead_s') - _casino_ccn('zim_min_ahead_s')))::double precision));
    zim := jsonb_build_object('code', _lot_zim_code(slot), 'prize', (100 + _casino_rand(401)) * 1000, 'slot', slot);
    w_z := true;
  else zim := jsonb_build_object('code', _casino_rstr(20), 'prize', 0, 'slot', null); end if;
  tan := jsonb_build_object('code', _casino_rstr(15));
  -- Tomateeom : 3 symboles identiques = gagné (un peu truqué : les gros lots sont très rares)
  if not fake then
    r := _casino_rfloat();
    cum := _casino_ccn('tom_p_ticket');   if r < cum then kind := 'ticket'; end if;
    if kind = 'none' then cum := cum + _casino_ccn('tom_p_25');    if r < cum then kind := 't25'; end if; end if;
    if kind = 'none' then cum := cum + _casino_ccn('tom_p_50');    if r < cum then kind := 't50'; end if; end if;
    if kind = 'none' then cum := cum + _casino_ccn('tom_p_500');   if r < cum then kind := 't500'; end if; end if;
    if kind = 'none' then cum := cum + _casino_ccn('tom_p_10000'); if r < cum then kind := 't10000'; end if; end if;
    if kind = 'none' then cum := cum + _casino_ccn('tom_p_25000'); if r < cum then kind := 't25000'; end if; end if;
  end if;
  if kind <> 'none' then cells := array[kind, kind, kind]; amt := case kind when 't25' then 25 when 't50' then 50 when 't500' then 500 when 't10000' then 10000 when 't25000' then 25000 else 0 end;
  else
    loop
      cells := array[syms[_casino_rand(7) + 1], syms[_casino_rand(7) + 1], syms[_casino_rand(7) + 1]];
      exit when not (cells[1] = cells[2] and cells[2] = cells[3]);
    end loop;
  end if;
  tom := jsonb_build_object('code', _casino_rstr(12), 'cells', to_jsonb(cells), 'prize', jsonb_build_object('kind', case kind when 'none' then 'none' when 'ticket' then 'ticket' else 'tokens' end, 'amount', amt));
  -- Poutinà : très rarement possible
  poss := not fake and _casino_rfloat() < _casino_ccn('pou_possible_p');
  cols := _lot_colors();
  pz := _lot_puzzle(poss, cols);
  pou := jsonb_build_object('code', _casino_rstr(50, '0123456789'), 'possible', poss, 'colors', cols, 'n', pz->'n', 'pairs', pz->'pairs', 'medals', 80 + 100 * cols);
  return jsonb_build_object('fake', fake, 'zim', zim, 'tan', tan, 'tom', tom, 'pou', pou);
end $$;

-- crée un billet pour un joueur (payé ou gratuit)
create or replace function public._lot_make(p_owner uuid) returns int language plpgsql security definer set search_path = public, extensions as $$
declare pl jsonb := _lot_gen(p_owner); no int; id bigint;
begin
  insert into public.casino_tickets(owner, bought_at, period, fake, payload, h_zim, h_tan, h_tom, h_pou, seed, w_zim, w_tom, w_pou)
    values (p_owner, _casino_now(), _lot_period_of(_casino_now()), (pl->>'fake')::boolean, pgp_sym_encrypt(pl::text, _casino_key('lot_key')),
      _lot_hmac(pl->'zim'->>'code'), _lot_hmac(pl->'tan'->>'code'), _lot_hmac(pl->'tom'->>'code'), _lot_hmac(pl->'pou'->>'code'), _casino_rand(2000000000),
      (pl->'zim'->>'prize')::numeric > 0, pl->'tom'->'prize'->>'kind' <> 'none', (pl->'pou'->>'possible')::boolean)
    returning casino_tickets.id, casino_tickets.no into id, no;
  return no;
end $$;

-- tirage mensuel Tanhgokrom (évalué paresseusement)
create or replace function public._lot_close_one(p_period date) returns void language plpgsql security definer set search_path = public, extensions as $$
declare n int; pick bigint; h text; frozen numeric;
begin
  update public.casino_periods set expired = true where winner_ticket is not null and not claimed and not expired and period < p_period;
  frozen := _lot_pot();
  select count(*) into n from public.casino_tickets where period = p_period and not fake and not confiscated;
  if n > 0 and frozen > 0 then
    select id, h_tan into pick, h from public.casino_tickets where period = p_period and not fake and not confiscated order by id offset _casino_rand(n) limit 1;
  end if;
  insert into public.casino_periods(period, pot, winner_ticket, winner_h, drawn_at) values (p_period, frozen, pick, h, _casino_now()) on conflict do nothing;
end $$;

create or replace function public._lot_period_close() returns void language plpgsql security definer set search_path = public, extensions as $$
declare cur date := _lot_period_of(_casino_now()); p date; last date;
begin
  perform pg_advisory_xact_lock(hashtextextended('casino:lotclose', 0));
  select max(period) into last from public.casino_periods;
  if last is null then select min(period) into p from public.casino_tickets; else p := (last + interval '1 month')::date; end if;
  if p is null then return; end if;
  while p < cur loop
    perform _lot_close_one(p);
    p := (p + interval '1 month')::date;
  end loop;
end $$;

create or replace function public._lot_pending(p_uid uuid) returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists(select 1 from public.casino_tickets t where t.owner = p_uid and not t.confiscated and not t.fake and (
      (t.w_tom and not t.tom_claimed) or (t.w_pou and t.pou_solved and not t.pou_claimed)
      or exists(select 1 from public.casino_periods p where p.winner_ticket = t.id and not p.claimed and not p.expired))) $$;

create or replace function public._lot_info_json(p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare slot bigint := _lot_zim_slot(); sl numeric := _casino_ccn('zim_slot_s'); left_ms int; cur date := _lot_period_of(_casino_now()); code text;
begin
  left_ms := greatest(0, round(((slot + 1) * sl - extract(epoch from _casino_now())) * 1000))::int;
  code := _lot_zim_code(slot);
  return jsonb_build_object('price', _lot_price(), 'pot', _lot_pot(), 'period_start', cur, 'period_end', (cur + interval '1 month')::date::text || 'T00:00:00Z',
    'zim_code', code, 'zim_left_ms', left_ms, 'zim_slot_ms', (sl * 1000)::int, 'zim', jsonb_build_object('code', code, 'left_ms', left_ms, 'slot_ms', (sl * 1000)::int),
    'pending_win', _lot_pending(p_uid));
end $$;

create or replace function public.lot_info() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid();
begin
  perform _lot_period_close();
  return _lot_info_json(uid);
end $$;

create or replace function public.lot_buy() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); price numeric; no int; bal numeric; potp numeric;
begin
  perform public.rate_ok('casino_lotbuy', 30, 60);
  perform _lot_period_close();
  price := _lot_price();
  bal := _casino_move(uid, -price, 'casino : Lot-Au-MAX! (achat)');
  no := _lot_make(uid);
  potp := round(price * _casino_ccn('lot_pot_pct'), 1);
  insert into public.casino_pot(delta, reason) values (potp, 'achat ' || _lot_label(no));
  insert into public.casino_burn(delta, reason) values (price - potp, 'achat ' || _lot_label(no));
  return jsonb_build_object('ticket', _lot_label(no), 'price', price, 'balance', bal);
end $$;

create or replace function public._lot_find(p_ticket text, p_uid uuid) returns public.casino_tickets language plpgsql stable security definer set search_path = public, extensions as $$
declare t public.casino_tickets; n int;
begin
  if p_ticket is null or upper(p_ticket) !~ '^L-?[0-9]{1,9}$' then raise exception 'Billet introuvable'; end if;
  n := regexp_replace(p_ticket, '[^0-9]', '', 'g')::int;
  select * into t from public.casino_tickets where no = n and owner = p_uid and not confiscated;
  if not found then raise exception 'Billet introuvable'; end if;
  return t;
end $$;

create or replace function public.lot_list() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('ticket', _lot_label(no), 'bought_at', bought_at, 'opened', opened,
      'scratched', jsonb_build_object('zim', scr_zim, 'tan', scr_tan, 'tom', scr_tom, 'pou', scr_pou), 'holo', not fake, 'pou_done', pou_done,
      'claimed', zim_claimed or tan_claimed or tom_claimed or pou_claimed, 'seed', seed) order by id desc)
    from public.casino_tickets where owner = uid and not confiscated), '[]'::jsonb);
end $$;

create or replace function public.lot_open(p_ticket text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets;
begin
  t := _lot_find(p_ticket, uid);
  update public.casino_tickets set opened = true where id = t.id;
  return jsonb_build_object('seed', t.seed);
end $$;

create or replace function public.lot_scratch(p_ticket text, p_zone text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets; pl jsonb;
begin
  perform public.rate_ok('casino_scratch', 120, 60);
  t := _lot_find(p_ticket, uid);
  if not t.opened then raise exception 'Ouvrez d’abord le sac'; end if;
  pl := _lot_dec(t.id);
  if p_zone = 'zim' then update public.casino_tickets set scr_zim = true where id = t.id; return jsonb_build_object('code', pl->'zim'->>'code');
  elsif p_zone = 'tan' then update public.casino_tickets set scr_tan = true where id = t.id; return jsonb_build_object('code', pl->'tan'->>'code');
  elsif p_zone = 'tom' then update public.casino_tickets set scr_tom = true where id = t.id; return jsonb_build_object('code', pl->'tom'->>'code', 'cells', pl->'tom'->'cells');
  elsif p_zone = 'pou' then
    update public.casino_tickets set scr_pou = true where id = t.id;
    return jsonb_build_object('code', pl->'pou'->>'code', 'done', t.pou_done, 'puzzle', jsonb_build_object('n', pl->'pou'->'n', 'colors', pl->'pou'->'colors', 'pairs', pl->'pou'->'pairs'));
  end if;
  raise exception 'Zone inconnue';
end $$;

-- validation d'un essai Poutinà : chemins orthogonaux continus, sans croisement ni passage sur un point
create or replace function public.lot_pou_submit(p_ticket text, p_paths jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets; pl jsonb; n int; cols int; pairs jsonb; used int[] := '{}'; ends int[] := '{}'; pr jsonb; i int; j int; path jsonb; len int; r int; c int; pr_ int; pc_ int; cell int; connected int := 0; valid boolean;
  ar int; ac int; br int; bc int; first_ok boolean; last_ok boolean; own boolean; allpaths boolean := true; cc int; e jsonb;
begin
  perform public.rate_ok('casino_pou', 30, 60);
  t := _lot_find(p_ticket, uid);
  if not t.scr_pou then raise exception 'Grattez d’abord cette zone'; end if;
  if t.pou_done then raise exception 'Essai déjà utilisé'; end if;
  if jsonb_typeof(p_paths) <> 'array' then raise exception 'Chemins invalides'; end if;
  pl := _lot_dec(t.id)->'pou'; n := (pl->>'n')::int; cols := (pl->>'colors')::int; pairs := pl->'pairs';
  for e in select * from jsonb_array_elements(pairs) loop
    ends := ends || ((e->'a'->>0)::int * n + (e->'a'->>1)::int) || ((e->'b'->>0)::int * n + (e->'b'->>1)::int);
  end loop;
  for i in 0..cols - 1 loop
    path := p_paths->i;
    if path is null or jsonb_typeof(path) <> 'array' or jsonb_array_length(path) < 2 then allpaths := false; continue; end if;
    pr := (select x from jsonb_array_elements(pairs) x where (x->>'c')::int = i);
    len := jsonb_array_length(path);
    ar := (pr->'a'->>0)::int; ac := (pr->'a'->>1)::int; br := (pr->'b'->>0)::int; bc := (pr->'b'->>1)::int;
    first_ok := ((path->0->>0)::int = ar and (path->0->>1)::int = ac) or ((path->0->>0)::int = br and (path->0->>1)::int = bc);
    last_ok := ((path->(len - 1)->>0)::int = br and (path->(len - 1)->>1)::int = bc and (path->0->>0)::int = ar and (path->0->>1)::int = ac)
            or ((path->(len - 1)->>0)::int = ar and (path->(len - 1)->>1)::int = ac and (path->0->>0)::int = br and (path->0->>1)::int = bc);
    if not last_ok then allpaths := false; continue; end if;
    pr_ := null; pc_ := null; own := true;
    for j in 0..len - 1 loop
      r := (path->j->>0)::int; c := (path->j->>1)::int;
      if r < 0 or r >= n or c < 0 or c >= n then own := false; exit; end if;
      if pr_ is not null and abs(r - pr_) + abs(c - pc_) <> 1 then own := false; exit; end if;
      cell := r * n + c;
      if cell = any(used) then own := false; exit; end if;
      if j > 0 and j < len - 1 and cell = any(ends) then own := false; exit; end if;
      used := used || cell;
      pr_ := r; pc_ := c;
    end loop;
    if own then connected := connected + 1; else allpaths := false; end if;
  end loop;
  valid := allpaths and connected = cols and (pl->>'possible')::boolean;
  update public.casino_tickets set pou_done = true, pou_solved = valid where id = t.id;
  return jsonb_build_object('valid', valid, 'connected', connected, 'colors', cols);
end $$;

create or replace function public.lot_scan(p_code text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); kind text; h text; t public.casino_tickets; pl jsonb; st text; note text; per public.casino_periods; slot_end timestamptz;
begin
  perform public.rate_ok('casino_scan', 40, 60);
  perform _lot_period_close();
  kind := case length(code) when 20 then 'zim' when 15 then 'tan' when 12 then 'tom' when 50 then 'pou' else null end;
  if kind is null then return jsonb_build_object('kind', null, 'ticket', null, 'status', 'inconnu', 'note', 'Code non reconnu.'); end if;
  h := _lot_hmac(code);
  select * into t from public.casino_tickets where owner = uid and not confiscated and case kind when 'zim' then h_zim when 'tan' then h_tan when 'tom' then h_tom else h_pou end = h limit 1;
  if not found then return jsonb_build_object('kind', kind, 'ticket', null, 'status', 'inconnu', 'note', 'Ce code ne correspond à aucun de vos billets.'); end if;
  if t.fake then return jsonb_build_object('kind', kind, 'ticket', _lot_label(t.no), 'status', 'faux', 'note', 'Billet falsifié : aucune valeur.'); end if;
  pl := _lot_dec(t.id);
  if kind = 'zim' then
    if (pl->'zim'->>'prize')::numeric <= 0 then st := 'perdant'; note := 'Aucun gain.';
    elsif t.zim_claimed then st := 'perdant'; note := 'Déjà réclamé.';
    else
      slot_end := to_timestamp(((pl->'zim'->>'slot')::bigint + 1) * _casino_ccn('zim_slot_s'));
      if slot_end <= _casino_now() then st := 'perdant'; note := 'Code expiré : il n’est plus affiché à la télé.';
      else st := 'gagnant'; note := 'À réclamer devant la télé Zimemberg quand ce code y apparaîtra.'; end if;
    end if;
  elsif kind = 'tan' then
    if t.period >= _lot_period_of(_casino_now()) then st := 'attente'; note := 'Le tirage a lieu le 1er du mois à 00:00 (GMT).';
    else
      select * into per from public.casino_periods where period = t.period;
      if found and per.winner_ticket = t.id and not per.expired and not per.claimed then st := 'gagnant'; note := 'À réclamer à la banque de ticket.';
      elsif found and per.winner_ticket = t.id and per.claimed then st := 'perdant'; note := 'Déjà réclamé.';
      elsif found and per.winner_ticket = t.id then st := 'perdant'; note := 'Cagnotte expirée (reportée).';
      else st := 'perdant'; note := 'Ce billet n’a pas gagné la cagnotte.'; end if;
    end if;
  elsif kind = 'tom' then
    if pl->'tom'->'prize'->>'kind' = 'none' then st := 'perdant'; note := 'Aucun gain.';
    elsif t.tom_claimed then st := 'perdant'; note := 'Déjà réclamé.';
    else st := 'gagnant'; note := 'À réclamer à la banque de ticket.'; end if;
  else
    if not (pl->'pou'->>'possible')::boolean then st := 'perdant'; note := 'Aucun gain.';
    elsif t.pou_claimed then st := 'perdant'; note := 'Déjà réclamé.';
    elsif t.pou_solved then st := 'gagnant'; note := 'À réclamer à la banque de ticket.';
    else st := 'gagnant'; note := 'Gagnant, mais aucun prix : le puzzle n’a pas été relié.'; end if;
  end if;
  return jsonb_build_object('kind', kind, 'ticket', _lot_label(t.no), 'status', st, 'note', note);
end $$;

create or replace function public.lot_zim_claim(p_ticket text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets; pl jsonb; bal numeric; prize numeric; cur text;
begin
  perform public.rate_ok('casino_zim', 20, 60);
  t := _lot_find(p_ticket, uid);
  if not t.scr_zim then raise exception 'Grattez d’abord cette zone'; end if;
  if t.zim_claimed then raise exception 'Déjà réclamé'; end if;
  pl := _lot_dec(t.id);
  cur := _lot_zim_code(_lot_zim_slot());
  prize := coalesce((pl->'zim'->>'prize')::numeric, 0);
  update public.casino_tickets set zim_claimed = true where id = t.id;
  if not t.fake and prize > 0 and pl->'zim'->>'code' = cur then
    bal := _casino_move(uid, prize, 'casino : Zimemberg ' || _lot_label(t.no));
    perform _casino_bank(-prize, 'Zimemberg ' || _lot_label(t.no));
    return jsonb_build_object('won', true, 'prize', prize, 'balance', bal, 'penalty', false);
  end if;
  select balance into bal from public.wallets where user_id = uid;
  if _casino_cc('zim_wrong_penalty') = 'all' and coalesce(bal, 0) > 0 then
    perform public.tok_add(uid, -bal, 'casino : mauvais code Zimemberg ' || _lot_label(t.no), null);
    perform _casino_bank(bal, 'pénalité Zimemberg');
    return jsonb_build_object('won', false, 'prize', 0, 'balance', 0, 'penalty', true);
  end if;
  return jsonb_build_object('won', false, 'prize', 0, 'balance', coalesce(bal, 0), 'penalty', false);
end $$;

create or replace function public.lot_bank(p_ticket text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets; pl jsonb; items jsonb := '[]'::jsonb; per public.casino_periods; tok numeric; med numeric; bal numeric; md numeric; free_no int; kind text; amt numeric;
begin
  perform public.rate_ok('casino_bank', 40, 60);
  perform _lot_period_close();
  t := _lot_find(p_ticket, uid);
  if t.fake then
    update public.casino_tickets set confiscated = true where id = t.id;
    return jsonb_build_object('items', '[]'::jsonb, 'balance', (select balance from public.wallets where user_id = uid), 'medals', (select medals from public.wallets where user_id = uid), 'fake', true);
  end if;
  pl := _lot_dec(t.id);
  -- Tanhgokrom
  if t.scr_tan and not t.tan_claimed then
    select * into per from public.casino_periods where winner_ticket = t.id and not claimed and not expired for update;
    if found then
      insert into public.casino_pot(delta, reason) values (-per.pot, 'cagnotte versée ' || _lot_label(t.no));
      update public.casino_periods set claimed = true where period = per.period;
      update public.casino_tickets set tan_claimed = true where id = t.id;
      bal := _casino_move(uid, per.pot, 'casino : cagnotte Tanhgokrom ' || _lot_label(t.no));
      items := items || jsonb_build_array(jsonb_build_object('kind', 'tan', 'label', 'Cagnotte Tanhgokrom', 'tokens', per.pot, 'medals', 0, 'free_ticket', null));
    end if;
  end if;
  -- Tomateeom
  if t.scr_tom and not t.tom_claimed and pl->'tom'->'prize'->>'kind' <> 'none' then
    kind := pl->'tom'->'prize'->>'kind'; amt := (pl->'tom'->'prize'->>'amount')::numeric;
    update public.casino_tickets set tom_claimed = true where id = t.id;
    if kind = 'ticket' then
      free_no := _lot_make(uid);
      items := items || jsonb_build_array(jsonb_build_object('kind', 'tom', 'label', 'Billet gratuit', 'tokens', 0, 'medals', 0, 'free_ticket', _lot_label(free_no)));
    else
      bal := _casino_move(uid, amt, 'casino : Tomateeom ' || _lot_label(t.no));
      perform _casino_bank(-amt, 'Tomateeom ' || _lot_label(t.no));
      items := items || jsonb_build_array(jsonb_build_object('kind', 'tom', 'label', amt::bigint || ' jetons', 'tokens', amt, 'medals', 0, 'free_ticket', null));
    end if;
  end if;
  -- Poutinà : seulement si le puzzle était possible ET relié
  if t.scr_pou and t.pou_done and t.pou_solved and not t.pou_claimed and (pl->'pou'->>'possible')::boolean then
    med := (pl->'pou'->>'medals')::numeric;
    update public.casino_tickets set pou_claimed = true where id = t.id;
    insert into public.wallets(user_id) values (uid) on conflict do nothing;
    update public.wallets set medals = medals + med where user_id = uid;
    perform public.tok_add(uid, 0, 'casino : Poutinà ' || med::bigint || ' médaillons ' || _lot_label(t.no), null);
    items := items || jsonb_build_array(jsonb_build_object('kind', 'pou', 'label', med::bigint || ' médaillons', 'tokens', 0, 'medals', med, 'free_ticket', null));
  end if;
  select balance, medals into bal, md from public.wallets where user_id = uid;
  return jsonb_build_object('items', items, 'balance', coalesce(bal, 0), 'medals', coalesce(md, 0), 'fake', false);
end $$;

create or replace function public.lot_discard(p_ticket text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets;
begin
  t := _lot_find(p_ticket, uid);
  delete from public.casino_tickets where id = t.id;
  return '{}'::jsonb;
end $$;

-- ---------- M) Droits : seules les fonctions RPC sont appelables par un joueur connecté ----------
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like '\_casino\_%' or p.proname like '\_pk\_%' or p.proname like '\_bj\_%' or p.proname like '\_rl\_%' or p.proname like '\_lot\_%' or p.proname like '\_slots\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('casino_lobby','casino_state','casino_join','casino_leave','casino_bot_vote','poker_action','casino_cheat_start','casino_cheat_click','casino_cheat_catch','casino_cheat_result',
      'bj_bet','bj_action','roulette_bet','roulette_clear','slots_info','slots_spin','lot_info','lot_buy','lot_list','lot_open','lot_scratch','lot_pou_submit','lot_scan','lot_zim_claim','lot_bank','lot_discard')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
