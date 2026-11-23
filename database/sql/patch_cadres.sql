-- Lot 12 : cadres en image (additif). Les images intégrées sont dans le dossier frames/ du site.
alter table public.frame_defs add column if not exists img text;
alter table public.frame_defs add column if not exists custom boolean not null default false;
create sequence if not exists public.frame_img_seq;

insert into public.frame_defs(code, cat, name, sort, img) values
 ('im_p1','photo','Couronne dorée',11,'frames/photo1.png'),
 ('im_p2','photo','Perles',12,'frames/photo2.png'),
 ('im_p3','photo','Rose des vents',13,'frames/photo3.png'),
 ('im_pa1','photo_anim','Comète',11,'frames/photoa1.png'),
 ('im_pa2','photo_anim','Halo cyan',12,'frames/photoa2.png'),
 ('im_pa3','photo_anim','Cercle spectral',13,'frames/photoa3.png'),
 ('im_r1','profile','Cadre royal',11,'frames/prof1.png'),
 ('im_r2','profile','Double azur',12,'frames/prof2.png'),
 ('im_r3','profile','Feuillage',13,'frames/prof3.png'),
 ('im_ra1','profile_anim','Lumière filante',11,'frames/profa1.png'),
 ('im_ra2','profile_anim','Halo rose',12,'frames/profa2.png'),
 ('im_ra3','profile_anim','Spectre',13,'frames/profa3.png')
on conflict (code) do update set cat = excluded.cat, name = excluded.name, sort = excluded.sort, img = excluded.img;

create or replace function public.frames_img() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'cat', cat, 'img', img, 'name', name, 'custom', custom) order by cat, sort), '[]'::jsonb)
  from public.frame_defs where img is not null
$$;

create or replace function public.frame_import(p_cat text, p_name text, p_img text) returns text language plpgsql security definer set search_path = public as $$
declare c text; n text := btrim(coalesce(p_name,''));
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_cat not in ('photo','photo_anim','profile','profile_anim') then raise exception 'Catégorie inconnue'; end if;
  if char_length(n) not between 1 and 40 then raise exception 'Nom de 1 à 40 caractères requis'; end if;
  if p_img is null or p_img !~ '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]{4,250}$' then raise exception 'Adresse d’image invalide'; end if;
  c := 'im_n' || nextval('public.frame_img_seq');
  insert into public.frame_defs(code, cat, name, sort, img, custom)
    values (c, p_cat, n, 100 + (select count(*) from public.frame_defs where custom), p_img, true);
  perform public.log_admin('cadre_import', c, jsonb_build_object('cat', p_cat, 'nom', n));
  return c;
end $$;

create or replace function public.frame_remove(p_code text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if not exists(select 1 from public.frame_defs where code = p_code and custom) then raise exception 'Seuls les cadres importés peuvent être retirés'; end if;
  update public.profile_ext set photo_frame = null where photo_frame = p_code;
  update public.profile_ext set profile_frame = null where profile_frame = p_code;
  delete from public.frame_defs where code = p_code;
  perform public.log_admin('cadre_retire', p_code, '{}'::jsonb);
end $$;

revoke all on function public.frames_img(), public.frame_import(text,text,text), public.frame_remove(text) from public, anon;
grant execute on function public.frames_img(), public.frame_import(text,text,text), public.frame_remove(text) to authenticated;
