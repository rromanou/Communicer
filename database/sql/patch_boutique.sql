-- ============================================================================
-- Communicer! — Patch « boutique 2 » (additif, relançable)
-- Codes promo avancés (période, utilisations par personne, conditions), packs de coquelicots, échange sécurisé coquelicots -> jetons.
-- À exécuter après patch_paiement.sql et patch_apparence.sql.
-- ============================================================================
-- ---------- codes promo ----------
alter table public.promo_codes add column if not exists valid_from timestamptz;
alter table public.promo_codes add column if not exists valid_until timestamptz;
alter table public.promo_codes add column if not exists per_user int check (per_user is null or per_user > 0);
alter table public.promo_codes add column if not exists cond_badge text;
alter table public.promo_codes add column if not exists cond_purchase boolean not null default false;

-- ---------- packs de coquelicots ----------
alter table public.token_packs add column if not exists medals int not null default 0;
alter table public.orders add column if not exists medals int not null default 0;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.token_packs'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%tokens%' loop
    execute format('alter table public.token_packs drop constraint %I', c);
  end loop;
end $$;
alter table public.token_packs drop constraint if exists token_packs_content_chk;
alter table public.token_packs add constraint token_packs_content_chk check (tokens >= 0 and medals >= 0 and (tokens > 0 or medals > 0));
alter table public.orders add column if not exists tokens_dummy int;
alter table public.orders drop column if exists tokens_dummy;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.orders'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%tokens%' loop
    execute format('alter table public.orders drop constraint %I', c);
  end loop;
end $$;
insert into public.token_packs(code, tokens, medals, cents, sort) values
  ('m20', 0, 20, 999, 10), ('m80', 0, 80, 3899, 11), ('m125', 0, 125, 5799, 12)
on conflict (code) do update set tokens = excluded.tokens, medals = excluded.medals, cents = excluded.cents, sort = excluded.sort;

create or replace function public.pack_list() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'tokens', tokens, 'medals', medals, 'cents', cents) order by sort), '[]'::jsonb) from public.token_packs
$$;

create or replace function public._promo_calc(p_pack text, p_code text, out pid bigint, out pct int, out base int, out final int)
language plpgsql security definer set search_path = public as $$
declare pk public.token_packs; pr public.promo_codes; n int;
begin
  select * into pk from public.token_packs where code = p_pack;
  if not found then raise exception 'Pack introuvable'; end if;
  base := pk.cents; pct := 0; pid := null;
  if nullif(trim(coalesce(p_code,'')), '') is not null then
    select * into pr from public.promo_codes where upper(code) = upper(trim(p_code));
    if not found or not pr.active then raise exception 'Code promo invalide'; end if;
    if pr.valid_from is not null and now() < pr.valid_from then raise exception 'Ce code promo n’est pas encore valide'; end if;
    if pr.valid_until is not null and now() > pr.valid_until then raise exception 'Ce code promo est expiré'; end if;
    if pr.max_uses is not null and pr.uses >= pr.max_uses then raise exception 'Ce code promo a atteint son nombre maximal d’utilisations'; end if;
    if not ('*' = any(pr.items) or p_pack = any(pr.items)) then raise exception 'Ce code ne s’applique pas à ce pack'; end if;
    if pr.per_user is not null then
      select count(*) into n from public.orders where user_id = auth.uid() and promo_id = pr.id and status = 'paid';
      if n >= pr.per_user then raise exception 'Vous avez déjà utilisé ce code le nombre de fois permis'; end if;
    end if;
    if pr.cond_badge is not null and not exists(select 1 from public.user_badges where user_id = auth.uid() and code = pr.cond_badge) then raise exception 'Ce code est réservé aux détenteurs d’un badge précis'; end if;
    if pr.cond_purchase and not exists(select 1 from public.orders where user_id = auth.uid() and status = 'paid') then raise exception 'Ce code est réservé aux personnes ayant déjà acheté'; end if;
    pid := pr.id; pct := pr.pct;
  end if;
  final := round(base * (100 - pct) / 100.0)::int;
end $$;
revoke all on function public._promo_calc(text, text) from public, anon, authenticated;

create or replace function public._order_pay(p_ref text, p_provider text) returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where ref = p_ref for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if o.status = 'paid' then return; end if;
  update public.orders set status = 'paid', paid_at = now(), provider_ref = coalesce(p_provider, provider_ref) where id = o.id;
  if o.promo_id is not null then update public.promo_codes set uses = uses + 1 where id = o.promo_id; end if;
  if o.tokens > 0 then perform public.tok_add(o.user_id, o.tokens, 'achat ' || o.ref, null); end if;
  if o.medals > 0 then
    insert into public.wallets(user_id) values (o.user_id) on conflict do nothing;
    update public.wallets set medals = medals + o.medals where user_id = o.user_id;
    insert into public.token_log(user_id, delta, reason) values (o.user_id, 0, 'achat ' || o.ref || ' : ' || o.medals || ' coquelicots');
  end if;
end $$;
revoke all on function public._order_pay(text, text) from public, anon, authenticated;

