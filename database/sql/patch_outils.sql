-- Lot 13 : fonctionnalités payantes (additif). Dépend de patch_jetons_v2, patch_droits, patch_apparence.
insert into public.shop_items(code, kind, name, descr, price, sort) values
 ('absence','feature','Message d’absence','Un message affiché à ceux qui vous écrivent',899,20),
 ('group_tools','feature','Outils de groupe','Sondages, quiz, minuteur, tâches, événements, album (à activer par un administrateur de groupe)',2999,21),
 ('personal_tools','feature','Outils personnels','Tâches, rappels récurrents, agenda, carnet de notes',99,22),
 ('export_stats','feature','Export et statistiques','Exporter vos données et consulter vos statistiques',799,23),
 ('tournaments','feature','Tournois','Organiser des tournois à élimination directe',1700,24),
 ('esport','feature','Équipe e-Sport','Équipe de groupe : nom, titre, règles et inscription aux tournois',11700,25)
on conflict (code) do update set kind = excluded.kind, name = excluded.name, descr = excluded.descr, price = excluded.price, sort = excluded.sort;

create or replace function public._owns(p_code text) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.inventory where user_id = auth.uid() and code = p_code)
$$;
create or replace function public._is_member(p_conv uuid) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = auth.uid())
$$;
create or replace function public._is_cadmin(p_conv uuid) returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = auth.uid() and role = 'admin')
$$;
revoke all on function public._owns(text), public._is_member(uuid), public._is_cadmin(uuid) from public, anon, authenticated;

