-- Lot 14 : actions de groupe gratuites (additif). Dépend de patch_outils.sql.
insert into public.gi_kinds(kind, paid, admin_only, votable) values
 ('link', false, false, false), ('suggest', false, false, false), ('debate', false, false, true), ('challenge', false, false, true),
 ('story', false, false, false), ('vote', false, true, true), ('vault', false, false, false), ('waitroom', false, true, false)
on conflict (kind) do update set paid = excluded.paid, admin_only = excluded.admin_only, votable = excluded.votable;

create or replace function public.gi_list(p_conv uuid, p_kind text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare r jsonb; adm boolean;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not exists(select 1 from public.gi_kinds where kind = p_kind) then raise exception 'Type inconnu'; end if;
  if p_conv is not null then
    if not public._is_member(p_conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
  elsif p_kind not in ('poll','quiz') then raise exception 'Type inconnu'; end if;
  adm := p_conv is not null and public._is_cadmin(p_conv);
  -- boîte à suggestions : lisible par les administrateurs seulement, sans auteur
  if p_kind = 'suggest' and not adm then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into r from (
    select jsonb_build_object('id', i.id, 'title', i.title, 'data', i.data, 'closed', i.closed, 'due', i.due, 'created_at', i.created_at,
      'by', case when p_kind = 'suggest' then null else (select username from public.profiles where id = i.created_by) end,
      'mine', p_kind <> 'suggest' and i.created_by = auth.uid(),
      'votes', coalesce((select jsonb_object_agg(c::text, n) from (select choice c, count(*) n from public.group_votes v where v.item = i.id group by choice) q), '{}'::jsonb),
      'my', (select choice from public.group_votes v where v.item = i.id and v.user_id = auth.uid())) x
    from public.group_items i where i.conv is not distinct from p_conv and i.kind = p_kind order by i.created_at desc limit 100) s;
  return r;
end $$;

create or replace function public.gi_add(p_conv uuid, p_kind text, p_title text, p_data jsonb default '{}'::jsonb, p_due timestamptz default null) returns bigint language plpgsql security definer set search_path = public as $$
declare k public.gi_kinds; n bigint; u uuid; t text := btrim(coalesce(p_title,'')); d jsonb := coalesce(p_data, '{}'::jsonb);
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select * into k from public.gi_kinds where kind = p_kind;
  if not found then raise exception 'Type inconnu'; end if;
  if char_length(t) not between 1 and 200 then raise exception 'Titre de 1 à 200 caractères requis'; end if;
  perform public.rate_ok('gi_add', 60, 3600);
  if p_conv is null then
    if public.staff_rank_me() < 4 or p_kind not in ('poll','quiz') then raise exception 'Réservé au commandant'; end if;
  else
    if not public._is_member(p_conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
    if k.paid and not exists(select 1 from public.group_tools where conv = p_conv) then raise exception 'Outils de groupe non activés pour ce groupe'; end if;
    if k.admin_only and not public._is_cadmin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  end if;
  if p_kind in ('poll','quiz','vote') and (jsonb_typeof(d->'options') is distinct from 'array' or jsonb_array_length(d->'options') not between 2 and 10) then raise exception 'Il faut de 2 à 10 choix'; end if;
  if p_kind = 'quiz' and (d->>'answer') !~ '^[0-9]$' then raise exception 'Réponse du quiz manquante'; end if;
  if p_kind in ('timer','event') and p_due is null then raise exception 'Date requise'; end if;
  if p_kind = 'link' and coalesce(d->>'url','') !~ '^https?://[^[:space:]]{4,250}$' then raise exception 'Lien invalide (http ou https)'; end if;
  if p_kind = 'debate' then d := jsonb_build_object('options', jsonb_build_array('Pour','Contre'), 'args', '[]'::jsonb); end if;
  if p_kind = 'challenge' then d := jsonb_build_object('options', jsonb_build_array('Je participe','Défi accompli'), 'desc', left(coalesce(d->>'desc',''), 500)); end if;
  if p_kind = 'story' then d := jsonb_build_object('parts', '[]'::jsonb); end if;
  if p_kind = 'vault' then d := jsonb_build_object('note', left(coalesce(d->>'note',''), 500), 'url', nullif(left(coalesce(d->>'url',''), 480), '')); end if;
  if p_kind = 'waitroom' then
    d := jsonb_build_object('color', case when coalesce(d->>'color','') ~ '^#[0-9a-fA-F]{6}$' then d->>'color' else '#1f2937' end);
    delete from public.group_items where conv = p_conv and kind = 'waitroom';
  end if;
  if p_kind = 'suggest' then perform public._need_right(auth.uid(), 'anon_suggest', p_conv); end if;
  insert into public.group_items(conv, kind, title, data, created_by, due) values (p_conv, p_kind, t, d, auth.uid(), p_due) returning id into n;
  if p_kind = 'event' and p_conv is not null then
    for u in select user_id from public.conversation_members where conversation_id = p_conv and user_id <> auth.uid() limit 200 loop
      perform public.sys_notify(u, 'Nouvel événement de groupe : ' || t || ' (' || to_char(p_due at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') || ')');
    end loop;
  end if;
  return n;
end $$;

-- ajout d'une phrase (livre) ou d'un argument (débat)
create or replace function public.gi_append(p_id bigint, p_text text, p_side int default null) returns void language plpgsql security definer set search_path = public as $$
declare i public.group_items; key text; arr jsonb; un text; t text := btrim(coalesce(p_text,''));
begin
  select * into i from public.group_items where id = p_id for update;
  if not found then raise exception 'Élément introuvable'; end if;
  if i.kind not in ('story','debate') or i.conv is null then raise exception 'Cet élément n’accepte pas d’ajout'; end if;
  if not public._is_member(i.conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
  if i.closed then raise exception 'Terminé'; end if;
  if char_length(t) not between 1 and 300 then raise exception 'Texte de 1 à 300 caractères requis'; end if;
  perform public.rate_ok('gi_append', 60, 3600);
  select username into un from public.profiles where id = auth.uid();
  key := case when i.kind = 'story' then 'parts' else 'args' end;
  arr := coalesce(i.data->key, '[]'::jsonb);
  if jsonb_array_length(arr) >= 200 then raise exception 'Limite atteinte'; end if;
  if i.kind = 'story' then
    if jsonb_array_length(arr) > 0 and (arr->-1->>'u') = un then raise exception 'Laissez quelqu’un d’autre continuer l’histoire'; end if;
    arr := arr || jsonb_build_array(jsonb_build_object('t', t, 'u', un));
  else
    if p_side not in (0,1) then raise exception 'Choisissez Pour ou Contre'; end if;
    arr := arr || jsonb_build_array(jsonb_build_object('t', t, 'u', un, 's', p_side));
  end if;
  update public.group_items set data = jsonb_set(data, array[key], arr) where id = p_id;
end $$;

-- bilan personnel de la semaine
create or replace function public.group_recap(p_conv uuid) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare mine int; prev int; tot int; rk int; best jsonb;
begin
  if not public._is_member(p_conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
  select count(*) into mine from public.messages where conversation_id = p_conv and sender_id = auth.uid() and created_at > now() - interval '7 days';
  select count(*) into prev from public.messages where conversation_id = p_conv and sender_id = auth.uid() and created_at between now() - interval '14 days' and now() - interval '7 days';
  select count(*) into tot from public.messages where conversation_id = p_conv and created_at > now() - interval '7 days';
  select 1 + count(*) into rk from (select sender_id, count(*) n from public.messages where conversation_id = p_conv and created_at > now() - interval '7 days' and sender_id is not null group by 1) q where q.n > mine;
  select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]'::jsonb) into best from (
    select (created_at at time zone 'America/Toronto')::date d, count(*) n from public.messages where conversation_id = p_conv and sender_id = auth.uid() and created_at > now() - interval '7 days' group by 1) q;
  return jsonb_build_object('mine', mine, 'prev', prev, 'group', tot, 'rank', case when mine = 0 then null else rk end, 'days', best,
    'members', (select count(*) from public.conversation_members where conversation_id = p_conv));
end $$;

-- succès secrets (les non débloqués restent cachés)
create or replace function public.achv_me(p_conv uuid) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare n int; nd int; night boolean; early boolean; wk boolean;
begin
  if not public._is_member(p_conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
  select count(*), count(distinct (created_at at time zone 'America/Toronto')::date),
    coalesce(bool_or(extract(hour from created_at at time zone 'America/Toronto') between 2 and 4), false),
    coalesce(bool_or(extract(hour from created_at at time zone 'America/Toronto') between 5 and 6), false),
    coalesce(bool_or(extract(dow from created_at at time zone 'America/Toronto') = 6), false) and coalesce(bool_or(extract(dow from created_at at time zone 'America/Toronto') = 0), false)
  into n, nd, night, early, wk from public.messages where conversation_id = p_conv and sender_id = auth.uid();
  return (select jsonb_agg(case when u then jsonb_build_object('code', c, 'unlocked', true, 'name', nm, 'desc', ds) else jsonb_build_object('code', c, 'unlocked', false) end order by o)
    from (values
      (1, 'first', n >= 1, 'Premier pas', 'Avoir écrit au moins un message dans ce groupe.'),
      (2, 'chat100', n >= 100, 'Bavard', 'Avoir écrit 100 messages dans ce groupe.'),
      (3, 'chat500', n >= 500, 'Pilier du groupe', 'Avoir écrit 500 messages dans ce groupe.'),
      (4, 'night', night, 'Noctambule', 'Avoir écrit entre 2 h et 5 h du matin.'),
      (5, 'early', early, 'Lève-tôt', 'Avoir écrit entre 5 h et 7 h du matin.'),
      (6, 'days7', nd >= 7, 'Fidèle', 'Avoir été actif 7 jours différents.'),
      (7, 'weekend', wk, 'Week-end actif', 'Avoir écrit un samedi et un dimanche.')) v(o, c, u, nm, ds));
end $$;

revoke all on function public.gi_list(uuid,text), public.gi_add(uuid,text,text,jsonb,timestamptz), public.gi_append(bigint,text,int), public.group_recap(uuid), public.achv_me(uuid) from public, anon;
grant execute on function public.gi_list(uuid,text), public.gi_add(uuid,text,text,jsonb,timestamptz), public.gi_append(bigint,text,int), public.group_recap(uuid), public.achv_me(uuid) to authenticated;