create or replace function public.order_create(p_pack text, p_code text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; o public.orders; pk public.token_packs; url text;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  perform public.rate_ok('order:' || auth.uid()::text, 8, 3600);
  select * into r from public._promo_calc(p_pack, p_code);
  select * into pk from public.token_packs where code = p_pack;
  insert into public.orders(user_id, pack_code, tokens, medals, cents_base, pct, cents_final, promo_id)
    values (auth.uid(), pk.code, pk.tokens, pk.medals, r.base, r.pct, r.final, r.pid) returning * into o;
  if o.cents_final = 0 then
    perform public._order_pay(o.ref, 'gratuit');
    return jsonb_build_object('ref', o.ref, 'paid', true, 'tokens', o.tokens, 'medals', o.medals);
  end if;
  select nullif(v, '') into url from public.tok_cfg where k = 'pay_url';
  return jsonb_build_object('ref', o.ref, 'paid', false, 'cents', o.cents_final, 'tokens', o.tokens, 'medals', o.medals, 'url', url);
end $$;

create or replace function public.order_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (select jsonb_build_object('ref', ref, 'tokens', tokens, 'medals', medals, 'cents', cents_final, 'status', status, 'at', created_at) x
    from public.orders where user_id = auth.uid() order by id desc limit 5) q
$$;

drop function if exists public.promo_create(text, int, text[], int);
create or replace function public.promo_create(p_code text, p_pct int, p_items text[], p_max int, p_from timestamptz default null, p_until timestamptz default null,
  p_per_user int default null, p_badge text default null, p_purchase boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare it text[]; c text := upper(trim(p_code));
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if c !~ '^[A-Z0-9_-]{3,24}$' then raise exception 'Code invalide (3 à 24 caractères : lettres, chiffres, - et _)'; end if;
  if p_pct is null or p_pct < 1 or p_pct > 100 then raise exception 'Pourcentage entre 1 et 100'; end if;
  if p_from is not null and p_until is not null and p_until <= p_from then raise exception 'La fin doit suivre le début'; end if;
  if p_badge is not null and not exists(select 1 from public.badge_defs where code = p_badge) then raise exception 'Badge inconnu'; end if;
  it := coalesce(nullif(p_items, '{}'), array['*']);
  if not ('*' = any(it)) and exists(select 1 from unnest(it) x where x not in (select code from public.token_packs)) then raise exception 'Article inconnu'; end if;
  insert into public.promo_codes(code, pct, items, max_uses, valid_from, valid_until, per_user, cond_badge, cond_purchase, created_by)
    values (c, p_pct, it, p_max, p_from, p_until, p_per_user, nullif(p_badge, ''), coalesce(p_purchase, false), auth.uid());
  perform public.log_admin('promo_cree', c, jsonb_build_object('pct', p_pct, 'items', it, 'max', p_max, 'du', p_from, 'au', p_until, 'par_personne', p_per_user, 'badge', p_badge, 'achat', p_purchase));
exception when unique_violation then raise exception 'Ce code existe déjà';
end $$;
revoke all on function public.promo_create(text, int, text[], int, timestamptz, timestamptz, int, text, boolean) from public, anon;
grant execute on function public.promo_create(text, int, text[], int, timestamptz, timestamptz, int, text, boolean) to authenticated;

create or replace function public.promo_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', code, 'pct', pct, 'items', items, 'max', max_uses, 'uses', uses, 'active', active, 'from', valid_from, 'until', valid_until, 'per_user', per_user, 'badge', cond_badge, 'purchase', cond_purchase) order by id desc) from public.promo_codes), '[]'::jsonb);
end $$;

-- ---------- échange coquelicots -> jetons ----------
insert into public.tok_cfg(k, v) values ('poppy_rate', '283.75'), ('poppy_rate_old', '183.75') on conflict (k) do update set v = excluded.v;
create or replace function public.medals_rate() returns jsonb language sql security definer stable set search_path = public as $$
  select jsonb_build_object('rate', (select v::numeric from public.tok_cfg where k = 'poppy_rate'), 'old', (select v::numeric from public.tok_cfg where k = 'poppy_rate_old'))
$$;
create or replace function public.medals_exchange(p_amount int) returns jsonb language plpgsql security definer set search_path = public as $$
declare w public.wallets; rate numeric; gain numeric; b numeric;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 then raise exception 'Quantité invalide (1 à 10 000)'; end if;
  perform public.rate_ok('medx:' || auth.uid()::text, 20, 3600);
  select (v)::numeric into rate from public.tok_cfg where k = 'poppy_rate';
  select * into w from public.wallets where user_id = auth.uid() for update;
  if not found or w.medals < p_amount then raise exception 'Coquelicots insuffisants'; end if;
  gain := floor(p_amount * rate * 10) / 10;
  update public.wallets set medals = medals - p_amount where user_id = auth.uid();
  b := public.tok_add(auth.uid(), gain, 'échange de ' || p_amount || ' coquelicots', null);
  return jsonb_build_object('gain', gain, 'balance', b, 'medals', w.medals - p_amount);
end $$;
revoke all on function public.medals_rate(), public.medals_exchange(int) from public, anon;
grant execute on function public.medals_rate(), public.medals_exchange(int) to authenticated;