-- ---------- message d'absence ----------
create table if not exists public.absence (user_id uuid primary key references public.profiles(id) on delete cascade, msg text not null check (char_length(msg) between 1 and 300), on_ boolean not null default true, at timestamptz not null default now());
alter table public.absence enable row level security; revoke all on public.absence from anon, authenticated;
create or replace function public.absence_set(p_msg text, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public._owns('absence') then raise exception 'Article non possédé'; end if;
  insert into public.absence(user_id, msg, on_) values (auth.uid(), left(btrim(coalesce(p_msg,'')),300), coalesce(p_on,true))
   on conflict (user_id) do update set msg = excluded.msg, on_ = excluded.on_, at = now();
end $$;
create or replace function public.absence_me() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce((select jsonb_build_object('msg', msg, 'on', on_) from public.absence where user_id = auth.uid()), '{}'::jsonb)
$$;
create or replace function public.absence_of(p_username text) returns text language sql security definer stable set search_path = public as $$
  select a.msg from public.absence a join public.profiles p on p.id = a.user_id
  where lower(p.username) = lower(regexp_replace(coalesce(p_username,''), '^@', '')) and a.on_ and char_length(btrim(a.msg)) > 0
$$;

-- ---------- outils de groupe ----------
create table if not exists public.group_tools (conv uuid primary key references public.conversations(id) on delete cascade, owner uuid references public.profiles(id) on delete set null, at timestamptz not null default now());
alter table public.group_tools enable row level security; revoke all on public.group_tools from anon, authenticated;
create table if not exists public.gi_kinds (kind text primary key, paid boolean not null, admin_only boolean not null, votable boolean not null default false);
insert into public.gi_kinds(kind, paid, admin_only, votable) values
 ('poll', true, true, true), ('quiz', true, true, true), ('timer', true, true, false), ('task', true, false, false), ('event', true, true, false), ('album', true, false, false)
on conflict (kind) do update set paid = excluded.paid, admin_only = excluded.admin_only, votable = excluded.votable;
alter table public.gi_kinds enable row level security; revoke all on public.gi_kinds from anon, authenticated;
create table if not exists public.group_items (
  id bigint generated always as identity primary key,
  conv uuid references public.conversations(id) on delete cascade,
  kind text not null references public.gi_kinds(kind),
  title text not null check (char_length(title) between 1 and 200),
  data jsonb not null default '{}'::jsonb check (pg_column_size(data) < 20000),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  closed boolean not null default false,
  due timestamptz
);
create index if not exists group_items_conv on public.group_items (conv, kind, created_at desc);
alter table public.group_items enable row level security; revoke all on public.group_items from anon, authenticated;
create table if not exists public.group_votes (item bigint not null references public.group_items(id) on delete cascade, user_id uuid not null references public.profiles(id) on delete cascade, choice int not null check (choice between 0 and 19), at timestamptz not null default now(), primary key (item, user_id));
alter table public.group_votes enable row level security; revoke all on public.group_votes from anon, authenticated;

create or replace function public.tools_state(p_conv uuid) returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if p_conv is null then return jsonb_build_object('on', true, 'admin', public.staff_rank_me() >= 4, 'owned', public.staff_rank_me() >= 4, 'member', true); end if;
  return jsonb_build_object('on', exists(select 1 from public.group_tools where conv = p_conv), 'admin', public._is_cadmin(p_conv), 'owned', public._owns('group_tools'), 'member', public._is_member(p_conv));
end $$;
create or replace function public.tools_enable(p_conv uuid, p_on boolean default true) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_cadmin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if p_on then
    if not public._owns('group_tools') then raise exception 'Achetez d’abord « Outils de groupe » dans la boutique'; end if;
    insert into public.group_tools(conv, owner) values (p_conv, auth.uid()) on conflict do nothing;
  else delete from public.group_tools where conv = p_conv; end if;
end $$;

create or replace function public.gi_list(p_conv uuid, p_kind text) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_conv is not null then
    if not public._is_member(p_conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
  elsif p_kind not in ('poll','quiz') then raise exception 'Type inconnu'; end if;
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into r from (
    select jsonb_build_object('id', i.id, 'title', i.title, 'data', i.data, 'closed', i.closed, 'due', i.due, 'created_at', i.created_at,
      'by', (select username from public.profiles where id = i.created_by), 'mine', i.created_by = auth.uid(),
      'votes', coalesce((select jsonb_object_agg(c::text, n) from (select choice c, count(*) n from public.group_votes v where v.item = i.id group by choice) q), '{}'::jsonb),
      'my', (select choice from public.group_votes v where v.item = i.id and v.user_id = auth.uid())) x
    from public.group_items i where i.conv is not distinct from p_conv and i.kind = p_kind order by i.created_at desc limit 100) s;
  return r;
end $$;

create or replace function public.gi_add(p_conv uuid, p_kind text, p_title text, p_data jsonb default '{}'::jsonb, p_due timestamptz default null) returns bigint language plpgsql security definer set search_path = public as $$
declare k public.gi_kinds; n bigint; u uuid; t text := btrim(coalesce(p_title,''));
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
  if p_kind in ('poll','quiz') and (jsonb_typeof(p_data->'options') is distinct from 'array' or jsonb_array_length(p_data->'options') not between 2 and 10) then raise exception 'Il faut de 2 à 10 choix'; end if;
  if p_kind = 'quiz' and (p_data->>'answer') !~ '^[0-9]$' then raise exception 'Réponse du quiz manquante'; end if;
  if p_kind in ('timer','event') and p_due is null then raise exception 'Date requise'; end if;
  insert into public.group_items(conv, kind, title, data, created_by, due) values (p_conv, p_kind, t, coalesce(p_data,'{}'::jsonb), auth.uid(), p_due) returning id into n;
  if p_kind = 'event' and p_conv is not null then
    for u in select user_id from public.conversation_members where conversation_id = p_conv and user_id <> auth.uid() limit 200 loop
      perform public.sys_notify(u, 'Nouvel événement de groupe : ' || t || ' (' || to_char(p_due at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') || ')');
    end loop;
  end if;
  return n;
end $$;

create or replace function public._gi_can(p_id bigint) returns public.group_items language plpgsql security definer stable set search_path = public as $$
declare i public.group_items;
begin
  select * into i from public.group_items where id = p_id;
  if not found then raise exception 'Élément introuvable'; end if;
  if i.conv is null then
    if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  elsif not (public._is_cadmin(i.conv) or (i.created_by = auth.uid() and public._is_member(i.conv))) then raise exception 'Action réservée à l’auteur ou aux administrateurs'; end if;
  return i;
end $$;
revoke all on function public._gi_can(bigint) from public, anon, authenticated;

create or replace function public.gi_set(p_id bigint, p_data jsonb default null, p_closed boolean default null) returns void language plpgsql security definer set search_path = public as $$
declare i public.group_items; k public.gi_kinds;
begin
  select * into i from public.group_items where id = p_id;
  if not found then raise exception 'Élément introuvable'; end if;
  select * into k from public.gi_kinds where kind = i.kind;
  -- les tâches se cochent par tout membre ; le reste par l'auteur ou un administrateur
  if i.kind = 'task' and i.conv is not null and public._is_member(i.conv) then null; else perform public._gi_can(p_id); end if;
  update public.group_items set data = case when p_data is null then data else data || p_data end, closed = coalesce(p_closed, closed) where id = p_id;
end $$;
create or replace function public.gi_del(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
begin perform public._gi_can(p_id); delete from public.group_items where id = p_id; end $$;

create or replace function public.gi_vote(p_id bigint, p_choice int) returns void language plpgsql security definer set search_path = public as $$
declare i public.group_items; k public.gi_kinds; nopt int;
begin
  select * into i from public.group_items where id = p_id;
  if not found then raise exception 'Élément introuvable'; end if;
  select * into k from public.gi_kinds where kind = i.kind;
  if not k.votable then raise exception 'Cet élément n’accepte pas de vote'; end if;
  if i.conv is not null and not public._is_member(i.conv) then raise exception 'Vous n’êtes pas membre de ce groupe'; end if;
  perform public._need_right(auth.uid(), 'vote', i.conv);
  if i.closed or (i.due is not null and i.due < now()) then raise exception 'Vote terminé'; end if;
  nopt := jsonb_array_length(coalesce(i.data->'options', '[]'::jsonb));
  if p_choice is null or p_choice < 0 or p_choice >= nopt then raise exception 'Choix invalide'; end if;
  if i.kind in ('quiz') and exists(select 1 from public.group_votes where item = p_id and user_id = auth.uid()) then raise exception 'Vous avez déjà répondu'; end if;
  insert into public.group_votes(item, user_id, choice) values (p_id, auth.uid(), p_choice)
    on conflict (item, user_id) do update set choice = excluded.choice, at = now();
end $$;

-- ---------- outils personnels ----------
create table if not exists public.personal_items (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('todo','reminder','agenda','note')),
  title text not null check (char_length(title) between 1 and 200),
  body text check (body is null or char_length(body) <= 5000),
  due timestamptz, rep text not null default 'none' check (rep in ('none','daily','weekly','monthly')),
  done boolean not null default false, at timestamptz not null default now()
);
create index if not exists personal_items_u on public.personal_items (user_id, kind);
alter table public.personal_items enable row level security; revoke all on public.personal_items from anon, authenticated;
create or replace function public.pi_list(p_kind text) returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public._owns('personal_tools') then raise exception 'Article non possédé'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'body', body, 'due', due, 'rep', rep, 'done', done) order by done, due nulls last, at desc)
    from public.personal_items where user_id = auth.uid() and kind = p_kind), '[]'::jsonb);
