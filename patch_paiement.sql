-- Communicer! — patch paiement : packs de jetons, commandes, codes promo (additif)
create table if not exists public.token_packs (
  code text primary key, tokens int not null check (tokens > 0), cents int not null check (cents > 0), sort int not null default 0
);
insert into public.token_packs(code, tokens, cents, sort) values
  ('p300', 300, 89, 1), ('p2450', 2450, 699, 2), ('p10450', 10450, 1799, 3), ('p34500', 34500, 5299, 4), ('p85000', 85000, 11999, 5)
on conflict (code) do update set tokens = excluded.tokens, cents = excluded.cents, sort = excluded.sort;

create table if not exists public.promo_codes (
  id bigint generated always as identity primary key,
  code text not null, pct int not null check (pct between 1 and 100),
  items text[] not null default array['*'], max_uses int check (max_uses is null or max_uses > 0),
  uses int not null default 0, active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now()
);
create unique index if not exists promo_codes_code on public.promo_codes (upper(code));

create table if not exists public.orders (
  id bigint generated always as identity primary key,
  ref text unique, user_id uuid not null references public.profiles(id) on delete cascade,
  pack_code text not null references public.token_packs(code), tokens int not null,
  cents_base int not null, pct int not null default 0, cents_final int not null,
  promo_id bigint references public.promo_codes(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','paid','cancelled')),
  provider_ref text, created_at timestamptz not null default now(), paid_at timestamptz
);
create index if not exists orders_user on public.orders (user_id, id desc);
create or replace function public.trg_order_ref() returns trigger language plpgsql as $$
begin new.ref := 'C-' || lpad(new.id::text, 6, '0'); return new; end $$;
drop trigger if exists order_ref on public.orders;
create trigger order_ref before insert on public.orders for each row execute function public.trg_order_ref();

alter table public.token_packs enable row level security;
alter table public.promo_codes enable row level security;
alter table public.orders enable row level security;
revoke all on public.token_packs, public.promo_codes, public.orders from anon, authenticated;

insert into public.tok_cfg(k, v) values ('pay_url', '') on conflict do nothing;

create or replace function public.pack_list() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'tokens', tokens, 'cents', cents) order by sort), '[]'::jsonb) from public.token_packs
$$;

-- calcule le prix final ; lève une erreur lisible si le code est inutilisable
create or replace function public._promo_calc(p_pack text, p_code text, out pid bigint, out pct int, out base int, out final int)
language plpgsql security definer set search_path = public as $$
declare pk public.token_packs; pr public.promo_codes;
begin
  select * into pk from public.token_packs where code = p_pack;
  if not found then raise exception 'Pack introuvable'; end if;
  base := pk.cents; pct := 0; pid := null;
  if nullif(trim(coalesce(p_code,'')), '') is not null then
    select * into pr from public.promo_codes where upper(code) = upper(trim(p_code));
    if not found or not pr.active then raise exception 'Code promo invalide'; end if;
    if pr.max_uses is not null and pr.uses >= pr.max_uses then raise exception 'Ce code promo a atteint son nombre maximal d’utilisations'; end if;
    if not ('*' = any(pr.items) or p_pack = any(pr.items)) then raise exception 'Ce code ne s’applique pas à ce pack'; end if;
    pid := pr.id; pct := pr.pct;
  end if;
  final := round(base * (100 - pct) / 100.0)::int;
end $$;
revoke all on function public._promo_calc(text, text) from public, anon, authenticated;

