-- ============================================================================
-- Communicer! — Patch « équipes e-Sport, cadres payants, surnoms de groupe, retrait des administrateurs » (additif, relançable)
-- À exécuter après patch_tournois.sql.
-- ============================================================================

-- ---------- e-Sport : création directe (chat automatique), administrateurs sans achat, supervision ----------
create or replace function public.esport_create(p_name text, p_title text, p_rules text) returns text language plpgsql security definer set search_path = public as $$
declare cv uuid; n text := btrim(coalesce(p_name,''));
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public._need_right(auth.uid(), 'esport');
  if not (public._owns('esport') or public.staff_rank_me() >= 2) then raise exception 'Achetez d’abord « Équipe e-Sport » dans la boutique'; end if;
  perform public.rate_ok('esc', 6, 3600);
  if char_length(n) not between 2 and 30 then raise exception 'Nom d’équipe de 2 à 30 caractères'; end if;
  if exists(select 1 from public.esport_teams where lower(name) = lower(n)) then raise exception 'Ce nom d’équipe est déjà pris'; end if;
  insert into public.conversations(kind, mode, name, created_by) values ('group', 'clear', left('e-Sport · ' || n, 60), auth.uid()) returning conversations.id into cv;
  insert into public.conversation_members(conversation_id, user_id, role) values (cv, auth.uid(), 'admin');
  insert into public.esport_teams(conv, name, title, rules, owner) values (cv, n, nullif(btrim(coalesce(p_title,'')), ''), nullif(btrim(coalesce(p_rules,'')), ''), auth.uid());
  return n;
end $$;

create or replace function public.esport_set(p_conv uuid, p_name text, p_title text, p_rules text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_cadmin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if not exists(select 1 from public.conversations where id = p_conv and kind = 'group') then raise exception 'Seuls les groupes peuvent former une équipe'; end if;
  perform public._need_right(auth.uid(), 'esport', p_conv);
  if exists(select 1 from public.esport_teams where conv = p_conv) then
    if not exists(select 1 from public.esport_teams where conv = p_conv and owner = auth.uid()) then raise exception 'Seul le fondateur de l’équipe peut la modifier'; end if;
  elsif not (public._owns('esport') or public.staff_rank_me() >= 2) then raise exception 'Achetez d’abord « Équipe e-Sport » dans la boutique'; end if;
  begin
    insert into public.esport_teams(conv, name, title, rules, owner) values (p_conv, btrim(p_name), nullif(btrim(coalesce(p_title,'')),''), nullif(btrim(coalesce(p_rules,'')),''), auth.uid())
    on conflict (conv) do update set name = excluded.name, title = excluded.title, rules = excluded.rules;
  exception when unique_violation then raise exception 'Ce nom d’équipe est déjà pris'; end;
end $$;

create or replace function public.esport_list_all() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'title', t.title, 'owner', public._ev_name(t.owner), 'members', (select count(*) from public.conversation_members m where m.conversation_id = t.conv),
      'supervised', exists(select 1 from public.conversation_members m where m.conversation_id = t.conv and m.user_id = auth.uid())) order by t.created_at desc) from public.esport_teams t), '[]'::jsonb);
end $$;
create or replace function public.esport_supervise(p_team text, p_on boolean default true) returns void language plpgsql security definer set search_path = public as $$
declare t public.esport_teams;
begin
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select * into t from public.esport_teams where lower(name) = lower(btrim(p_team));
  if not found then raise exception 'Équipe introuvable'; end if;
  if p_on then
    insert into public.conversation_members(conversation_id, user_id, role) values (t.conv, auth.uid(), 'member') on conflict do nothing;
  else
    if t.owner = auth.uid() then raise exception 'Vous êtes le fondateur de cette équipe'; end if;
    delete from public.conversation_members where conversation_id = t.conv and user_id = auth.uid();
  end if;
  perform public.log_admin(case when p_on then 'esport_supervise' else 'esport_quitte' end, t.name, '{}'::jsonb);
