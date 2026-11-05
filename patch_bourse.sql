-- ============================================================================
-- Communicer! — Patch « Bourse » : 7 cryptomonnaies fondamentales, carnet d'ordres, portefeuille (additif, relançable)
-- Utilise les jetons existants (wallets / tok_add / token_log). Aucun solde parallèle : les ordres d'achat réservent
-- (débitent) des jetons du portefeuille ; les ventes créditent le portefeuille. Les quantités de monnaies sont dans crypto_holdings.
-- À exécuter après patch_customize.sql, patch_correctifs2.sql et patch_badges.sql.
-- ============================================================================

-- ---------- pass Krypto+%!? ----------
insert into public.shop_items(code, kind, name, descr, price, sort) values
 ('krypto_plus', 'feature', 'Krypto+%!?', 'Créer une cryptomonnaie, coder son assistant avec du code visuel (le code manuel est réservé aux détenteurs), mémoire de 512 Ko au lieu de 256 Ko.', 6000, 60)
on conflict (code) do update set name = excluded.name, descr = excluded.descr;
create or replace function public._has_krypto(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = p_user and code = 'krypto_plus') $$;
revoke all on function public._has_krypto(uuid) from public, anon, authenticated;

-- ---------- configuration ----------
create table if not exists public.crypto_cfg (k text primary key, v numeric not null);
insert into public.crypto_cfg(k, v) values ('fee_bps', 50), ('max_order_value', 10000000), ('orders_per_hour', 120), ('max_open_orders', 50) on conflict (k) do nothing;
create or replace function public._ccfg(p_k text) returns numeric language sql stable security definer set search_path = public as $$ select v from public.crypto_cfg where k = p_k $$;
revoke all on function public._ccfg(text) from public, anon, authenticated;

-- ---------- monnaies ----------
create table if not exists public.crypto_assets (
  symbol text primary key check (symbol ~ '^[A-Z0-9]{2,6}$'), name text not null, descr text not null, role text not null,
  price0 numeric(20,4) not null check (price0 > 0), max_supply numeric(24,4) not null check (max_supply > 0), circ_supply numeric(24,4) not null check (circ_supply >= 0),
  state text not null default 'active' check (state in ('active','suspended','retired')), sort int not null default 0, created_at timestamptz not null default now(),
  check (circ_supply <= max_supply));

create table if not exists public.crypto_holdings (
  user_id uuid not null references public.profiles(id) on delete cascade, symbol text not null references public.crypto_assets(symbol),
  qty numeric(24,4) not null default 0 check (qty >= 0), locked numeric(24,4) not null default 0 check (locked >= 0), avg_cost numeric(20,6) not null default 0,
  realized numeric(20,1) not null default 0, primary key (user_id, symbol), check (locked <= qty));

create table if not exists public.crypto_orders (
  id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade, symbol text not null references public.crypto_assets(symbol),
  side text not null check (side in ('buy','sell')), qty numeric(24,4) not null check (qty > 0), filled numeric(24,4) not null default 0, price numeric(20,4) not null check (price > 0),
  reserved numeric(16,1) not null default 0 check (reserved >= 0), status text not null default 'open' check (status in ('open','partial','filled','cancelled')),
  kind text not null default 'user' check (kind in ('user','treasury','bot')), idem text, created_at timestamptz not null default now(), closed_at timestamptz,
  check (filled <= qty));
create unique index if not exists crypto_orders_idem on public.crypto_orders(user_id, idem) where idem is not null;
create index if not exists crypto_orders_book on public.crypto_orders(symbol, side, price, id) where status in ('open','partial');
create index if not exists crypto_orders_user on public.crypto_orders(user_id, id desc);

create table if not exists public.crypto_trades (
  id bigint generated always as identity primary key, symbol text not null references public.crypto_assets(symbol), buy_order bigint not null, sell_order bigint not null,
  buyer uuid not null, seller uuid not null, qty numeric(24,4) not null, price numeric(20,4) not null, value numeric(16,1) not null, fee numeric(16,1) not null default 0,
  taker_side text not null check (taker_side in ('buy','sell')), automated boolean not null default false, at timestamptz not null default now());
create index if not exists crypto_trades_sym on public.crypto_trades(symbol, at desc);
create index if not exists crypto_trades_buyer on public.crypto_trades(buyer, id desc);
create index if not exists crypto_trades_seller on public.crypto_trades(seller, id desc);

-- registre comptable en ajout seulement
create table if not exists public.crypto_ledger (
  id bigint generated always as identity primary key, at timestamptz not null default now(), kind text not null, user_id uuid, symbol text,
  d_qty numeric(24,4) not null default 0, d_tokens numeric(16,1) not null default 0, ref text, note text);