end $$;
create or replace function public.pi_add(p_kind text, p_title text, p_body text default null, p_due timestamptz default null, p_rep text default 'none') returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if not public._owns('personal_tools') then raise exception 'Article non possédé'; end if;
  if p_kind not in ('todo','reminder','agenda','note') then raise exception 'Type inconnu'; end if;
  if p_kind in ('reminder','agenda') and p_due is null then raise exception 'Date requise'; end if;
  if (select count(*) from public.personal_items where user_id = auth.uid()) >= 500 then raise exception 'Limite de 500 éléments atteinte'; end if;
  insert into public.personal_items(user_id, kind, title, body, due, rep) values (auth.uid(), p_kind, btrim(coalesce(p_title,'')), p_body, p_due, coalesce(p_rep,'none')) returning id into n;
  return n;
end $$;
create or replace function public.pi_set(p_id bigint, p_title text default null, p_body text default null, p_done boolean default null, p_due timestamptz default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._owns('personal_tools') then raise exception 'Article non possédé'; end if;
  update public.personal_items set title = coalesce(nullif(btrim(p_title),''), title), body = coalesce(p_body, body), done = coalesce(p_done, done), due = coalesce(p_due, due) where id = p_id and user_id = auth.uid();
  if not found then raise exception 'Élément introuvable'; end if;
end $$;
create or replace function public.pi_del(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
begin delete from public.personal_items where id = p_id and user_id = auth.uid(); end $$;
-- rappels échus : renvoie et fait avancer les récurrents
create or replace function public.pi_due() returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb := '[]'::jsonb; x record;
begin
  if auth.uid() is null or not public._owns('personal_tools') then return r; end if;
  for x in select * from public.personal_items where user_id = auth.uid() and kind = 'reminder' and not done and due <= now() order by due limit 20 loop
    r := r || jsonb_build_array(jsonb_build_object('id', x.id, 'title', x.title, 'due', x.due));
    if x.rep = 'none' then update public.personal_items set done = true where id = x.id;
    else update public.personal_items set due = (case x.rep when 'daily' then interval '1 day' when 'weekly' then interval '7 days' else interval '1 month' end) * greatest(1, ceil(extract(epoch from (now() - x.due)) / extract(epoch from (case x.rep when 'daily' then interval '1 day' when 'weekly' then interval '7 days' else interval '31 days' end)))::int) + x.due where id = x.id; end if;
  end loop;
  return r;
end $$;
-- agenda unifié : personnel + événements des groupes
create or replace function public.agenda_all(p_days int default 60) returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public._owns('personal_tools') then raise exception 'Article non possédé'; end if;
  return coalesce((select jsonb_agg(z order by z->>'due') from (
    select jsonb_build_object('src','perso','title',title,'due',due,'where',null) z from public.personal_items where user_id = auth.uid() and kind in ('agenda','reminder') and not done and due between now() - interval '1 day' and now() + make_interval(days => least(greatest(p_days,1),365))
    union all
    select jsonb_build_object('src','groupe','title',i.title,'due',i.due,'where',c.name) from public.group_items i join public.conversations c on c.id = i.conv
      where i.kind = 'event' and i.due between now() - interval '1 day' and now() + make_interval(days => least(greatest(p_days,1),365)) and exists(select 1 from public.conversation_members m where m.conversation_id = i.conv and m.user_id = auth.uid())) q), '[]'::jsonb);
end $$;

-- ---------- export et statistiques ----------
create or replace function public.export_me() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public._owns('export_stats') then raise exception 'Article non possédé'; end if;
  perform public._need_right(auth.uid(), 'export');
  return jsonb_build_object('exporte_le', now(),
    'profil', (select to_jsonb(p) - 'id' - 'public_key' from public.profiles p where p.id = auth.uid()),
    'jetons', coalesce((select balance from public.wallets where user_id = auth.uid()), 0),
    'historique_jetons', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' - 'id' order by t.at desc) from (select * from public.token_log where user_id = auth.uid() order by at desc limit 500) t), '[]'::jsonb),
    'stats_jeux', coalesce((select jsonb_agg(to_jsonb(g) - 'user_id') from public.game_stats g where g.user_id = auth.uid()), '[]'::jsonb),
    'articles', coalesce((select jsonb_agg(code) from public.inventory where user_id = auth.uid()), '[]'::jsonb),
    'elements_personnels', coalesce((select jsonb_agg(to_jsonb(i) - 'user_id' - 'id') from public.personal_items i where i.user_id = auth.uid()), '[]'::jsonb));
end $$;
create or replace function public.stats_me() returns jsonb language plpgsql security definer stable set search_path = public as $$
begin
  if not public._owns('export_stats') then raise exception 'Article non possédé'; end if;
  perform public._need_right(auth.uid(), 'export');
  return jsonb_build_object(
    'messages_total', (select count(*) from public.messages where sender_id = auth.uid()),
    'par_jour', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d) from (select (created_at at time zone 'America/Toronto')::date d, count(*) n from public.messages where sender_id = auth.uid() and created_at > now() - interval '30 days' group by 1) q), '[]'::jsonb),
    'par_conv', coalesce((select jsonb_agg(jsonb_build_object('conv', conv, 'n', n) order by n desc) from (select conversation_id conv, count(*) n from public.messages where sender_id = auth.uid() group by 1 order by 2 desc limit 5) q), '[]'::jsonb),
    'jeux', coalesce((select jsonb_agg(to_jsonb(g) - 'user_id') from public.game_stats g where g.user_id = auth.uid()), '[]'::jsonb));