create or replace function public.promo_preview(p_pack text, p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  perform public.rate_ok('promo:' || auth.uid()::text, 30, 600);
  select * into r from public._promo_calc(p_pack, p_code);
  return jsonb_build_object('pct', r.pct, 'base', r.base, 'final', r.final);
end $$;

create or replace function public._order_pay(p_ref text, p_provider text) returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where ref = p_ref for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if o.status = 'paid' then return; end if;
  update public.orders set status = 'paid', paid_at = now(), provider_ref = coalesce(p_provider, provider_ref) where id = o.id;
  if o.promo_id is not null then update public.promo_codes set uses = uses + 1 where id = o.promo_id; end if;
  perform public.tok_add(o.user_id, o.tokens, 'achat ' || o.ref, null);
end $$;
revoke all on function public._order_pay(text, text) from public, anon, authenticated;

create or replace function public.order_create(p_pack text, p_code text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; o public.orders; pk public.token_packs; url text;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  perform public.rate_ok('order:' || auth.uid()::text, 8, 3600);
  select * into r from public._promo_calc(p_pack, p_code);
  select * into pk from public.token_packs where code = p_pack;
  insert into public.orders(user_id, pack_code, tokens, cents_base, pct, cents_final, promo_id)
    values (auth.uid(), pk.code, pk.tokens, r.base, r.pct, r.final, r.pid) returning * into o;
  if o.cents_final = 0 then
    perform public._order_pay(o.ref, 'gratuit');
    return jsonb_build_object('ref', o.ref, 'paid', true, 'tokens', o.tokens);
  end if;
  select nullif(v, '') into url from public.tok_cfg where k = 'pay_url';
  return jsonb_build_object('ref', o.ref, 'paid', false, 'cents', o.cents_final, 'tokens', o.tokens, 'url', url);
end $$;

-- appelée uniquement par la fonction serveur du fournisseur de paiement (service_role)
create or replace function public.order_fulfill(p_ref text, p_provider text, p_cents int) returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  select * into o from public.orders where ref = p_ref;
  if not found then raise exception 'Commande introuvable'; end if;
  if p_cents < o.cents_final then raise exception 'Montant insuffisant'; end if;
  perform public._order_pay(p_ref, p_provider);
end $$;
revoke all on function public.order_fulfill(text, text, int) from public, anon, authenticated;
grant execute on function public.order_fulfill(text, text, int) to service_role;

create or replace function public.order_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (select jsonb_build_object('ref', ref, 'tokens', tokens, 'cents', cents_final, 'status', status, 'at', created_at) x
    from public.orders where user_id = auth.uid() order by id desc limit 5) q
$$;

-- commandant : codes promo
create or replace function public.promo_create(p_code text, p_pct int, p_items text[], p_max int) returns void language plpgsql security definer set search_path = public as $$
declare it text[]; c text := upper(trim(p_code));
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if c !~ '^[A-Z0-9_-]{3,24}$' then raise exception 'Code invalide (3 à 24 caractères : lettres, chiffres, - et _)'; end if;
  if p_pct is null or p_pct < 1 or p_pct > 100 then raise exception 'Pourcentage entre 1 et 100'; end if;
  it := coalesce(nullif(p_items, '{}'), array['*']);
  if not ('*' = any(it)) and exists(select 1 from unnest(it) x where x not in (select code from public.token_packs)) then raise exception 'Article inconnu'; end if;
  insert into public.promo_codes(code, pct, items, max_uses, created_by) values (c, p_pct, it, p_max, auth.uid());
  perform public.log_admin('promo_cree', c, jsonb_build_object('pct', p_pct, 'items', it, 'max', p_max));
exception when unique_violation then raise exception 'Ce code existe déjà';
end $$;
create or replace function public.promo_list() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', code, 'pct', pct, 'items', items, 'max', max_uses, 'uses', uses, 'active', active) order by id desc) from public.promo_codes), '[]'::jsonb);
end $$;
create or replace function public.promo_set(p_code text, p_active boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  update public.promo_codes set active = p_active where upper(code) = upper(p_code);
  perform public.log_admin('promo_etat', upper(p_code), jsonb_build_object('actif', p_active));
end $$;
create or replace function public.pay_cfg_set(p_url text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_url <> '' and p_url !~ '^https://' then raise exception 'Lien https requis'; end if;
  insert into public.tok_cfg(k, v) values ('pay_url', p_url) on conflict (k) do update set v = excluded.v;
  perform public.log_admin('paiement_lien', 'pay_url', jsonb_build_object('url', p_url));
end $$;
do $$ declare f text; begin foreach f in array array['pack_list()','promo_preview(text,text)','order_create(text,text)','order_mine()','promo_create(text,int,text[],int)','promo_list()','promo_set(text,boolean)','pay_cfg_set(text)'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