create index if not exists crypto_ledger_user on public.crypto_ledger(user_id, id desc);
create or replace function public.trg_crypto_ledger_ro() returns trigger language plpgsql as $$ begin raise exception 'Le registre comptable est en ajout seulement'; end $$;
drop trigger if exists crypto_ledger_ro on public.crypto_ledger;
create trigger crypto_ledger_ro before update or delete on public.crypto_ledger for each row execute function public.trg_crypto_ledger_ro();

create table if not exists public.crypto_supply_events (
  id bigint generated always as identity primary key, at timestamptz not null default now(), symbol text not null references public.crypto_assets(symbol),
  kind text not null check (kind in ('initial','issue','burn')), qty numeric(24,4) not null, reason text not null, by_user uuid);

alter table public.crypto_cfg enable row level security; alter table public.crypto_assets enable row level security; alter table public.crypto_holdings enable row level security;
alter table public.crypto_orders enable row level security; alter table public.crypto_trades enable row level security; alter table public.crypto_ledger enable row level security;
alter table public.crypto_supply_events enable row level security;
drop policy if exists crypto_assets_r on public.crypto_assets; create policy crypto_assets_r on public.crypto_assets for select to authenticated using (true);
drop policy if exists crypto_supply_r on public.crypto_supply_events; create policy crypto_supply_r on public.crypto_supply_events for select to authenticated using (true);
drop policy if exists crypto_holdings_r on public.crypto_holdings; create policy crypto_holdings_r on public.crypto_holdings for select to authenticated using (user_id = auth.uid());
drop policy if exists crypto_orders_r on public.crypto_orders; create policy crypto_orders_r on public.crypto_orders for select to authenticated using (user_id = auth.uid());
drop policy if exists crypto_ledger_r on public.crypto_ledger; create policy crypto_ledger_r on public.crypto_ledger for select to authenticated using (user_id = auth.uid());
drop policy if exists crypto_trades_r on public.crypto_trades; create policy crypto_trades_r on public.crypto_trades for select to authenticated using (true);

do $$ begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'crypto_trades') then
    alter publication supabase_realtime add table public.crypto_trades;
  end if;
exception when others then null; end $$;

-- compte de trésorerie du marché : le compte système
create or replace function public._ctreas() returns uuid language sql immutable as $$ select 'aaaaaaaa-0000-4000-8000-000000000001'::uuid $$;

-- ---------- noyau d'exécution ----------
create or replace function public._cr_lock(p_symbol text) returns void language sql as $$ select pg_advisory_xact_lock(hashtext('crypto:' || p_symbol)) $$;

create or replace function public._cr_close_order(p_id bigint, p_status text) returns void language plpgsql security definer set search_path = public as $$
declare o public.crypto_orders;
begin
  select * into o from public.crypto_orders where id = p_id for update;
  if o.side = 'buy' and o.reserved > 0 then
    perform public.tok_add(o.user_id, o.reserved, 'ordre d’achat ' || o.symbol || ' : jetons restitués', null);
    insert into public.crypto_ledger(kind, user_id, symbol, d_tokens, ref) values ('release', o.user_id, o.symbol, o.reserved, 'ordre ' || o.id);
  elsif o.side = 'sell' and o.qty - o.filled > 0 then
    update public.crypto_holdings set locked = locked - (o.qty - o.filled) where user_id = o.user_id and symbol = o.symbol;
  end if;
  update public.crypto_orders set status = p_status, reserved = 0, closed_at = now() where id = p_id;
end $$;
revoke all on function public._cr_close_order(bigint, text) from public, anon, authenticated;

