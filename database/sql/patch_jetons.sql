-- ============================================================================
-- Communicer! — Patch 10 (additif, relançable) : jetons, parrainage, quêtes, boutique,
-- cadres, badges, emojis premium, Communicer Lite (9 jetons). À exécuter après patch_hierarchie.sql.
-- ============================================================================
create table if not exists public.wallets (user_id uuid primary key references public.profiles(id) on delete cascade, balance int not null default 0 check (balance >= 0), updated_at timestamptz not null default now());
create table if not exists public.token_log (id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id) on delete cascade,
  delta int not null, reason text not null, by_id uuid references public.profiles(id) on delete set null, at timestamptz not null default now());
create index if not exists token_log_user on public.token_log(user_id, id desc);
create table if not exists public.daily_claims (user_id uuid not null references public.profiles(id) on delete cascade, day date not null, primary key (user_id, day));
create table if not exists public.referral_codes (user_id uuid primary key references public.profiles(id) on delete cascade, code text not null unique check (code ~ '^[A-Z0-9]{5}$'));
alter table public.referrals add column if not exists paid boolean not null default false;
create table if not exists public.quest_defs (code text primary key, title text not null, period text not null check (period in ('day','week')), target int not null, reward int not null, kind text not null, sort int not null default 0);
create table if not exists public.quest_events (user_id uuid not null references public.profiles(id) on delete cascade, kind text not null, day date not null, n int not null default 0, primary key (user_id, kind, day));
create table if not exists public.quest_claims (user_id uuid not null references public.profiles(id) on delete cascade, code text not null, period_start date not null, primary key (user_id, code, period_start));
create table if not exists public.shop_items (code text primary key, kind text not null check (kind in ('frame','badge','pack','feature')), name text not null, descr text not null default '', price int check (price is null or price >= 0), sort int not null default 0);
create table if not exists public.inventory (user_id uuid not null references public.profiles(id) on delete cascade, code text not null references public.shop_items(code), at timestamptz not null default now(), source text not null default 'achat', primary key (user_id, code));
create table if not exists public.equipped (user_id uuid primary key references public.profiles(id) on delete cascade, frame text references public.shop_items(code), badge text references public.shop_items(code));
create table if not exists public.premium_emoji (code text primary key, pack text not null references public.shop_items(code), label text not null);
do $$ declare t text; begin
  foreach t in array array['wallets','token_log','daily_claims','referral_codes','quest_defs','quest_events','quest_claims','shop_items','inventory','equipped','premium_emoji'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

insert into public.quest_defs(code, title, period, target, reward, kind, sort) values
 ('msg10', 'Envoyer 10 messages', 'day', 10, 2, 'msgs', 1),
 ('game1', 'Jouer une partie', 'day', 1, 3, 'game', 2),
 ('call1', 'Faire un appel', 'day', 1, 3, 'call', 3),
 ('login5', 'Se connecter 5 jours dans la semaine', 'week', 5, 8, 'login', 4),
 ('friend1', 'Ajouter un ami', 'week', 1, 5, 'friend', 5),
 ('msg200', 'Envoyer 200 messages', 'week', 200, 10, 'msgs', 6)
on conflict (code) do update set title = excluded.title, period = excluded.period, target = excluded.target, reward = excluded.reward, kind = excluded.kind, sort = excluded.sort;
insert into public.shop_items(code, kind, name, descr, price, sort) values
 ('frame_or','frame','Cadre or','Anneau doré autour de la photo',30,1),('frame_arc','frame','Cadre arc-en-ciel','Anneau multicolore animé',40,2),
 ('frame_feu','frame','Cadre feu','Anneau de flammes',50,3),('frame_neon','frame','Cadre néon','Anneau lumineux cyan',60,4),('frame_glace','frame','Cadre glace','Anneau bleu givré',35,5),
 ('badge_etoile','badge','Étoile','Badge étoile',20,10),('badge_flamme','badge','Flamme','Badge flamme',25,11),('badge_couronne','badge','Couronne','Badge couronne',80,12),
 ('badge_feuille','badge','Feuille','Badge feuille',15,13),('badge_eclair','badge','Éclair','Badge éclair',30,14),('badge_gemme','badge','Gemme','Badge gemme',45,15),
 ('badge_fondateur','badge','Fondateur','Remis par l’équipe uniquement',null,16),
 ('pack_visages','pack','Pack Visages','12 emojis premium : visages',25,20),('pack_nature','pack','Pack Nature','12 emojis premium : nature',25,21),
 ('lite','feature','Communicer Lite','Version économie d’énergie',9,30)
on conflict (code) do update set kind = excluded.kind, name = excluded.name, descr = excluded.descr, price = excluded.price, sort = excluded.sort;
insert into public.premium_emoji(code, pack, label)
select 'pe_v' || n, 'pack_visages', 'Visage ' || n from generate_series(1,12) n
on conflict (code) do nothing;
insert into public.premium_emoji(code, pack, label)
select 'pe_n' || n, 'pack_nature', 'Nature ' || n from generate_series(1,12) n
on conflict (code) do nothing;

-- ---------- internes ----------
create or replace function public.tok_add(p_user uuid, p_delta int, p_reason text, p_by uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare b int;
begin
  insert into public.wallets(user_id, balance) values (p_user, 0) on conflict do nothing;
  update public.wallets set balance = balance + p_delta, updated_at = now() where user_id = p_user returning balance into b;
  insert into public.token_log(user_id, delta, reason, by_id) values (p_user, p_delta, p_reason, p_by);
  return b;
end $$;
revoke all on function public.tok_add(uuid, int, text, uuid) from public, anon, authenticated;
create or replace function public.period_start(p text) returns date language sql stable as $$
  select case when p = 'week' then public.staff_week() else public.staff_today() end $$;

-- ---------- portefeuille, connexion quotidienne, parrainage ----------
create or replace function public.referral_check() returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select * from public.referrals where referrer_id = auth.uid() and not approved loop
    if (select created_at from public.profiles where id = r.referred_id) <= now() - interval '1 day'
       and (select count(*) from public.messages where sender_id = r.referred_id) >= 5 then
      update public.referrals set approved = true where id = r.id;
    end if;
  end loop;
  for r in select * from public.referrals where approved and not paid and (referrer_id = auth.uid() or referred_id = auth.uid()) loop
    update public.referrals set paid = true where id = r.id;
    perform public.tok_add(r.referrer_id, 10, 'parrainage approuvé');
    perform public.tok_add(r.referred_id, 5, 'bienvenue (parrainage)');
  end loop;
end $$;

create or replace function public.wallet_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare d date := public.staff_today(); got boolean := false; b int;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  insert into public.daily_claims(user_id, day) values (auth.uid(), d) on conflict do nothing;
  get diagnostics b = row_count;
  if b > 0 then perform public.tok_add(auth.uid(), 2, 'connexion quotidienne'); got := true; end if;
  perform public.referral_check();
  select balance into b from public.wallets where user_id = auth.uid();
  return jsonb_build_object('balance', b, 'daily', got,
    'refs', (select count(*) from public.referrals where referrer_id = auth.uid() and approved),
    'refs_pending', (select count(*) from public.referrals where referrer_id = auth.uid() and not approved),
    'log', coalesce((select jsonb_agg(jsonb_build_object('delta', delta, 'reason', reason, 'at', at) order by id desc) from (select * from public.token_log where user_id = auth.uid() order by id desc limit 30) l), '[]'::jsonb));
end $$;

create or replace function public.referral_code_me()
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int := 0;
begin
  select code into c from public.referral_codes where user_id = auth.uid();
  if c is not null then return c; end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 1, 5));
    begin insert into public.referral_codes(user_id, code) values (auth.uid(), c); return c;
    exception when unique_violation then i := i + 1; if i > 20 then raise exception 'Réessayez'; end if; end;
  end loop;
