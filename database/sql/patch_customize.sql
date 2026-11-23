-- ============================================================================
-- Communicer! — Patch « Customize+ » (additif, relançable)
-- À exécuter après patch_jetons_v2.sql, patch_comptes2.sql et patch_correctifs.sql.
-- ============================================================================
alter table public.inventory add column if not exists via text;
alter table public.profile_ext add column if not exists site_color text check (site_color is null or site_color ~ '^#[0-9a-fA-F]{6}$');
alter table public.profile_ext add column if not exists bg_music text check (bg_music is null or bg_music ~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$');
alter table public.profile_ext add column if not exists music_vol numeric not null default 0.5 check (music_vol between 0 and 1);
alter table public.profile_ext add column if not exists music_btn text check (music_btn is null or music_btn ~ '^#[0-9a-fA-F]{6}$');
alter table public.profile_ext add column if not exists backdrop text check (backdrop is null or backdrop ~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$');
alter table public.profile_ext add column if not exists layout text[] not null default '{}';
alter table public.profile_ext add column if not exists extra jsonb not null default '{}'::jsonb;
alter table public.profile_ext add column if not exists last_rename timestamptz;

insert into public.shop_items(code, kind, name, descr, price, sort) values
 ('customize_plus', 'feature', 'Customize+', 'Couleur du site, profil réorganisable, musique de profil, informations privées, décor personnalisé, liens personnalisés, et inclut couleurs, cadres, 5e badge et renommage mensuel gratuit', 4512, 5)
on conflict (code) do update set name = excluded.name, descr = excluded.descr, price = excluded.price;

-- Customize+ inclut ces articles (accordés avec via = 'customize_plus' ; un achat antérieur reste « possédé »)
create or replace function public._cplus_codes() returns text[] language sql immutable as $$
  select array['name_color','profile_color','profile_bg','badge_slot5','frame_photo','frame_photo_anim','frame_profile','frame_profile_anim'] $$;
create or replace function public.trg_cplus_grant() returns trigger language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if new.code <> 'customize_plus' then return new; end if;
  foreach c in array public._cplus_codes() loop
    insert into public.inventory(user_id, code, via) select new.user_id, c, 'customize_plus' where exists(select 1 from public.shop_items where code = c)
      on conflict do nothing;
  end loop;
  return new;
end $$;
drop trigger if exists cplus_grant on public.inventory;
create trigger cplus_grant after insert on public.inventory for each row execute function public.trg_cplus_grant();
-- rattrapage : acheteurs existants
insert into public.inventory(user_id, code, via)
  select i.user_id, c, 'customize_plus' from public.inventory i cross join unnest(public._cplus_codes()) c where i.code = 'customize_plus' and exists(select 1 from public.shop_items s where s.code = c)
  on conflict do nothing;

create or replace function public.has_cplus() returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = auth.uid() and code = 'customize_plus') $$;

create or replace function public.shop_list()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('balance', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'descr', s.descr, 'price', s.price, 'kind', s.kind,
       'owned', s.kind <> 'credit' and exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code),
       'via', exists(select 1 from public.inventory i where i.user_id = auth.uid() and i.code = s.code and i.via is not null)) order by s.sort) from public.shop_items s), '[]'::jsonb),
    'badges', coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'name', d.name, 'descr', d.descr, 'tier', d.tier, 'price', d.price,
       'owned', exists(select 1 from public.user_badges b where b.user_id = auth.uid() and b.code = d.code)) order by d.sort) from public.badge_defs d where d.price is not null), '[]'::jsonb),
    'frames', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'name', name) order by cat, sort) from public.frame_defs), '[]'::jsonb),
    'pack', jsonb_build_object('cad', public.cfg_n('pack_price_cad'), 'tokens', public.cfg_n('pack_tokens')))
$$;