end $$;

-- ---------- équipes e-Sport ----------
create table if not exists public.esport_teams (
  conv uuid primary key references public.conversations(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 30), title text check (title is null or char_length(title) <= 30), rules text check (rules is null or char_length(rules) <= 1500),
  owner uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now()
);
create unique index if not exists esport_name_uq on public.esport_teams (lower(name));
alter table public.esport_teams enable row level security; revoke all on public.esport_teams from anon, authenticated;
create or replace function public.esport_set(p_conv uuid, p_name text, p_title text, p_rules text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_cadmin(p_conv) then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if not exists(select 1 from public.conversations where id = p_conv and kind = 'group') then raise exception 'Seuls les groupes peuvent former une équipe'; end if;
  perform public._need_right(auth.uid(), 'esport', p_conv);
  if exists(select 1 from public.esport_teams where conv = p_conv) then
    if not exists(select 1 from public.esport_teams where conv = p_conv and owner = auth.uid()) then raise exception 'Seul le fondateur de l’équipe peut la modifier'; end if;
  elsif not public._owns('esport') then raise exception 'Achetez d’abord « Équipe e-Sport » dans la boutique'; end if;
  begin
    insert into public.esport_teams(conv, name, title, rules, owner) values (p_conv, btrim(p_name), nullif(btrim(coalesce(p_title,'')),''), nullif(btrim(coalesce(p_rules,'')),''), auth.uid())
    on conflict (conv) do update set name = excluded.name, title = excluded.title, rules = excluded.rules;
  exception when unique_violation then raise exception 'Ce nom d’équipe est déjà pris'; end;
end $$;
create or replace function public.esport_del(p_conv uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.esport_teams where conv = p_conv and owner = auth.uid()) and public.staff_rank_me() < 4 then raise exception 'Réservé au fondateur de l’équipe'; end if;
  delete from public.esport_teams where conv = p_conv;
end $$;
create or replace function public.esport_get(p_conv uuid) returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce((select jsonb_build_object('name', name, 'title', title, 'rules', rules, 'mine', owner = auth.uid()) from public.esport_teams where conv = p_conv and public._is_member(p_conv)), '{}'::jsonb)
$$;
create or replace function public.esport_of(p_username text) returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'title', t.title)), '[]'::jsonb)
  from public.esport_teams t join public.conversation_members m on m.conversation_id = t.conv join public.profiles p on p.id = m.user_id
  where lower(p.username) = lower(regexp_replace(coalesce(p_username,''), '^@', ''))
