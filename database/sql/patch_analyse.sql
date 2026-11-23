-- ============================================================================
-- Communicer! — Patch « Intelligence économique » (phase 2) : Ruther, Tachter, Ruther-Tachter (additif, relançable)
-- À exécuter après patch_bourse.sql.
-- Principes : les assistants LISENT le marché (transactions et carnet réels) et produisent des prévisions consignées.
-- Ils ne modifient jamais un solde, un prix ni un ordre. Le prix reste uniquement le résultat des échanges réels.
-- Les paramètres des modèles sont versionnés, bornés, et seul le commandant peut déclencher/annuler une adaptation.
-- ============================================================================

-- ---------- versions de modèle ----------
create table if not exists public.crypto_models (
  version int generated always as identity primary key, created_at timestamptz not null default now(), active boolean not null default false,
  params jsonb not null, note text not null default '', by_user uuid);
create unique index if not exists crypto_models_one_active on public.crypto_models(active) where active;
insert into public.crypto_models(params, active, note)
select '{"kp":0.05,"km":0.5,"kv":50,"kg":0.04,"kb":0.03,"kr":0.02,"kmt":0.4,"max":0.2}'::jsonb, true, 'Modèle initial'
where not exists (select 1 from public.crypto_models);
alter table public.crypto_models enable row level security;
revoke all on public.crypto_models from anon, authenticated;

-- ---------- prévisions consignées ----------
create table if not exists public.crypto_forecasts (
  id bigint generated always as identity primary key, symbol text not null references public.crypto_assets(symbol),
  assistant text not null check (assistant in ('ruther','tachter','rt')), model int not null, horizon text not null check (horizon in ('5m','1h','24h','7d')),
  made_at timestamptz not null default now(), target_at timestamptz not null, p0 numeric(20,4) not null, exp_ret numeric(10,6) not null, conf numeric(8,6) not null,
  actual numeric(20,4), err numeric(10,6), hit boolean, scored_at timestamptz);
create index if not exists crypto_fc_sym on public.crypto_forecasts(symbol, assistant, horizon, made_at desc);
create index if not exists crypto_fc_due on public.crypto_forecasts(target_at) where scored_at is null;
alter table public.crypto_forecasts enable row level security;
revoke all on public.crypto_forecasts from anon, authenticated;

create or replace function public._rm() returns jsonb language sql stable security definer set search_path = public as $$ select params from public.crypto_models where active $$;
revoke all on function public._rm() from public, anon, authenticated;
create or replace function public._rm_ver() returns int language sql stable security definer set search_path = public as $$ select version from public.crypto_models where active $$;
revoke all on function public._rm_ver() from public, anon, authenticated;