-- ---------- renommage mensuel gratuit ----------
create or replace function public.rename_me(p_new text)
returns text language plpgsql security definer set search_path = public as $$
declare n text := lower(trim(coalesce(p_new,''))); old text; free boolean := false; e public.profile_ext;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if n !~ '^[a-z0-9_]{3,20}$' then raise exception 'Nom invalide (3 à 20 caractères : lettres, chiffres, _)'; end if;
  if n = (select username from public.profiles where id = auth.uid()) then raise exception 'C’est déjà votre nom'; end if;
  case public.name_available(n) when 'taken' then raise exception 'Ce nom est déjà pris ou réservé'; when 'forbidden' then raise exception 'Ce nom d’utilisateur n’est pas autorisé'; when 'ok' then null; else raise exception 'Nom invalide'; end case;
  insert into public.profile_ext(user_id) values (auth.uid()) on conflict do nothing;
  select * into e from public.profile_ext where user_id = auth.uid() for update;
  if public.has_cplus() and (e.last_rename is null or e.last_rename < now() - interval '30 days') then free := true; end if;
  if not free then
    update public.profile_ext set rename_credits = rename_credits - 1 where user_id = auth.uid() and rename_credits > 0;
    if not found then raise exception 'Achetez d’abord un changement de nom (ou attendez 30 jours avec Customize+)'; end if;
  end if;
  update public.profile_ext set last_rename = now() where user_id = auth.uid();
  select username into old from public.profiles where id = auth.uid();
  update public.profiles set username = n where id = auth.uid();
  insert into public.token_log(user_id, delta, reason) values (auth.uid(), 0, 'nom changé : ' || old || ' vers ' || n);
  return n;
end $$;

-- ---------- réglages Customize+ ----------
create or replace function public.custom_set(p_field text, p_value text) returns void language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_value,'')), ''); arr text[]; k text; j jsonb; allowed text[] := array['bio','age','anniv','ville','travail','etudes','jeu','citation','site','pronoms'];
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.has_cplus() then raise exception 'Réservé à Customize+'; end if;
  perform public.rate_ok('cplus', 120, 3600);
  insert into public.profile_ext(user_id) values (auth.uid()) on conflict do nothing;
  if p_field = 'site_color' then
    if v is not null and v !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
    update public.profile_ext set site_color = v where user_id = auth.uid();
  elsif p_field = 'music_btn' then
    if v is not null and v !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Couleur invalide'; end if;
    update public.profile_ext set music_btn = v where user_id = auth.uid();
  elsif p_field = 'bg_music' then
    if v is not null and v !~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$' then raise exception 'Lien https invalide'; end if;
    update public.profile_ext set bg_music = v where user_id = auth.uid();
  elsif p_field = 'backdrop' then
    if v is not null and v !~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$' then raise exception 'Lien https invalide'; end if;
    update public.profile_ext set backdrop = v where user_id = auth.uid();
  elsif p_field = 'music_vol' then
    if v is null or v !~ '^(0|1|0?\.[0-9]{1,2})$' then raise exception 'Volume invalide'; end if;
    update public.profile_ext set music_vol = v::numeric where user_id = auth.uid();
  elsif p_field = 'layout' then
    arr := coalesce(string_to_array(coalesce(v,''), ','), '{}');
    if exists(select 1 from unnest(arr) x where x not in ('bio','info','extra','stats','badges')) or cardinality(arr) <> (select count(distinct x) from unnest(arr) x) then raise exception 'Ordre invalide'; end if;
    update public.profile_ext set layout = arr where user_id = auth.uid();
  elsif p_field like 'x:%' then
    -- x:<champ>  valeur = texte ; x:<champ>:show = 1/0
    k := split_part(p_field, ':', 2);
    if not (k = any(allowed)) then raise exception 'Champ inconnu'; end if;
    if split_part(p_field, ':', 3) = 'show' then
      update public.profile_ext set extra = jsonb_set(extra, array[k], coalesce(extra -> k, '{}'::jsonb) || jsonb_build_object('show', v = '1')) where user_id = auth.uid();
    else
      if v is not null and char_length(v) > 120 then raise exception '120 caractères au maximum'; end if;
      if v is null then update public.profile_ext set extra = extra - k where user_id = auth.uid();
      else update public.profile_ext set extra = jsonb_set(extra, array[k], coalesce(extra -> k, '{"show":false}'::jsonb) || jsonb_build_object('v', v)) where user_id = auth.uid(); end if;
    end if;
  else raise exception 'Réglage inconnu'; end if;