create or replace function public._cr_match(p_order bigint) returns void language plpgsql security definer set search_path = public as $$
declare o public.crypto_orders; m public.crypto_orders; q numeric; p numeric; c numeric; f numeric; bu uuid; se uuid; bo bigint; so bigint; tid bigint; h public.crypto_holdings; fee_bps numeric := public._ccfg('fee_bps'); net numeric;
begin
  loop
    select * into o from public.crypto_orders where id = p_order for update;
    exit when o.status not in ('open','partial');
    if o.side = 'buy' then
      select * into m from public.crypto_orders where symbol = o.symbol and side = 'sell' and status in ('open','partial') and user_id <> o.user_id and price <= o.price order by price asc, id asc limit 1 for update;
    else
      select * into m from public.crypto_orders where symbol = o.symbol and side = 'buy' and status in ('open','partial') and user_id <> o.user_id and price >= o.price order by price desc, id asc limit 1 for update;
    end if;
    exit when not found;
    q := least(o.qty - o.filled, m.qty - m.filled); p := m.price;
    c := round(q * p, 1);
    if o.side = 'buy' then c := least(c, o.reserved); else c := least(c, m.reserved); end if;
    exit when c < 0.1;
    f := round(c * fee_bps / 10000, 1); net := c - f;
    if o.side = 'buy' then bu := o.user_id; bo := o.id; se := m.user_id; so := m.id; else bu := m.user_id; bo := m.id; se := o.user_id; so := o.id; end if;
    -- vendeur : quantité remise, jetons reçus (moins les frais)
    update public.crypto_holdings set qty = qty - q, locked = locked - q, realized = realized + (net - avg_cost * q) where user_id = se and symbol = o.symbol;
    perform public.tok_add(se, net, 'vente ' || o.symbol || ' x ' || q, null);
    if f > 0 then perform public.tok_add(public._ctreas(), f, 'frais de bourse ' || o.symbol, null); end if;
    -- acheteur : quantité reçue, prix moyen mis à jour
    insert into public.crypto_holdings(user_id, symbol, qty, avg_cost) values (bu, o.symbol, 0, 0) on conflict do nothing;
    select * into h from public.crypto_holdings where user_id = bu and symbol = o.symbol for update;
    update public.crypto_holdings set avg_cost = case when h.qty + q > 0 then (h.avg_cost * h.qty + c) / (h.qty + q) else 0 end, qty = h.qty + q where user_id = bu and symbol = o.symbol;
    -- ordres
    if o.side = 'buy' then update public.crypto_orders set filled = filled + q, reserved = reserved - c where id = o.id; update public.crypto_orders set filled = filled + q where id = m.id;
    else update public.crypto_orders set filled = filled + q where id = o.id; update public.crypto_orders set filled = filled + q, reserved = reserved - c where id = m.id; end if;
    insert into public.crypto_trades(symbol, buy_order, sell_order, buyer, seller, qty, price, value, fee, taker_side, automated)
      values (o.symbol, bo, so, bu, se, q, p, c, f, o.side, o.kind = 'bot' or m.kind = 'bot') returning id into tid;
    insert into public.crypto_ledger(kind, user_id, symbol, d_qty, d_tokens, ref) values
      ('trade', bu, o.symbol, q, -c, 'echange ' || tid), ('trade', se, o.symbol, -q, net, 'echange ' || tid);
    if f > 0 then insert into public.crypto_ledger(kind, user_id, symbol, d_tokens, ref) values ('fee', public._ctreas(), o.symbol, f, 'echange ' || tid); end if;
    -- statuts ; l'acheteur récupère le surplus réservé quand son ordre est complet
    update public.crypto_orders set status = case when filled >= qty then 'filled' else 'partial' end where id in (o.id, m.id);
    for m in select * from public.crypto_orders where id in (o.id, m.id) and status = 'filled' loop
      if m.side = 'buy' and m.reserved > 0 then perform public._cr_close_order(m.id, 'filled'); else update public.crypto_orders set closed_at = now() where id = m.id; end if;
    end loop;
  end loop;
end $$;
revoke all on function public._cr_match(bigint) from public, anon, authenticated;