-- ---------- vecteur X = [D, O, P, V, L, C, A] pour une monnaie ----------
create or replace function public._ra_x(p_symbol text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare a public.crypto_assets; last numeric; p24 numeric; d numeric; o numeric; p numeric; v numeric; l numeric; c numeric; act bigint; bid numeric; ask numeric; tb numeric; ts numeric; pt numeric; mom numeric; first_at timestamptz; last_at timestamptz; n7 bigint; tot numeric;
begin
  select * into a from public.crypto_assets where symbol = p_symbol;
  select price, at into last, last_at from public.crypto_trades where symbol = p_symbol order by id desc limit 1;
  select price into p24 from public.crypto_trades where symbol = p_symbol and at <= now() - interval '24 hours' order by id desc limit 1;
  select coalesce(sum((qty - filled) * price),0) into d from public.crypto_orders where symbol = p_symbol and side = 'buy' and status in ('open','partial') and kind <> 'treasury';
  select coalesce(sum((qty - filled) * price),0) into o from public.crypto_orders where symbol = p_symbol and side = 'sell' and status in ('open','partial') and kind <> 'treasury';
  select max(price) into bid from public.crypto_orders where symbol = p_symbol and side = 'buy' and status in ('open','partial');
  select min(price) into ask from public.crypto_orders where symbol = p_symbol and side = 'sell' and status in ('open','partial');
  p := case when d + o > 0 then (d - o) / (d + o) else 0 end;
  select coalesce(sum(case when taker_side = 'buy' then qty end),0), coalesce(sum(case when taker_side = 'sell' then qty end),0), count(*) into tb, ts, act from public.crypto_trades where symbol = p_symbol and at > now() - interval '24 hours';
  pt := case when tb + ts > 0 then (tb - ts) / (tb + ts) else 0 end;
  select coalesce(stddev_samp(ln(price / nullif(lp, 0))), 0) into v from (select price, lag(price) over (order by id) lp from public.crypto_trades where symbol = p_symbol and at > now() - interval '24 hours') x where lp is not null;
  l := case when bid is not null and ask is not null and ask + bid > 0 then greatest(0, 1 - (ask - bid) / ((ask + bid) / 2)) else 0 end;
  select coalesce(sum(qty),0) into tot from public.crypto_holdings where symbol = p_symbol and qty > 0 and user_id <> public._ctreas();
  select coalesce(sum(power(qty / nullif(tot,0), 2)),0) into c from public.crypto_holdings where symbol = p_symbol and qty > 0 and user_id <> public._ctreas();
  mom := case when last is not null and p24 is not null and p24 > 0 then ln(last / p24) else 0 end;
  select min(at), count(*) into first_at, n7 from public.crypto_trades where symbol = p_symbol and at > now() - interval '7 days';
  select min(at) into first_at from public.crypto_trades where symbol = p_symbol;
  return jsonb_build_object('symbol', p_symbol, 'last', last, 'ref', coalesce(last, a.price0), 'price0', a.price0, 'D', round(d,1), 'O', round(o,1), 'P', round(p,4), 'Pt', round(pt,4),
    'V', round(coalesce(v,0),6), 'L', round(l,4), 'C', round(coalesce(c,0),4), 'A', act, 'mom', round(mom,6), 'n7', n7,
    'age_h', case when last_at is not null then round((extract(epoch from now() - last_at) / 3600)::numeric, 2) end,
    'hist_d', case when first_at is not null then round((extract(epoch from now() - first_at) / 86400)::numeric, 3) else 0 end);
end $$;
revoke all on function public._ra_x(text) from public, anon, authenticated;

-- ---------- fiabilité passée d'un assistant : 0.5 sans historique, sinon fonction de l'erreur moyenne ----------
create or replace function public._ra_track(p_assistant text, p_symbol text) returns jsonb language sql security definer stable set search_path = public as $$
  select jsonb_build_object('n', count(*), 'hit', case when count(*) > 0 then round(avg(case when hit then 1 else 0 end)::numeric, 4) end,
    'mae', case when count(*) > 0 then round(avg(abs(err))::numeric, 6) end,
    'T', case when count(*) >= 5 then round((0.2 + 0.8 * greatest(0, 1 - avg(abs(err)) / 0.05))::numeric, 4) else 0.5 end)
  from (select hit, err from public.crypto_forecasts where assistant = p_assistant and (p_symbol is null or symbol = p_symbol) and scored_at is not null and err is not null order by id desc limit 50) z $$;
revoke all on function public._ra_track(text, text) from public, anon, authenticated;

-- ---------- analyse complète d'une monnaie (lecture seule) ----------
create or replace function public._ra_analyze(p_symbol text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare m jsonb := public._rm(); x jsonb := public._ra_x(p_symbol); mx numeric := (m->>'max')::numeric; pmix numeric; er numeric; et numeric;
  agp numeric; agm numeric; breadth numeric; nasset int; ntr bigint; mtr bigint; mage numeric;
  q_r numeric; q_t numeric; f_r numeric; f_t numeric; h numeric; tr jsonb; tt jsonb; c_r numeric; c_t numeric; ert numeric; crt numeric; div boolean; xr numeric; xv numeric;
begin
  pmix := 0.5 * (x->>'P')::numeric + 0.5 * (x->>'Pt')::numeric;
  er := (((m->>'kp')::numeric * pmix + (m->>'km')::numeric * greatest(-0.3, least(0.3, (x->>'mom')::numeric))) / (1 + (m->>'kv')::numeric * (x->>'V')::numeric));
  er := greatest(-mx, least(mx, er));
  -- Tachter : vue globale du marché
  select count(*), avg(0.5 * (y->>'P')::numeric + 0.5 * (y->>'Pt')::numeric), avg((y->>'mom')::numeric), avg(case when (y->>'mom')::numeric > 0 then 1.0 when (y->>'mom')::numeric < 0 then 0.0 else 0.5 end)
    into nasset, agp, agm, breadth from (select public._ra_x(symbol) y from public.crypto_assets where state = 'active') z;
  et := (m->>'kg')::numeric * coalesce(agp,0) + (m->>'kb')::numeric * (coalesce(breadth,0.5) - 0.5) * 2 + (m->>'kmt')::numeric * coalesce(agm,0) * 0.1
        + (m->>'kr')::numeric * greatest(-1, least(1, ln((x->>'price0')::numeric / (x->>'ref')::numeric)));
  et := greatest(-mx, least(mx, et));
  select count(*) into ntr from public.crypto_trades where symbol = p_symbol and at > now() - interval '7 days';
  select count(*), coalesce(extract(epoch from now() - max(at)) / 3600, 9999) into mtr, mage from public.crypto_trades where at > now() - interval '24 hours';
  q_r := least(1, ntr / 20.0); q_t := least(1, mtr / 50.0);
  f_r := case when (x->>'age_h') is null then 0 else exp(-(x->>'age_h')::numeric / 48) end;
  f_t := exp(-least(mage, 9999) / 48);
  h := least(1, (x->>'hist_d')::numeric / 7);
  tr := public._ra_track('ruther', p_symbol); tt := public._ra_track('tachter', null);
  c_r := q_r * f_r * (tr->>'T')::numeric * h; c_t := q_t * f_t * (tt->>'T')::numeric * h;
  if c_r + c_t > 0 then ert := (c_r * er + c_t * et) / (c_r + c_t); crt := (c_r + c_t) / 2; else ert := 0; crt := 0; end if;
  div := c_r > 0.05 and c_t > 0.05 and abs(er - et) > 0.01 and (sign(er) <> sign(et) or abs(er - et) > 0.03);
  return jsonb_build_object('symbol', p_symbol, 'model', public._rm_ver(), 'X', x,
    'ruther', jsonb_build_object('E', round(er,6), 'conf', round(c_r,4), 'Q', round(q_r,3), 'F', round(f_r,3), 'T', (tr->>'T')::numeric, 'H', round(h,3), 'track', tr),
    'tachter', jsonb_build_object('E', round(et,6), 'conf', round(c_t,4), 'Q', round(q_t,3), 'F', round(f_t,3), 'T', (tt->>'T')::numeric, 'H', round(h,3), 'track', tt,
       'market', jsonb_build_object('assets', nasset, 'pressure', round(coalesce(agp,0),4), 'momentum', round(coalesce(agm,0),6), 'breadth', round(coalesce(breadth,0.5),3), 'trades24', mtr)),
    'rt', jsonb_build_object('E', round(ert,6), 'conf', round(crt,4), 'track', public._ra_track('rt', p_symbol)),
    'divergence', div, 'enough', crt > 0);
end $$;
revoke all on function public._ra_analyze(text) from public, anon, authenticated;

-- horizon : facteur sqrt(heures) sur l'estimation à 1 h, borné
create or replace function public._ra_hz(p_h text) returns numeric language sql immutable as $$ select case p_h when '5m' then 5.0/60 when '1h' then 1 when '24h' then 24 when '7d' then 168 end $$;
create or replace function public._ra_hi(p_h text) returns interval language sql immutable as $$ select case p_h when '5m' then interval '5 minutes' when '1h' then interval '1 hour' when '24h' then interval '24 hours' when '7d' then interval '7 days' end $$;

-- ---------- moteur : consigne les prévisions puis note celles arrivées à échéance ----------
create or replace function public.crypto_engine_tick() returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; h text; r jsonb; mdl int := public._rm_ver(); mx numeric := (public._rm()->>'max')::numeric; ins int := 0; sc int := 0; f record; pr numeric; e numeric; who text; ex numeric; cf numeric; gap interval;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not pg_try_advisory_xact_lock(hashtext('crypto:engine')) then return jsonb_build_object('logged', 0, 'scored', 0, 'busy', true); end if;
  for a in select symbol from public.crypto_assets where state = 'active' and exists(select 1 from public.crypto_trades t where t.symbol = crypto_assets.symbol) loop
    r := public._ra_analyze(a.symbol);
    select price into pr from public.crypto_trades where symbol = a.symbol order by id desc limit 1;
    foreach h in array array['5m','1h','24h','7d'] loop
      gap := greatest(interval '5 minutes', least(public._ra_hi(h) / 4, interval '1 hour'));
      foreach who in array array['ruther','tachter','rt'] loop
        e := (r->who->>'E')::numeric; cf := (r->who->>'conf')::numeric;
        if cf <= 0 then continue; end if;
        ex := greatest(-mx * 2, least(mx * 2, e * sqrt(public._ra_hz(h))));
        if exists(select 1 from public.crypto_forecasts where symbol = a.symbol and assistant = who and horizon = h and made_at > now() - gap) then continue; end if;
        insert into public.crypto_forecasts(symbol, assistant, model, horizon, target_at, p0, exp_ret, conf) values (a.symbol, who, mdl, h, now() + public._ra_hi(h), pr, ex, cf);
        ins := ins + 1;
      end loop;
    end loop;
  end loop;
  for f in select * from public.crypto_forecasts where scored_at is null and target_at <= now() order by id limit 500 loop
    select price into pr from public.crypto_trades where symbol = f.symbol and at <= f.target_at order by id desc limit 1;
    if pr is null then update public.crypto_forecasts set scored_at = now() where id = f.id; continue; end if;
    update public.crypto_forecasts set actual = pr, err = round((ln(pr / f.p0) - f.exp_ret)::numeric, 6),
      hit = (sign(ln(pr / f.p0)) = sign(f.exp_ret)) or (abs(ln(pr / f.p0)) < 0.001 and abs(f.exp_ret) < 0.005), scored_at = now() where id = f.id;
    sc := sc + 1;
  end loop;
  return jsonb_build_object('logged', ins, 'scored', sc);
end $$;
revoke all on function public.crypto_engine_tick() from public, anon;
grant execute on function public.crypto_engine_tick() to authenticated;

-- ---------- lecture pour l'interface ----------
create or replace function public.crypto_intel(p_symbol text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare s text := upper(btrim(coalesce(p_symbol,''))); r jsonb; pr numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not exists(select 1 from public.crypto_assets where symbol = s) then raise exception 'Cryptomonnaie introuvable'; end if;
  r := public._ra_analyze(s);
  select price into pr from public.crypto_trades where symbol = s order by id desc limit 1;
  return r || jsonb_build_object('price', pr,     'horizons', (select jsonb_agg(jsonb_build_object('h', h, 'ruther', (r->'ruther'->>'E')::numeric * sqrt(public._ra_hz(h)), 'tachter', (r->'tachter'->>'E')::numeric * sqrt(public._ra_hz(h)), 'rt', (r->'rt'->>'E')::numeric * sqrt(public._ra_hz(h)),
        'price_rt', case when pr is not null then round((pr * exp(greatest(-0.4, least(0.4, (r->'rt'->>'E')::numeric * sqrt(public._ra_hz(h))))))::numeric, 4) end)) from unnest(array['5m','1h','24h','7d']) h),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', made_at, 'who', assistant, 'h', horizon, 'exp', exp_ret, 'real', case when actual is not null then round(ln(actual / p0)::numeric, 6) end, 'err', err, 'hit', hit) order by id desc)
        from (select * from public.crypto_forecasts where symbol = s order by id desc limit 24) f), '[]'::jsonb));
end $$;
revoke all on function public.crypto_intel(text) from public, anon;
grant execute on function public.crypto_intel(text) to authenticated;

create or replace function public.crypto_intel_market() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  return jsonb_build_object('model', public._rm_ver(), 'rows', coalesce((select jsonb_agg(jsonb_build_object('symbol', symbol, 'name', name, 'a', public._ra_analyze(symbol)) order by sort) from public.crypto_assets where state = 'active'), '[]'::jsonb),
    'scored', (select count(*) from public.crypto_forecasts where scored_at is not null and err is not null), 'pending', (select count(*) from public.crypto_forecasts where scored_at is null));
end $$;
revoke all on function public.crypto_intel_market() from public, anon;
grant execute on function public.crypto_intel_market() to authenticated;

-- ---------- adaptation versionnée et bornée (commandant) ----------
create or replace function public.crypto_model_adapt() returns int language plpgsql security definer set search_path = public as $$
declare m jsonb := public._rm(); nm jsonb := public._rm(); tr jsonb; tt jsonb; nv int; hr numeric; ch text := '';
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  tr := public._ra_track('ruther', null); tt := public._ra_track('tachter', null);
  if coalesce((tr->>'n')::int,0) < 10 and coalesce((tt->>'n')::int,0) < 10 then raise exception 'Pas assez de prévisions notées (10 minimum)'; end if;
  if coalesce((tr->>'n')::int,0) >= 10 then hr := (tr->>'hit')::numeric;
    if hr < 0.45 then nm := jsonb_set(nm, '{kp}', to_jsonb(greatest(0.01, round(((nm->>'kp')::numeric * 0.9)::numeric, 5)))); nm := jsonb_set(nm, '{km}', to_jsonb(greatest(0.1, round(((nm->>'km')::numeric * 0.9)::numeric, 5)))); ch := ch || 'Ruther -10 % ';
    elsif hr > 0.55 then nm := jsonb_set(nm, '{kp}', to_jsonb(least(0.2, round(((nm->>'kp')::numeric * 1.05)::numeric, 5)))); nm := jsonb_set(nm, '{km}', to_jsonb(least(1.0, round(((nm->>'km')::numeric * 1.05)::numeric, 5)))); ch := ch || 'Ruther +5 % '; end if; end if;
  if coalesce((tt->>'n')::int,0) >= 10 then hr := (tt->>'hit')::numeric;
    if hr < 0.45 then nm := jsonb_set(nm, '{kg}', to_jsonb(greatest(0.01, round(((nm->>'kg')::numeric * 0.9)::numeric, 5)))); nm := jsonb_set(nm, '{kb}', to_jsonb(greatest(0.005, round(((nm->>'kb')::numeric * 0.9)::numeric, 5)))); ch := ch || 'Tachter -10 % ';
    elsif hr > 0.55 then nm := jsonb_set(nm, '{kg}', to_jsonb(least(0.15, round(((nm->>'kg')::numeric * 1.05)::numeric, 5)))); nm := jsonb_set(nm, '{kb}', to_jsonb(least(0.1, round(((nm->>'kb')::numeric * 1.05)::numeric, 5)))); ch := ch || 'Tachter +5 % '; end if; end if;
  if ch = '' then raise exception 'Aucun ajustement nécessaire (taux de réussite entre 45 %% et 55 %%)'; end if;
  update public.crypto_models set active = false where active;
  insert into public.crypto_models(params, active, note, by_user) values (nm, true, btrim(ch), auth.uid()) returning version into nv;
  perform public.log_admin('crypto_modele', nv::text, jsonb_build_object('note', btrim(ch)));
  return nv;
end $$;
revoke all on function public.crypto_model_adapt() from public, anon;
grant execute on function public.crypto_model_adapt() to authenticated;

create or replace function public.crypto_model_activate(p_version int) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if not exists(select 1 from public.crypto_models where version = p_version) then raise exception 'Version introuvable'; end if;
  update public.crypto_models set active = false where active;
  update public.crypto_models set active = true where version = p_version;
  perform public.log_admin('crypto_modele_activer', p_version::text, '{}'::jsonb);
end $$;
revoke all on function public.crypto_model_activate(int) from public, anon;
grant execute on function public.crypto_model_activate(int) to authenticated;

create or replace function public.crypto_models_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('version', version, 'at', created_at, 'active', active, 'params', params, 'note', note) order by version desc) from public.crypto_models), '[]'::jsonb);
end $$;
revoke all on function public.crypto_models_list() from public, anon;
grant execute on function public.crypto_models_list() to authenticated;
notify pgrst, 'reload schema';