end $$;

create or replace function public.custom_me() returns jsonb language sql security definer stable set search_path = public as $$
  select case when public.has_cplus() then (select jsonb_build_object('on', true, 'site_color', e.site_color, 'bg_music', e.bg_music, 'music_vol', e.music_vol, 'music_btn', e.music_btn, 'backdrop', e.backdrop,
      'layout', to_jsonb(e.layout), 'extra', e.extra, 'last_rename', e.last_rename) from public.profile_ext e where e.user_id = auth.uid())
    else jsonb_build_object('on', false) end
$$;
-- couleur du site de la personne connectée (uniquement elle-même : aucun effet sur les profils)
create or replace function public.site_color_me() returns text language sql security definer stable set search_path = public as $$
  select case when public.has_cplus() then (select site_color from public.profile_ext where user_id = auth.uid()) end $$;

create or replace function public.profile_full(p_username text)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare u uuid; e public.profile_ext; shown jsonb := '[]'::jsonb; c text; ex jsonb := '{}'::jsonb; k text; cp boolean;
begin
  select id into u from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if u is null then return '{}'::jsonb; end if;
  select * into e from public.profile_ext where user_id = u;
  if exists(select 1 from public.user_badges where user_id = u and code = 'moderateur') then shown := shown || jsonb_build_array(public.badge_json(u, 'moderateur')); end if;
  foreach c in array coalesce(e.badges, '{}') loop
    if c <> 'moderateur' and exists(select 1 from public.user_badges where user_id = u and code = c) then shown := shown || jsonb_build_array(public.badge_json(u, c)); end if;
  end loop;
  cp := exists(select 1 from public.inventory where user_id = u and code = 'customize_plus');
  if cp then for k in select jsonb_object_keys(coalesce(e.extra, '{}'::jsonb)) loop
      if coalesce((e.extra -> k ->> 'show')::boolean, false) then ex := ex || jsonb_build_object(k, e.extra -> k ->> 'v'); end if;
  end loop; end if;
  return jsonb_build_object('nc', e.name_color, 'pc', e.profile_color, 'ptc', e.profile_text_color, 'bg', e.profile_bg, 'pf', e.photo_frame, 'rf', e.profile_frame, 'badges', shown,
    'cp', cp, 'music', case when cp then e.bg_music end, 'vol', e.music_vol, 'mbtn', case when cp then e.music_btn end, 'backdrop', case when cp then e.backdrop end,
    'layout', case when cp then to_jsonb(e.layout) else '[]'::jsonb end, 'extra', ex);
end $$;

-- ---------- liens personnalisés ----------
create table if not exists public.custom_links (
  slug text primary key check (slug ~ '^[a-z0-9_]{3,24}$'),
  kind text not null check (kind in ('profile','group')),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete cascade,
  created_at timestamptz not null default now(),
  check ((kind = 'group') = (conversation_id is not null))
);
create unique index if not exists custom_links_one_profile on public.custom_links(owner_id) where kind = 'profile';
create unique index if not exists custom_links_one_conv on public.custom_links(conversation_id) where kind = 'group';
alter table public.custom_links enable row level security;

-- un lien ne peut pas être égal à un nom d'utilisateur existant : supprimé si le nom apparaît (création/renommage)
create or replace function public.trg_cl_username() returns trigger language plpgsql security definer set search_path = public as $$
begin delete from public.custom_links where slug = lower(new.username); return new; end $$;
drop trigger if exists cl_username on public.profiles;
create trigger cl_username after insert or update of username on public.profiles for each row execute function public.trg_cl_username();
delete from public.custom_links where slug in (select username from public.profiles);