-- ---------- ordres ----------
create or replace function public.crypto_order_place(p_symbol text, p_side text, p_qty numeric, p_price numeric, p_ioc boolean default false, p_idem text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.crypto_assets; oid bigint; r numeric; b numeric; hh public.crypto_holdings; o public.crypto_orders; ex public.crypto_orders;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('cord', public._ccfg('orders_per_hour')::int, 3600);
  select * into a from public.crypto_assets where symbol = upper(btrim(coalesce(p_symbol,'')));
  if not found then raise exception 'Cryptomonnaie introuvable'; end if;
  if a.state <> 'active' then raise exception 'Le marché de % est suspendu', a.symbol; end if;
  if p_side not in ('buy','sell') then raise exception 'Sens inconnu'; end if;
  if p_qty is null or p_qty <= 0 or p_qty <> round(p_qty, 4) then raise exception 'Quantité invalide (4 décimales au maximum)'; end if;
  if p_price is null or p_price <= 0 or p_price <> round(p_price, 4) then raise exception 'Prix invalide (4 décimales au maximum)'; end if;
  if p_idem is not null and char_length(p_idem) > 64 then raise exception 'Identifiant d’opération trop long'; end if;
  perform public._cr_lock(a.symbol);
  if p_idem is not null then
    select * into ex from public.crypto_orders where user_id = auth.uid() and idem = p_idem;
    if found then return jsonb_build_object('id', ex.id, 'status', ex.status, 'filled', ex.filled, 'duplicate', true); end if;
  end if;
  r := round(p_qty * p_price, 1);
  if r < 0.1 then raise exception 'Ordre trop petit (valeur minimale : 0,1 jeton)'; end if;
  if r > public._ccfg('max_order_value') then raise exception 'Ordre trop grand'; end if;
  if (select count(*) from public.crypto_orders where user_id = auth.uid() and status in ('open','partial')) >= public._ccfg('max_open_orders') then raise exception 'Trop d’ordres ouverts'; end if;
  if p_side = 'buy' then
    insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
    select balance into b from public.wallets where user_id = auth.uid() for update;
    if b < r then raise exception 'Jetons insuffisants (% requis)', r; end if;
    perform public.tok_add(auth.uid(), -r, 'ordre d’achat ' || a.symbol || ' : jetons réservés', null);
    insert into public.crypto_ledger(kind, user_id, symbol, d_tokens, ref) values ('reserve', auth.uid(), a.symbol, -r, 'achat ' || p_qty || ' @ ' || p_price);
    insert into public.crypto_orders(user_id, symbol, side, qty, price, reserved, idem) values (auth.uid(), a.symbol, 'buy', p_qty, p_price, r, p_idem) returning crypto_orders.id into oid;
  else
    select * into hh from public.crypto_holdings where user_id = auth.uid() and symbol = a.symbol for update;
    if not found or hh.qty - hh.locked < p_qty then raise exception 'Quantité insuffisante'; end if;
    update public.crypto_holdings set locked = locked + p_qty where user_id = auth.uid() and symbol = a.symbol;
    insert into public.crypto_orders(user_id, symbol, side, qty, price, idem) values (auth.uid(), a.symbol, 'sell', p_qty, p_price, p_idem) returning crypto_orders.id into oid;
  end if;
  perform public._cr_match(oid);
  select * into o from public.crypto_orders where crypto_orders.id = oid;
  if p_ioc and o.status in ('open','partial') then perform public._cr_close_order(oid, 'cancelled'); select * into o from public.crypto_orders where crypto_orders.id = oid; end if;
  return jsonb_build_object('id', o.id, 'status', o.status, 'filled', o.filled, 'qty', o.qty);
end $$;

create or replace function public.crypto_order_cancel(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare o public.crypto_orders;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into o from public.crypto_orders where id = p_id and user_id = auth.uid();
  if not found then raise exception 'Ordre introuvable'; end if;
  perform public._cr_lock(o.symbol);
  select * into o from public.crypto_orders where id = p_id for update;
  if o.status not in ('open','partial') then raise exception 'Cet ordre n’est plus ouvert'; end if;
  perform public._cr_close_order(p_id, 'cancelled');
end $$;

-- ---------- lecture ----------
create or replace function public._cr_stats(p_symbol text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare a public.crypto_assets; last numeric; p24 numeric; p7 numeric; p30 numeric; hi numeric; lo numeric; v24q numeric; v24v numeric; ntr bigint; bid numeric; ask numeric; holders int; oo int; bq numeric; sq numeric; vol numeric; sell_q numeric; buy_q numeric; tb numeric; ts numeric;
begin
  select * into a from public.crypto_assets where symbol = p_symbol;
  select price into last from public.crypto_trades where symbol = p_symbol order by id desc limit 1;
  select price into p24 from public.crypto_trades where symbol = p_symbol and at <= now() - interval '24 hours' order by id desc limit 1;
  select price into p7 from public.crypto_trades where symbol = p_symbol and at <= now() - interval '7 days' order by id desc limit 1;
  select price into p30 from public.crypto_trades where symbol = p_symbol and at <= now() - interval '30 days' order by id desc limit 1;
  select max(price), min(price), count(*) into hi, lo, ntr from public.crypto_trades where symbol = p_symbol;
  select coalesce(sum(qty),0), coalesce(sum(value),0) into v24q, v24v from public.crypto_trades where symbol = p_symbol and at > now() - interval '24 hours';
  select coalesce(sum(case when taker_side = 'buy' then qty end),0), coalesce(sum(case when taker_side = 'sell' then qty end),0) into tb, ts from public.crypto_trades where symbol = p_symbol and at > now() - interval '24 hours';
  select min(price) into ask from public.crypto_orders where symbol = p_symbol and side = 'sell' and status in ('open','partial');
  select max(price) into bid from public.crypto_orders where symbol = p_symbol and side = 'buy' and status in ('open','partial');
  select coalesce(sum(qty - filled),0) into sell_q from public.crypto_orders where symbol = p_symbol and side = 'sell' and status in ('open','partial');
  select coalesce(sum(qty - filled),0) into buy_q from public.crypto_orders where symbol = p_symbol and side = 'buy' and status in ('open','partial');
  select count(*) into holders from public.crypto_holdings where symbol = p_symbol and qty > 0 and user_id <> public._ctreas();
  select count(*) into oo from public.crypto_orders where symbol = p_symbol and status in ('open','partial');
  select stddev_samp(ln(price / nullif(lp, 0))) into vol from (select price, lag(price) over (order by id) lp from public.crypto_trades where symbol = p_symbol and at > now() - interval '24 hours') x where lp is not null;
  select coalesce(sum(qty),0) into bq from public.crypto_trades where symbol = p_symbol and taker_side = 'buy';
  select coalesce(sum(qty),0) into sq from public.crypto_trades where symbol = p_symbol and taker_side = 'sell';
  return jsonb_build_object('symbol', a.symbol, 'name', a.name, 'descr', a.descr, 'role', a.role, 'state', a.state, 'price0', a.price0,
    'last', last, 'has_price', last is not null, 'ref_price', coalesce(last, a.price0),
    'chg24', case when last is not null and coalesce(p24, 0) > 0 then round((last / p24 - 1) * 100, 2) end,
    'chg7', case when last is not null and coalesce(p7, 0) > 0 then round((last / p7 - 1) * 100, 2) end,
    'chg30', case when last is not null and coalesce(p30, 0) > 0 then round((last / p30 - 1) * 100, 2) end,
    'high', hi, 'low', lo, 'trades', ntr, 'max_supply', a.max_supply, 'circ', a.circ_supply, 'reserve', a.max_supply - a.circ_supply,
    'for_sale', sell_q, 'wanted', buy_q, 'bought_cum', bq, 'sold_cum', sq, 'vol24_qty', v24q, 'vol24_val', v24v,
    'cap', round(coalesce(last, a.price0) * a.circ_supply, 1), 'cap_indicative', last is null,
    'bid', bid, 'ask', ask, 'spread', case when bid is not null and ask is not null then ask - bid end,
    'holders', holders, 'open_orders', oo, 'volatility24', round(coalesce(vol, 0)::numeric, 6),
    'pressure24', case when tb + ts > 0 then round((tb - ts) / (tb + ts), 4) end);
end $$;
revoke all on function public._cr_stats(text) from public, anon, authenticated;

create or replace function public.crypto_market() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return coalesce((select jsonb_agg(public._cr_stats(symbol) order by sort) from public.crypto_assets where state <> 'retired'), '[]'::jsonb);
end $$;

create or replace function public.crypto_asset(p_symbol text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare s text := upper(btrim(coalesce(p_symbol,'')));
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not exists(select 1 from public.crypto_assets where symbol = s) then raise exception 'Cryptomonnaie introuvable'; end if;
  return public._cr_stats(s) || jsonb_build_object(
    'asks', coalesce((select jsonb_agg(x order by (x->>'price')::numeric asc) from (select jsonb_build_object('price', price, 'qty', sum(qty - filled)) x from public.crypto_orders where symbol = s and side = 'sell' and status in ('open','partial') group by price order by price asc limit 12) y), '[]'::jsonb),
    'bids', coalesce((select jsonb_agg(x order by (x->>'price')::numeric desc) from (select jsonb_build_object('price', price, 'qty', sum(qty - filled)) x from public.crypto_orders where symbol = s and side = 'buy' and status in ('open','partial') group by price order by price desc limit 12) y), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'price', price, 'qty', qty, 'side', taker_side, 'auto', automated) order by id desc) from (select * from public.crypto_trades where symbol = s order by id desc limit 40) t), '[]'::jsonb),
    'holders_top', coalesce((select jsonb_agg(jsonb_build_object('label', case when user_id = public._ctreas() then 'Trésorerie' else 'Investisseur ' || rn end, 'pct', round(qty / nullif(circ, 0) * 100, 2)) order by qty desc)
        from (select user_id, qty, row_number() over (order by qty desc) rn, (select circ_supply from public.crypto_assets where symbol = s) circ from public.crypto_holdings where symbol = s and qty > 0 order by qty desc limit 8) h), '[]'::jsonb),
    'supply_events', coalesce((select jsonb_agg(jsonb_build_object('at', at, 'kind', kind, 'qty', qty, 'reason', reason) order by id desc) from (select * from public.crypto_supply_events where symbol = s order by id desc limit 10) e), '[]'::jsonb));
end $$;

create or replace function public.crypto_chart(p_symbol text, p_period text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare s text := upper(btrim(coalesce(p_symbol,''))); since timestamptz; bucket interval;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select case p_period when '1h' then interval '1 hour' when '24h' then interval '24 hours' when '7d' then interval '7 days' when '30d' then interval '30 days' when '90d' then interval '90 days' when '1y' then interval '365 days' when 'all' then null else interval '24 hours' end into bucket;
  since := case when bucket is null then '-infinity'::timestamptz else now() - bucket end;
  bucket := case p_period when '1h' then interval '1 minute' when '24h' then interval '15 minutes' when '7d' then interval '1 hour' when '30d' then interval '6 hours' when '90d' then interval '1 day' when '1y' then interval '1 day' else interval '7 days' end;
  return coalesce((select jsonb_agg(jsonb_build_object('t', t, 'o', o, 'h', h, 'l', l, 'c', c, 'v', v) order by t) from (
    select date_bin(bucket, at, timestamptz '2000-01-01') t, (array_agg(price order by id))[1] o, max(price) h, min(price) l, (array_agg(price order by id desc))[1] c, sum(qty) v
    from public.crypto_trades where symbol = s and at >= since group by 1) z), '[]'::jsonb);
end $$;

create or replace function public.crypto_portfolio() returns jsonb language plpgsql security definer stable set search_path = public as $$
declare tot numeric := 0;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return jsonb_build_object(
    'balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'positions', coalesce((select jsonb_agg(jsonb_build_object('symbol', h.symbol, 'name', a.name, 'qty', h.qty, 'locked', h.locked, 'avg_cost', round(h.avg_cost, 4),
         'last', (select price from public.crypto_trades t where t.symbol = h.symbol order by id desc limit 1), 'ref_price', coalesce((select price from public.crypto_trades t where t.symbol = h.symbol order by id desc limit 1), a.price0),
         'indicative', not exists(select 1 from public.crypto_trades t where t.symbol = h.symbol),
         'value', round(h.qty * coalesce((select price from public.crypto_trades t where t.symbol = h.symbol order by id desc limit 1), a.price0), 1),
         'unrealized', round((coalesce((select price from public.crypto_trades t where t.symbol = h.symbol order by id desc limit 1), a.price0) - h.avg_cost) * h.qty, 1), 'realized', h.realized) order by h.symbol)
       from public.crypto_holdings h join public.crypto_assets a on a.symbol = h.symbol where h.user_id = auth.uid() and (h.qty > 0 or h.realized <> 0)), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'symbol', o.symbol, 'side', o.side, 'qty', o.qty, 'filled', o.filled, 'price', o.price, 'status', o.status, 'at', o.created_at) order by o.id desc)
       from (select * from public.crypto_orders where user_id = auth.uid() order by id desc limit 40) o), '[]'::jsonb),
    'trades', coalesce((select jsonb_agg(jsonb_build_object('at', t.at, 'symbol', t.symbol, 'side', case when t.buyer = auth.uid() then 'buy' else 'sell' end, 'qty', t.qty, 'price', t.price, 'value', t.value,
         'fee', case when t.seller = auth.uid() then t.fee else 0 end) order by t.id desc) from (select * from public.crypto_trades where buyer = auth.uid() or seller = auth.uid() order by id desc limit 40) t), '[]'::jsonb));