$$;

-- ---------- tournois ----------
create table if not exists public.tournaments (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 2 and 60), game text check (game is null or char_length(game) <= 40), rules text check (rules is null or char_length(rules) <= 1500),
  creator uuid references public.profiles(id) on delete set null, status text not null default 'open' check (status in ('open','running','done')),
  max_n int not null default 16 check (max_n between 2 and 64), winner text, created_at timestamptz not null default now()
);
create table if not exists public.t_entries (tid bigint not null references public.tournaments(id) on delete cascade, ref uuid not null, kind text not null check (kind in ('user','team')), label text not null, primary key (tid, ref));
create table if not exists public.t_matches (
  id bigint generated always as identity primary key, tid bigint not null references public.tournaments(id) on delete cascade,
  rnd int not null, slot int not null, a_ref uuid, a_label text, b_ref uuid, b_label text, winner_ref uuid, unique (tid, rnd, slot)
);
alter table public.tournaments enable row level security; alter table public.t_entries enable row level security; alter table public.t_matches enable row level security;
revoke all on public.tournaments, public.t_entries, public.t_matches from anon, authenticated;

create or replace function public.t_create(p_name text, p_game text, p_rules text, p_max int) returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if not public._owns('tournaments') then raise exception 'Achetez d’abord « Tournois » dans la boutique'; end if;
  perform public._need_right(auth.uid(), 'tournaments');
  perform public.rate_ok('t_create', 10, 3600);
  insert into public.tournaments(name, game, rules, creator, max_n) values (btrim(coalesce(p_name,'')), nullif(btrim(coalesce(p_game,'')),''), nullif(btrim(coalesce(p_rules,'')),''), auth.uid(), least(greatest(coalesce(p_max,16),2),64)) returning id into n;
  return n;
end $$;
create or replace function public.t_list() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'game', t.game, 'status', t.status, 'max', t.max_n, 'winner', t.winner,
    'by', (select username from public.profiles where id = t.creator), 'mine', t.creator = auth.uid(),
    'n', (select count(*) from public.t_entries e where e.tid = t.id), 'in', exists(select 1 from public.t_entries e where e.tid = t.id and e.ref = auth.uid())) order by t.id desc), '[]'::jsonb)
  from (select * from public.tournaments order by id desc limit 60) t