end $$;

create or replace function public.referral_use(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  if exists(select 1 from public.referrals where referred_id = auth.uid()) then raise exception 'Vous avez déjà utilisé un code de parrainage'; end if;
  if (select created_at from public.profiles where id = auth.uid()) < now() - interval '7 days' then raise exception 'Le code doit être utilisé dans les 7 jours suivant l’inscription'; end if;
  select user_id into o from public.referral_codes where code = upper(trim(coalesce(p_code,'')));
  if o is null then raise exception 'Code invalide'; end if;
  if o = auth.uid() then raise exception 'Vous ne pouvez pas utiliser votre propre code'; end if;
  insert into public.referrals(referrer_id, referred_id) values (o, auth.uid());
  return (select username from public.profiles where id = o);
end $$;

-- ---------- quêtes ----------
create or replace function public.quest_value(p_user uuid, d public.quest_defs)
returns int language plpgsql security definer stable set search_path = public as $$
declare s date := public.period_start(d.period); e date := s + case when d.period = 'week' then 7 else 1 end; v int := 0;
begin
  if d.kind = 'msgs' then
    select count(*) into v from public.messages where sender_id = p_user and created_at >= s::timestamp at time zone 'America/Toronto' and created_at < e::timestamp at time zone 'America/Toronto';
  elsif d.kind = 'login' then
    select count(*) into v from public.daily_claims where user_id = p_user and day >= s and day < e;
  elsif d.kind = 'friend' then
    select count(*) into v from public.friendships where status = 'accepted' and (requester = p_user or addressee = p_user) and created_at >= s::timestamp at time zone 'America/Toronto';
  else
    select coalesce(sum(n), 0) into v from public.quest_events where user_id = p_user and kind = d.kind and day >= s and day < e;
  end if;
  return v;
end $$;
revoke all on function public.quest_value(uuid, public.quest_defs) from public, anon, authenticated;

create or replace function public.quests_list()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', d.code, 'title', d.title, 'period', d.period, 'target', d.target, 'reward', d.reward,
    'value', least(public.quest_value(auth.uid(), d), d.target),
    'claimed', exists(select 1 from public.quest_claims c where c.user_id = auth.uid() and c.code = d.code and c.period_start = public.period_start(d.period))) order by d.sort), '[]'::jsonb)
  from public.quest_defs d