end $$;
revoke all on function public.esport_create(text,text,text), public.esport_list_all(), public.esport_supervise(text,boolean) from public, anon;
grant execute on function public.esport_create(text,text,text), public.esport_list_all(), public.esport_supervise(text,boolean) to authenticated;

-- ---------- cadres importés : prix en jetons, versés au commandant qui les a importés ----------
alter table public.frame_defs add column if not exists price numeric(14,1) check (price is null or (price >= 1 and price <= 1000000));
alter table public.frame_defs add column if not exists seller uuid references public.profiles(id) on delete set null;
update public.frame_defs set seller = (select user_id from public.site_staff where role = 'commander' order by rank_at limit 1) where custom and seller is null;

create or replace function public.frame_import(p_cat text, p_name text, p_img text) returns text language plpgsql security definer set search_path = public as $$
declare c text; n text := btrim(coalesce(p_name,''));
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_cat not in ('photo','photo_anim','profile','profile_anim') then raise exception 'Catégorie inconnue'; end if;
  if char_length(n) not between 1 and 40 then raise exception 'Nom de 1 à 40 caractères requis'; end if;
  if p_img is null or p_img !~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$' then raise exception 'Adresse d’image invalide'; end if;
  c := 'im_n' || nextval('public.frame_img_seq');
  insert into public.frame_defs(code, cat, name, sort, img, custom, seller)
    values (c, p_cat, n, 100 + (select count(*) from public.frame_defs where custom), p_img, true, auth.uid());
  perform public.log_admin('cadre_import', c, jsonb_build_object('cat', p_cat, 'nom', n));
  return c;
end $$;

create or replace function public.frame_price_set(p_code text, p_price numeric) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if not exists(select 1 from public.frame_defs where code = p_code and custom) then raise exception 'Seuls les cadres importés ont un prix'; end if;
  if p_price is not null and (p_price < 1 or p_price > 1000000) then raise exception 'Prix entre 1 et 1 000 000 jetons'; end if;
  update public.frame_defs set price = p_price, seller = coalesce(seller, auth.uid()) where code = p_code;
  perform public.log_admin('cadre_prix', p_code, jsonb_build_object('prix', p_price));
end $$;

-- un cadre acheté (ou décerné) est utilisable quel que soit son mode de diffusion
create or replace function public._frame_ok(p_user uuid, p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.frame_defs f where f.code = p_code and (
      f.audience = 'all'
      or exists(select 1 from public.frame_grants g where g.frame_code = f.code and g.user_id = p_user)
      or exists(select 1 from public.inventory i where i.user_id = p_user and i.code = 'frame_' || f.cat)))
$$;
revoke all on function public._frame_ok(uuid, text) from public, anon, authenticated;
create or replace function public.frames_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(f.code), '[]'::jsonb) from public.frame_defs f
  where auth.uid() is not null and (f.audience = 'all' or exists(select 1 from public.frame_grants g where g.frame_code = f.code and g.user_id = auth.uid()))
$$;
create or replace function public.frames_img() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'img', img, 'name', name, 'custom', custom, 'audience', audience, 'price', price) order by cat, sort), '[]'::jsonb)
  from public.frame_defs where img is not null
$$;
create or replace function public.frame_buy(p_code text) returns numeric language plpgsql security definer set search_path = public as $$
declare f public.frame_defs; b numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public._need_right(auth.uid(), 'shop_buy');
  perform public.rate_ok('fbuy', 30, 3600);
  select * into f from public.frame_defs where code = p_code;
  if not found or f.price is null then raise exception 'Ce cadre n’est pas en vente'; end if;
  if public._frame_ok(auth.uid(), p_code) then raise exception 'Déjà possédé'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  perform 1 from public.wallets where user_id = auth.uid() for update;
  if (select balance from public.wallets where user_id = auth.uid()) < f.price then raise exception 'Jetons insuffisants'; end if;
  b := public.tok_add(auth.uid(), -f.price, 'achat du cadre « ' || f.name || ' »', null);
  if f.seller is not null and f.seller <> auth.uid() then perform public.tok_add(f.seller, f.price, 'vente du cadre « ' || f.name || ' » à @' || public._ev_name(auth.uid()), null); end if;
  insert into public.frame_grants(frame_code, user_id) values (p_code, auth.uid()) on conflict do nothing;
  return b;