$$;
create or replace function public.t_get(p_id bigint) returns jsonb language plpgsql security definer stable set search_path = public as $$
declare t public.tournaments;
begin
  select * into t from public.tournaments where id = p_id;
  if not found then raise exception 'Tournoi introuvable'; end if;
  return jsonb_build_object('id', t.id, 'name', t.name, 'game', t.game, 'rules', t.rules, 'status', t.status, 'max', t.max_n, 'winner', t.winner, 'mine', t.creator = auth.uid(), 'by', (select username from public.profiles where id = t.creator),
    'entries', coalesce((select jsonb_agg(jsonb_build_object('label', label, 'kind', kind, 'me', ref = auth.uid()) order by label) from public.t_entries where tid = p_id), '[]'::jsonb),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'rnd', rnd, 'slot', slot, 'a', a_label, 'b', b_label, 'aref', a_ref, 'bref', b_ref, 'win', winner_ref) order by rnd, slot) from public.t_matches where tid = p_id), '[]'::jsonb));
end $$;
create or replace function public.t_join(p_id bigint, p_team uuid default null) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; lbl text; r uuid; k text; tt public.esport_teams;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found then raise exception 'Tournoi introuvable'; end if;
  if t.status <> 'open' then raise exception 'Les inscriptions sont closes'; end if;
  perform public._need_right(auth.uid(), 'tournaments');
  if (select count(*) from public.t_entries where tid = p_id) >= t.max_n then raise exception 'Tournoi complet'; end if;
  if p_team is null then
    select username into lbl from public.profiles where id = auth.uid(); r := auth.uid(); k := 'user'; lbl := '@' || lbl;
  else
    select * into tt from public.esport_teams where conv = p_team;
    if not found or tt.owner is distinct from auth.uid() then raise exception 'Seul le fondateur de l’équipe peut l’inscrire'; end if;
    r := p_team; k := 'team'; lbl := tt.name || coalesce(' [' || tt.title || ']', '');
  end if;
  if exists(select 1 from public.t_entries where tid = p_id and ref = r) then raise exception 'Déjà inscrit'; end if;
  insert into public.t_entries(tid, ref, kind, label) values (p_id, r, k, lbl);