$$;
create or replace function public.quest_event(p_kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('game','call') then raise exception 'Événement inconnu'; end if;
  insert into public.quest_events(user_id, kind, day, n) values (auth.uid(), p_kind, public.staff_today(), 1)
  on conflict (user_id, kind, day) do update set n = least(public.quest_events.n + 1, 20);
end $$;
create or replace function public.quest_claim(p_code text)
returns int language plpgsql security definer set search_path = public as $$
declare d public.quest_defs;
begin
  select * into d from public.quest_defs where code = p_code;
  if not found then raise exception 'Quête introuvable'; end if;
  if public.quest_value(auth.uid(), d) < d.target then raise exception 'Quête non terminée'; end if;
  begin insert into public.quest_claims(user_id, code, period_start) values (auth.uid(), d.code, public.period_start(d.period));
  exception when unique_violation then raise exception 'Récompense déjà récupérée'; end;
  return public.tok_add(auth.uid(), d.reward, 'quête : ' || d.title);
end $$;

-- ---------- boutique ----------
create or replace function public.shop_list()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'kind', s.kind, 'name', s.name, 'descr', s.descr, 'price', s.price,
       'owned', exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code)) order by s.sort) from public.shop_items s), '[]'::jsonb),
    'equipped', coalesce((select to_jsonb(e) - 'user_id' from public.equipped e where e.user_id = auth.uid()), '{}'::jsonb),
    'emojis', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'pack', pack, 'label', label) order by code) from public.premium_emoji), '[]'::jsonb))
$$;
create or replace function public.shop_buy(p_code text)
returns int language plpgsql security definer set search_path = public as $$
declare it public.shop_items; b int;
begin
  select * into it from public.shop_items where code = p_code;
  if not found then raise exception 'Article introuvable'; end if;
  if it.price is null then raise exception 'Cet article ne s’achète pas'; end if;
  if exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code) then raise exception 'Déjà possédé'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select balance into b from public.wallets where user_id = auth.uid() for update;
  if b < it.price then raise exception 'Jetons insuffisants'; end if;
  insert into public.inventory(user_id, code) values (auth.uid(), p_code);
  return public.tok_add(auth.uid(), -it.price, 'achat : ' || it.name);