end $$;
revoke all on function public.frame_price_set(text,numeric), public.frame_buy(text) from public, anon;
grant execute on function public.frame_price_set(text,numeric), public.frame_buy(text) to authenticated;

-- ---------- surnoms dans les groupes (droit « nickname », retirable) ----------
create or replace function public.right_keys() returns text[] language sql immutable as $$
  select array['play','call','edit_conv','upload_files','become_admin','bot_cmds','create_bot','create_groups','friend_requests','edit_profile','quests','shop_buy','referral','rmn_import','buy_tokens','send_messages','start_game','import_game','customize_group','add_members','transfer','promo_codes','mention','export','tournaments','esport','anon_suggest','vote','nickname']
$$;
create table if not exists public.conv_nicks (conversation_id uuid not null references public.conversations(id) on delete cascade, user_id uuid not null references public.profiles(id) on delete cascade,
  nick text not null check (char_length(nick) between 1 and 30), set_by uuid references public.profiles(id) on delete set null, at timestamptz not null default now(), primary key (conversation_id, user_id));
alter table public.conv_nicks enable row level security; revoke all on public.conv_nicks from anon, authenticated;
create or replace function public.nick_set(p_conv uuid, p_username text, p_nick text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid; n text := btrim(coalesce(p_nick,''));
begin
  if auth.uid() is null or not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if not exists(select 1 from public.conversations where id = p_conv and kind = 'group') then raise exception 'Réservé aux groupes'; end if;
  perform public._need_right(auth.uid(), 'nickname', p_conv);
  perform public.rate_ok('nick', 60, 3600);
  select id into u from public.profiles where username = lower(regexp_replace(btrim(coalesce(p_username,'')), '^@', ''));
  if u is null or not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = u) then raise exception 'Cette personne n’est pas dans le groupe'; end if;
  if n = '' then delete from public.conv_nicks where conversation_id = p_conv and user_id = u; return; end if;
  if char_length(n) > 30 or n ~ '[@<>]' then raise exception 'Surnom de 30 caractères au maximum, sans @ < >'; end if;
  insert into public.conv_nicks(conversation_id, user_id, nick, set_by) values (p_conv, u, n, auth.uid())
    on conflict (conversation_id, user_id) do update set nick = excluded.nick, set_by = excluded.set_by, at = now();
end $$;
create or replace function public.nicks_of(p_conv uuid) returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_object_agg(p.username, n.nick), '{}'::jsonb) from public.conv_nicks n join public.profiles p on p.id = n.user_id where n.conversation_id = p_conv and public.is_member(p_conv) $$;
revoke all on function public.nick_set(uuid,text,text), public.nicks_of(uuid) from public, anon;
grant execute on function public.nick_set(uuid,text,text), public.nicks_of(uuid) to authenticated;

-- ---------- retrait d'un administrateur : il quitte aussitôt le groupe Administration ----------
create or replace function public.trg_staff_leave() returns trigger language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select conversation_id into g from public.staff_group where id = 1;
  if g is not null then delete from public.conversation_members where conversation_id = g and user_id = old.user_id; end if;
  return old;
end $$;
drop trigger if exists staff_leave on public.site_staff;
create trigger staff_leave after delete on public.site_staff for each row execute function public.trg_staff_leave();
-- rattrapage : personnes déjà retirées mais restées dans le groupe
delete from public.conversation_members m using public.staff_group g
 where g.id = 1 and m.conversation_id = g.conversation_id and m.user_id not in (select user_id from public.site_staff);

notify pgrst, 'reload schema';