end $$;
create or replace function public.t_leave(p_id bigint, p_team uuid default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if (select status from public.tournaments where id = p_id) is distinct from 'open' then raise exception 'Les inscriptions sont closes'; end if;
  delete from public.t_entries where tid = p_id and ref = coalesce(p_team, auth.uid()) and (p_team is null or exists(select 1 from public.esport_teams where conv = p_team and owner = auth.uid()));
end $$;
create or replace function public._t_push(p_match bigint) returns void language plpgsql security definer set search_path = public as $$
declare m public.t_matches; lbl text; nx public.t_matches; maxr int;
begin
  select * into m from public.t_matches where id = p_match;
  lbl := case when m.winner_ref = m.a_ref then m.a_label else m.b_label end;
  select max(rnd) into maxr from public.t_matches where tid = m.tid;
  if m.rnd = maxr then
    update public.tournaments set status = 'done', winner = lbl where id = m.tid; return;
  end if;
  if m.slot % 2 = 1 then update public.t_matches set a_ref = m.winner_ref, a_label = lbl where tid = m.tid and rnd = m.rnd + 1 and slot = (m.slot + 1) / 2;
  else update public.t_matches set b_ref = m.winner_ref, b_label = lbl where tid = m.tid and rnd = m.rnd + 1 and slot = (m.slot + 1) / 2; end if;
end $$;
revoke all on function public._t_push(bigint) from public, anon, authenticated;

create or replace function public.t_start(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare t public.tournaments; n int; sz int := 2; rounds int := 1; r int; s int; e record; arr uuid[]; lbl text[]; i int; mid bigint;
begin
  select * into t from public.tournaments where id = p_id for update;
  if not found then raise exception 'Tournoi introuvable'; end if;
  if t.creator is distinct from auth.uid() then raise exception 'Réservé à l’organisateur'; end if;
  if t.status <> 'open' then raise exception 'Tournoi déjà lancé'; end if;
  select count(*) into n from public.t_entries where tid = p_id;
  if n < 2 then raise exception 'Il faut au moins 2 inscrits'; end if;
  while sz < n loop sz := sz * 2; rounds := rounds + 1; end loop;
  select array_agg(ref), array_agg(label) into arr, lbl from (select ref, label from public.t_entries where tid = p_id order by random()) q;
  for r in 1..rounds loop
    for s in 1..(sz / (2 ^ r)::int) loop
      insert into public.t_matches(tid, rnd, slot) values (p_id, r, s);
    end loop;
  end loop;
  -- tour 1 : tête de série s contre la place (sz+1-s) ; les places vides sont des byes répartis
  for s in 1..(sz / 2) loop
    update public.t_matches set a_ref = arr[s], a_label = lbl[s], b_ref = arr[sz + 1 - s], b_label = lbl[sz + 1 - s] where tid = p_id and rnd = 1 and slot = s;
  end loop;
  update public.tournaments set status = 'running' where id = p_id;
  for e in select id from public.t_matches where tid = p_id and rnd = 1 and (a_ref is null or b_ref is null) and not (a_ref is null and b_ref is null) loop
    update public.t_matches set winner_ref = coalesce(a_ref, b_ref) where id = e.id;
    perform public._t_push(e.id);
  end loop;
end $$;
create or replace function public.t_report(p_match bigint, p_winner uuid) returns void language plpgsql security definer set search_path = public as $$
declare m public.t_matches; t public.tournaments;
begin
  select * into m from public.t_matches where id = p_match for update;
  if not found then raise exception 'Match introuvable'; end if;
  select * into t from public.tournaments where id = m.tid;
  if t.creator is distinct from auth.uid() then raise exception 'Réservé à l’organisateur'; end if;
  if t.status <> 'running' then raise exception 'Tournoi non en cours'; end if;
  if m.winner_ref is not null then raise exception 'Match déjà joué'; end if;
  if m.a_ref is null or m.b_ref is null then raise exception 'Adversaire pas encore connu'; end if;
  if p_winner not in (m.a_ref, m.b_ref) then raise exception 'Vainqueur invalide'; end if;
  update public.t_matches set winner_ref = p_winner where id = p_match;
  perform public._t_push(p_match);
end $$;
create or replace function public.t_delete(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.tournaments where id = p_id and creator = auth.uid()) and public.staff_rank_me() < 4 then raise exception 'Réservé à l’organisateur'; end if;
  delete from public.tournaments where id = p_id;
end $$;

revoke all on function public.absence_set(text,boolean), public.absence_me(), public.absence_of(text), public.tools_state(uuid), public.tools_enable(uuid,boolean),
  public.gi_list(uuid,text), public.gi_add(uuid,text,text,jsonb,timestamptz), public.gi_set(bigint,jsonb,boolean), public.gi_del(bigint), public.gi_vote(bigint,int),
  public.pi_list(text), public.pi_add(text,text,text,timestamptz,text), public.pi_set(bigint,text,text,boolean,timestamptz), public.pi_del(bigint), public.pi_due(), public.agenda_all(int),
  public.export_me(), public.stats_me(), public.esport_set(uuid,text,text,text), public.esport_del(uuid), public.esport_get(uuid), public.esport_of(text),
  public.t_create(text,text,text,int), public.t_list(), public.t_get(bigint), public.t_join(bigint,uuid), public.t_leave(bigint,uuid), public.t_start(bigint), public.t_report(bigint,uuid), public.t_delete(bigint) from public, anon;
grant execute on function public.absence_set(text,boolean), public.absence_me(), public.absence_of(text), public.tools_state(uuid), public.tools_enable(uuid,boolean),
  public.gi_list(uuid,text), public.gi_add(uuid,text,text,jsonb,timestamptz), public.gi_set(bigint,jsonb,boolean), public.gi_del(bigint), public.gi_vote(bigint,int),
  public.pi_list(text), public.pi_add(text,text,text,timestamptz,text), public.pi_set(bigint,text,text,boolean,timestamptz), public.pi_del(bigint), public.pi_due(), public.agenda_all(int),
  public.export_me(), public.stats_me(), public.esport_set(uuid,text,text,text), public.esport_del(uuid), public.esport_get(uuid), public.esport_of(text),
  public.t_create(text,text,text,int), public.t_list(), public.t_get(bigint), public.t_join(bigint,uuid), public.t_leave(bigint,uuid), public.t_start(bigint), public.t_report(bigint,uuid), public.t_delete(bigint) to authenticated;