end $$;

-- ---------- administration (commandant) ----------
create or replace function public.crypto_issue(p_symbol text, p_qty numeric, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare a public.crypto_assets;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_qty is null or p_qty <= 0 or p_qty <> round(p_qty, 4) then raise exception 'Quantité invalide'; end if;
  if char_length(btrim(coalesce(p_reason,''))) < 5 then raise exception 'Indiquez le motif (5 caractères minimum)'; end if;
  select * into a from public.crypto_assets where symbol = upper(p_symbol) for update;
  if not found then raise exception 'Cryptomonnaie introuvable'; end if;
  if a.circ_supply + p_qty > a.max_supply then raise exception 'L’offre maximale serait dépassée'; end if;
  update public.crypto_assets set circ_supply = circ_supply + p_qty where symbol = a.symbol;
  insert into public.crypto_holdings(user_id, symbol, qty) values (public._ctreas(), a.symbol, p_qty) on conflict (user_id, symbol) do update set qty = public.crypto_holdings.qty + p_qty;
  insert into public.crypto_supply_events(symbol, kind, qty, reason, by_user) values (a.symbol, 'issue', p_qty, p_reason, auth.uid());
  insert into public.crypto_ledger(kind, user_id, symbol, d_qty, ref, note) values ('issue', public._ctreas(), a.symbol, p_qty, 'emission', p_reason);
  perform public.log_admin('crypto_emission', a.symbol, jsonb_build_object('qty', p_qty, 'motif', p_reason));
end $$;

create or replace function public.crypto_burn(p_symbol text, p_qty numeric, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare a public.crypto_assets; h public.crypto_holdings;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_qty is null or p_qty <= 0 or p_qty <> round(p_qty, 4) then raise exception 'Quantité invalide'; end if;
  if char_length(btrim(coalesce(p_reason,''))) < 5 then raise exception 'Indiquez le motif (5 caractères minimum)'; end if;
  select * into a from public.crypto_assets where symbol = upper(p_symbol) for update;
  if not found then raise exception 'Cryptomonnaie introuvable'; end if;
  select * into h from public.crypto_holdings where user_id = public._ctreas() and symbol = a.symbol for update;
  if not found or h.qty - h.locked < p_qty then raise exception 'La trésorerie ne possède pas assez de % disponibles', a.symbol; end if;
  update public.crypto_holdings set qty = qty - p_qty where user_id = public._ctreas() and symbol = a.symbol;
  update public.crypto_assets set circ_supply = circ_supply - p_qty where symbol = a.symbol;
  insert into public.crypto_supply_events(symbol, kind, qty, reason, by_user) values (a.symbol, 'burn', p_qty, p_reason, auth.uid());
  insert into public.crypto_ledger(kind, user_id, symbol, d_qty, ref, note) values ('burn', public._ctreas(), a.symbol, -p_qty, 'destruction', p_reason);
  perform public.log_admin('crypto_destruction', a.symbol, jsonb_build_object('qty', p_qty, 'motif', p_reason));
end $$;

create or replace function public.crypto_treasury_sell(p_symbol text, p_qty numeric, p_price numeric) returns bigint language plpgsql security definer set search_path = public as $$
declare a public.crypto_assets; h public.crypto_holdings; oid bigint;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select * into a from public.crypto_assets where symbol = upper(p_symbol);
  if not found then raise exception 'Cryptomonnaie introuvable'; end if;
  if p_qty <= 0 or p_qty <> round(p_qty, 4) or p_price <= 0 or p_price <> round(p_price, 4) or round(p_qty * p_price, 1) < 0.1 then raise exception 'Quantité ou prix invalide'; end if;
  perform public._cr_lock(a.symbol);
  select * into h from public.crypto_holdings where user_id = public._ctreas() and symbol = a.symbol for update;
  if not found or h.qty - h.locked < p_qty then raise exception 'La trésorerie ne possède pas assez de % disponibles', a.symbol; end if;
  update public.crypto_holdings set locked = locked + p_qty where user_id = public._ctreas() and symbol = a.symbol;
  insert into public.crypto_orders(user_id, symbol, side, qty, price, kind) values (public._ctreas(), a.symbol, 'sell', p_qty, p_price, 'treasury') returning crypto_orders.id into oid;
  perform public._cr_match(oid);
  perform public.log_admin('crypto_mise_en_vente', a.symbol, jsonb_build_object('qty', p_qty, 'prix', p_price));
  return oid;
end $$;

create or replace function public.crypto_set_state(p_symbol text, p_state text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_state not in ('active','suspended','retired') then raise exception 'État inconnu'; end if;
  update public.crypto_assets set state = p_state where symbol = upper(p_symbol);
  if not found then raise exception 'Cryptomonnaie introuvable'; end if;
  perform public.log_admin('crypto_etat', upper(p_symbol), jsonb_build_object('etat', p_state));
end $$;

create or replace function public.crypto_cfg_set(p_k text, p_v numeric) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_k not in ('fee_bps','max_order_value','orders_per_hour','max_open_orders') then raise exception 'Paramètre inconnu'; end if;
  if p_k = 'fee_bps' and (p_v < 0 or p_v > 1000) then raise exception 'Frais entre 0 et 1000 points de base'; end if;
  if p_v < 0 then raise exception 'Valeur invalide'; end if;
  update public.crypto_cfg set v = p_v where k = p_k;
  perform public.log_admin('crypto_parametre', p_k, jsonb_build_object('valeur', p_v));
end $$;

-- vérification comptable : quantités détenues = offre en circulation ; jetons réservés = ordres d'achat ouverts
create or replace function public.crypto_audit() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return jsonb_build_object(
    'supply_mismatch', coalesce((select jsonb_agg(a.symbol) from public.crypto_assets a where a.circ_supply <> coalesce((select sum(qty) from public.crypto_holdings h where h.symbol = a.symbol), 0)), '[]'::jsonb),
    'locked_mismatch', coalesce((select jsonb_agg(h.symbol) from public.crypto_holdings h where h.locked <> coalesce((select sum(o.qty - o.filled) from public.crypto_orders o where o.user_id = h.user_id and o.symbol = h.symbol and o.side = 'sell' and o.status in ('open','partial')), 0)), '[]'::jsonb),
    'reserved_tokens', coalesce((select sum(reserved) from public.crypto_orders where status in ('open','partial')), 0),
    'orders_overfilled', coalesce((select jsonb_agg(id) from public.crypto_orders where filled > qty), '[]'::jsonb));
end $$;

-- ---------- lancement des sept monnaies (relançable : ne recrée rien d'existant) ----------
do $$
declare r record; n int;
begin
  insert into public.wallets(user_id) select public._ctreas() where exists(select 1 from public.profiles where id = public._ctreas()) on conflict do nothing;
  for r in select * from (values
    ('TCH','Tachter','Indice économique général et actif de référence analytique.','Référence analytique',100::numeric,10000000::numeric,1000000::numeric,100000::numeric,1),
    ('RTH','Ruther','Monnaie des services d’analyse individuelle.','Services analytiques',50,20000000,2000000,200000,2),
    ('CMC','Communicoin','Monnaie centrale de l’écosystème économique Communicer.','Monnaie centrale',10,100000000,10000000,1000000,3),
    ('RMC','Romanocoin','Monnaie fondatrice et historique, émission limitée.','Historique',25,5000000,500000,50000,4),
    ('BKM','Bokmal','Recherche et développement : financement de projets et d’outils expérimentaux.','Recherche',5,50000000,5000000,500000,5),
    ('BKZ','Buckzicoin','Commerce et paiements entre entreprises.','Commerce',2,250000000,25000000,2500000,6),
    ('KYT','Kibbytz','Communauté et récompenses.','Communauté',1,500000000,50000000,5000000,7)) v(symbol, name, descr, role, price0, max_supply, circ, sale, sort) loop
    if not exists(select 1 from public.crypto_assets where symbol = r.symbol) then
      insert into public.crypto_assets(symbol, name, descr, role, price0, max_supply, circ_supply, sort) values (r.symbol, r.name, r.descr, r.role, r.price0, r.max_supply, r.circ, r.sort);
      insert into public.crypto_supply_events(symbol, kind, qty, reason) values (r.symbol, 'initial', r.circ, 'Émission initiale');
      insert into public.crypto_ledger(kind, user_id, symbol, d_qty, ref) values ('initial', public._ctreas(), r.symbol, r.circ, 'emission initiale');
      if exists(select 1 from public.profiles where id = public._ctreas()) then
        insert into public.crypto_holdings(user_id, symbol, qty, locked) values (public._ctreas(), r.symbol, r.circ, r.sale);
        insert into public.crypto_orders(user_id, symbol, side, qty, price, kind) values (public._ctreas(), r.symbol, 'sell', r.sale, r.price0, 'treasury');
      end if;
    end if;
  end loop;
end $$;

revoke all on function public.crypto_order_place(text,text,numeric,numeric,boolean,text), public.crypto_order_cancel(bigint), public.crypto_market(), public.crypto_asset(text), public.crypto_chart(text,text),
  public.crypto_portfolio(), public.crypto_issue(text,numeric,text), public.crypto_burn(text,numeric,text), public.crypto_treasury_sell(text,numeric,numeric), public.crypto_set_state(text,text),
  public.crypto_cfg_set(text,numeric), public.crypto_audit() from public, anon;
grant execute on function public.crypto_order_place(text,text,numeric,numeric,boolean,text), public.crypto_order_cancel(bigint), public.crypto_market(), public.crypto_asset(text), public.crypto_chart(text,text),
  public.crypto_portfolio(), public.crypto_issue(text,numeric,text), public.crypto_burn(text,numeric,text), public.crypto_treasury_sell(text,numeric,numeric), public.crypto_set_state(text,text),
  public.crypto_cfg_set(text,numeric), public.crypto_audit() to authenticated;
revoke all on function public._cr_lock(text) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- ---------- miniatures du marché : derniers cours par heure sur 7 jours (seulement des échanges réels) ----------
create or replace function public.crypto_sparks() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return coalesce((select jsonb_object_agg(symbol, arr) from (
    select symbol, jsonb_agg(c order by t) arr from (
      select symbol, date_bin(interval '3 hours', at, timestamptz '2000-01-01') t, (array_agg(price order by id desc))[1] c
      from public.crypto_trades where at > now() - interval '7 days' group by 1, 2) z group by symbol) y), '{}'::jsonb);
end $$;
revoke all on function public.crypto_sparks() from public, anon;
grant execute on function public.crypto_sparks() to authenticated;
notify pgrst, 'reload schema';