end $$;
create or replace function public.shop_equip(p_slot text, p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_slot not in ('frame','badge') then raise exception 'Emplacement inconnu'; end if;
  if p_code is not null then
    if not exists(select 1 from public.inventory i join public.shop_items s on s.code = i.code where i.user_id = auth.uid() and i.code = p_code and s.kind = p_slot) then raise exception 'Article non possédé'; end if;
  end if;
  insert into public.equipped(user_id) values (auth.uid()) on conflict do nothing;
  if p_slot = 'frame' then update public.equipped set frame = p_code where user_id = auth.uid(); else update public.equipped set badge = p_code where user_id = auth.uid(); end if;
end $$;
create or replace function public.has_item(p_code text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code)
$$;
create or replace function public.cosmetics_of(p_users text[])
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_object_agg(p.username, jsonb_build_object('frame', e.frame, 'badge', e.badge)), '{}'::jsonb)
  from public.equipped e join public.profiles p on p.id = e.user_id where p.username = any(p_users) and (e.frame is not null or e.badge is not null)
$$;
create or replace function public.pe_owned() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(e.code), '[]'::jsonb) from public.premium_emoji e join public.inventory i on i.code = e.pack and i.user_id = auth.uid()
$$;

-- ---------- administration : jetons et badges (administrateur et plus) ----------
create or replace function public.admin_tokens(p_username text, p_amount int, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 then raise exception 'Montant invalide'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Raison obligatoire (demande d’indemnisation ou erreur)'; end if;
  v := public.staff_id_of(p_username);
  if p_amount < 0 and coalesce((select balance from public.wallets where user_id = v), 0) + p_amount < 0 then raise exception 'Solde insuffisant pour ce retrait'; end if;
  perform public.log_admin('jetons', p_username, jsonb_build_object('montant', p_amount, 'raison', p_reason));
  return public.tok_add(v, p_amount, 'administration : ' || left(p_reason, 150), auth.uid());
end $$;
create or replace function public.admin_item(p_username text, p_code text, p_give boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if not exists(select 1 from public.shop_items where code = p_code) then raise exception 'Article introuvable'; end if;
  v := public.staff_id_of(p_username);
  if p_give then insert into public.inventory(user_id, code, source) values (v, p_code, 'administration') on conflict do nothing;
  else delete from public.inventory where user_id = v and code = p_code;
    update public.equipped set frame = case when frame = p_code then null else frame end, badge = case when badge = p_code then null else badge end where user_id = v; end if;
  perform public.log_admin(case when p_give then 'article_donne' else 'article_retire' end, p_username, jsonb_build_object('article', p_code));
end $$;
create or replace function public.admin_wallet(p_username text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  v := public.staff_id_of(p_username);
  return jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = v), 0),
    'items', coalesce((select jsonb_agg(code) from public.inventory where user_id = v), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('delta', delta, 'reason', reason, 'at', at) order by id desc) from (select * from public.token_log where user_id = v order by id desc limit 20) l), '[]'::jsonb));
end $$;

-- ---------- emojis premium : l'envoi exige le pack (messages en clair) ----------
create or replace function public.pe_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if new.kind = 'text' and new.body is not null and new.body like '%:pe\_%' then
    for t in select (regexp_matches(new.body, ':(pe_[a-z0-9]+):', 'g'))[1] loop
      if exists(select 1 from public.premium_emoji where code = t) and not exists(
        select 1 from public.premium_emoji e join public.inventory i on i.code = e.pack and i.user_id = new.sender_id where e.code = t) then
        raise exception 'Emoji premium non possédé (%)', t;
      end if;
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists messages_pe_guard on public.messages;
create trigger messages_pe_guard before insert on public.messages for each row execute function public.pe_guard();

grant execute on function public.wallet_me(), public.referral_code_me(), public.referral_use(text), public.quests_list(), public.quest_event(text), public.quest_claim(text),
  public.shop_list(), public.shop_buy(text), public.shop_equip(text, text), public.has_item(text), public.cosmetics_of(text[]), public.pe_owned(),
  public.admin_tokens(text, int, text), public.admin_item(text, text, boolean), public.admin_wallet(text), public.referral_check() to authenticated;