create or replace function public.link_custom_set(p_kind text, p_slug text, p_conv uuid default null) returns void language plpgsql security definer set search_path = public as $$
declare s text := lower(trim(coalesce(p_slug,''))); c public.conversations;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public.has_cplus() then raise exception 'Réservé à Customize+'; end if;
  perform public.rate_ok('clink', 30, 3600);
  if s !~ '^[a-z0-9_]{3,24}$' then raise exception 'Lien invalide (3 à 24 caractères : lettres minuscules, chiffres, _)'; end if;
  if exists(select 1 from public.profiles where username = s) or exists(select 1 from public.username_history where lower(name) = s) then raise exception 'Ce lien est déjà un nom d’utilisateur'; end if;
  if exists(select 1 from public.invite_links where code = p_slug) then raise exception 'Lien indisponible'; end if;
  if p_kind = 'profile' then
    delete from public.custom_links where owner_id = auth.uid() and kind = 'profile';
    insert into public.custom_links(slug, kind, owner_id) values (s, 'profile', auth.uid());
  elsif p_kind = 'group' then
    select * into c from public.conversations where id = p_conv;
    if not found or c.kind <> 'group' then raise exception 'Groupe introuvable'; end if;
    if not (c.created_by = auth.uid() or (public.is_member(p_conv) and public.conv_is_admin(p_conv))) then raise exception 'Réservé au créateur et aux administrateurs du groupe'; end if;
    if c.mode <> 'clear' then raise exception 'Un groupe chiffré ne peut pas avoir de lien'; end if;
    if (select count(*) from public.custom_links where owner_id = auth.uid() and kind = 'group' and conversation_id <> p_conv) >= 5 then raise exception '5 liens de groupe au maximum'; end if;
    delete from public.custom_links where conversation_id = p_conv;
    insert into public.custom_links(slug, kind, owner_id, conversation_id) values (s, 'group', auth.uid(), p_conv);
    if not exists(select 1 from public.invite_links where conversation_id = p_conv and revoked_at is null) and public.is_member(p_conv) then perform public.link_group_create(p_conv); end if;
  else raise exception 'Type inconnu'; end if;
exception when unique_violation then raise exception 'Ce lien est déjà pris';
end $$;
create or replace function public.link_custom_delete(p_kind text, p_conv uuid default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_kind = 'profile' then delete from public.custom_links where owner_id = auth.uid() and kind = 'profile';
  else delete from public.custom_links where conversation_id = p_conv and (owner_id = auth.uid() or (public.is_member(p_conv) and public.conv_is_admin(p_conv))); end if;
end $$;
create or replace function public.link_custom_mine() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', l.slug, 'kind', l.kind, 'conv', l.conversation_id, 'name', c.name) order by l.created_at), '[]'::jsonb)
  from public.custom_links l left join public.conversations c on c.id = l.conversation_id where l.owner_id = auth.uid() $$;
-- résolution : profil -> nom d'utilisateur ; groupe -> code d'invitation actif
create or replace function public.link_custom_resolve(p_kind text, p_slug text) returns text language plpgsql security definer stable set search_path = public as $$
declare s text := lower(trim(coalesce(p_slug,''))); r text;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_kind = 'profile' then
    select p.username into r from public.custom_links l join public.profiles p on p.id = l.owner_id where l.slug = s and l.kind = 'profile';
    if r is null or not exists(select 1 from public.inventory i join public.profiles p on p.id = i.user_id where p.username = r and i.code = 'customize_plus') then raise exception 'Lien introuvable'; end if;
  else
    select i.code into r from public.custom_links l join public.invite_links i on i.conversation_id = l.conversation_id and i.revoked_at is null where l.slug = s and l.kind = 'group';
    if r is null then raise exception 'Lien invalide ou expiré'; end if;
  end if;
  return r;
end $$;
revoke all on function public.custom_set(text,text), public.custom_me(), public.site_color_me(), public.link_custom_set(text,text,uuid), public.link_custom_delete(text,uuid), public.link_custom_mine(), public.link_custom_resolve(text,text), public.has_cplus() from public, anon;
grant execute on function public.custom_set(text,text), public.custom_me(), public.site_color_me(), public.link_custom_set(text,text,uuid), public.link_custom_delete(text,uuid), public.link_custom_mine(), public.link_custom_resolve(text,text), public.has_cplus() to authenticated;
