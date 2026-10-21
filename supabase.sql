-- ============================================================
-- Communicer! — schéma Supabase (nouveau projet, idempotent)
-- Prérequis : Authentication > Providers > Email > désactiver "Confirm email"
-- ============================================================

-- ---------- Tables ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null,
  nickname    text,
  avatar_url  text,
  public_key  jsonb,
  last_seen   timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  constraint profiles_username_fmt check (username ~ '^[a-z0-9_]{3,20}$'),
  constraint profiles_nickname_len check (nickname is null or char_length(nickname) <= 40)
);
create unique index if not exists profiles_username_uq on public.profiles (username);

-- Clé privée chiffrée côté navigateur (le serveur ne la lit jamais en clair)
create table if not exists public.user_keys (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  enc_private_key text not null,
  salt            text not null
);

create table if not exists public.friendships (
  id         bigint generated always as identity primary key,
  requester  uuid not null references public.profiles(id) on delete cascade,
  addressee  uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  constraint friendships_not_self check (requester <> addressee)
);
create unique index if not exists friendships_pair_uq
  on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  num             bigint generated always as identity,
  kind            text not null check (kind in ('direct','group')),
  mode            text not null check (mode in ('clear','e2e')),
  name            text,
  avatar_url      text,
  theme           jsonb not null default '{}'::jsonb,
  created_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  role            text not null default 'member' check (role in ('admin','member')),
  joined_at       timestamptz not null default now(),
  last_read_at    timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index if not exists cm_user_idx on public.conversation_members (user_id);

-- Clé AES-256 de la conversation, enveloppée pour chaque membre (ECDH P-256)
create table if not exists public.conversation_keys (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  from_user       uuid not null references public.profiles(id) on delete cascade,
  wrapped_key     text not null,
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id) on delete cascade,
  kind            text not null default 'text' check (kind in ('text','image','voice','drawing','system')),
  body            text check (body is null or char_length(body) <= 20000),
  media_path      text,
  created_at      timestamptz not null default now()
);
create index if not exists messages_conv_idx on public.messages (conversation_id, id);

-- ---------- Aide RLS ----------
create or replace function public.is_member(p_conv uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = p_conv and user_id = auth.uid()
  );
$$;

-- ---------- RLS ----------
alter table public.profiles             enable row level security;
alter table public.user_keys            enable row level security;
alter table public.friendships          enable row level security;
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.conversation_keys    enable row level security;
alter table public.messages             enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists user_keys_select on public.user_keys;
create policy user_keys_select on public.user_keys for select to authenticated using (user_id = auth.uid());
drop policy if exists user_keys_insert on public.user_keys;
create policy user_keys_insert on public.user_keys for insert to authenticated with check (user_id = auth.uid());

drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select to authenticated using (public.is_member(id));

drop policy if exists cm_select on public.conversation_members;
create policy cm_select on public.conversation_members for select to authenticated using (public.is_member(conversation_id));

drop policy if exists ck_select on public.conversation_keys;
create policy ck_select on public.conversation_keys for select to authenticated using (user_id = auth.uid());

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated using (public.is_member(conversation_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and kind <> 'system' and public.is_member(conversation_id));

-- ---------- Privilèges ----------
grant select, insert on public.profiles to authenticated;
grant update (nickname, avatar_url, last_seen) on public.profiles to authenticated;
grant select, insert on public.user_keys to authenticated;
grant select on public.friendships to authenticated;
grant select on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant select on public.conversation_keys to authenticated;
grant select, insert on public.messages to authenticated;

-- ---------- Trigger : dernier message ----------
create or replace function public.trg_msg_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists msg_after on public.messages;
create trigger msg_after after insert on public.messages
  for each row execute function public.trg_msg_after();

-- ---------- Amis ----------
create or replace function public.send_friend_request(p_username text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_other uuid;
  v_f public.friendships%rowtype;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  select id into v_other from public.profiles where username = lower(trim(p_username));
  if v_other is null then raise exception 'Utilisateur introuvable'; end if;
  if v_other = v_me then raise exception 'Vous ne pouvez pas vous ajouter vous-même'; end if;
  select * into v_f from public.friendships
   where least(requester, addressee) = least(v_me, v_other)
     and greatest(requester, addressee) = greatest(v_me, v_other);
  if found then
    if v_f.status = 'accepted' then raise exception 'Vous êtes déjà amis'; end if;
    if v_f.requester = v_me then raise exception 'Demande déjà envoyée'; end if;
    update public.friendships set status = 'accepted' where id = v_f.id;
    return 'accepted';
  end if;
  insert into public.friendships (requester, addressee, status) values (v_me, v_other, 'pending');
  return 'sent';
end $$;

create or replace function public.respond_friend_request(p_id bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.friendships
                  where id = p_id and addressee = auth.uid() and status = 'pending') then
    raise exception 'Demande introuvable';
  end if;
  if p_accept then
    update public.friendships set status = 'accepted' where id = p_id;
  else
    delete from public.friendships where id = p_id;
  end if;
end $$;

create or replace function public.remove_friend(p_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v_other uuid;
begin
  select id into v_other from public.profiles where username = lower(trim(p_username));
  if v_other is null then raise exception 'Utilisateur introuvable'; end if;
  delete from public.friendships
   where least(requester, addressee) = least(auth.uid(), v_other)
     and greatest(requester, addressee) = greatest(auth.uid(), v_other);
end $$;

-- ---------- Conversations ----------
create or replace function public.create_conversation(
  p_kind text, p_mode text, p_name text, p_usernames text[],
  p_keys jsonb default null, p_avatar text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
  v_u text;
  v_p uuid;
  r record;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if p_kind not in ('direct','group') then raise exception 'Type invalide'; end if;
  if p_mode not in ('clear','e2e') then raise exception 'Mode invalide'; end if;
  if p_kind = 'group' and coalesce(trim(p_name), '') = '' then
    raise exception 'Nom du groupe requis';
  end if;
  if p_kind = 'direct' then
    if coalesce(array_length(p_usernames, 1), 0) <> 1 then raise exception 'Une seule personne attendue'; end if;
    select id into v_p from public.profiles where username = lower(trim(p_usernames[1]));
    if v_p is null then raise exception 'Utilisateur introuvable'; end if;
    if not exists (select 1 from public.friendships
                    where status = 'accepted'
                      and least(requester, addressee) = least(v_me, v_p)
                      and greatest(requester, addressee) = greatest(v_me, v_p)) then
      raise exception 'Vous devez être amis';
    end if;
  end if;

  insert into public.conversations (kind, mode, name, avatar_url, created_by)
  values (p_kind, p_mode,
          case when p_kind = 'group' then trim(p_name) end,
          case when p_kind = 'group' then p_avatar end,
          v_me)
  returning id into v_id;

  insert into public.conversation_members (conversation_id, user_id, role)
  values (v_id, v_me, case when p_kind = 'group' then 'admin' else 'member' end);

  foreach v_u in array coalesce(p_usernames, '{}'::text[]) loop
    select id into v_p from public.profiles where username = lower(trim(v_u));
    if v_p is null then raise exception 'Utilisateur introuvable : %', v_u; end if;
    if v_p <> v_me then
      insert into public.conversation_members (conversation_id, user_id)
      values (v_id, v_p) on conflict do nothing;
    end if;
  end loop;

  if p_mode = 'e2e' then
    for r in select cm.user_id, p.username
               from public.conversation_members cm
               join public.profiles p on p.id = cm.user_id
              where cm.conversation_id = v_id loop
      if coalesce(p_keys ->> r.username, '') = '' then
        raise exception 'Clé manquante pour %', r.username;
      end if;
      insert into public.conversation_keys (conversation_id, user_id, from_user, wrapped_key)
      values (v_id, r.user_id, v_me, p_keys ->> r.username);
    end loop;
  end if;
  return v_id;
end $$;

create or replace function public.add_member(p_conv uuid, p_username text, p_wrapped text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_c public.conversations%rowtype;
  v_p uuid;
  v_un text := lower(trim(p_username));
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'Réservé aux groupes'; end if;
  select id into v_p from public.profiles where username = v_un;
  if v_p is null then raise exception 'Utilisateur introuvable'; end if;
  if exists (select 1 from public.conversation_members where conversation_id = p_conv and user_id = v_p) then
    raise exception 'Déjà dans le groupe';
  end if;
  if v_c.mode = 'e2e' and coalesce(p_wrapped, '') = '' then raise exception 'Clé manquante'; end if;
  insert into public.conversation_members (conversation_id, user_id) values (p_conv, v_p);
  if v_c.mode = 'e2e' then
    insert into public.conversation_keys (conversation_id, user_id, from_user, wrapped_key)
    values (p_conv, v_p, v_me, p_wrapped);
  else
    insert into public.messages (conversation_id, sender_id, kind, body)
    values (p_conv, v_me, 'system', '@' || v_un || ' a été ajouté au groupe');
  end if;
end $$;

create or replace function public.leave_conversation(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_c public.conversations%rowtype;
  v_un text;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind <> 'group' then raise exception 'Réservé aux groupes'; end if;
  select username into v_un from public.profiles where id = v_me;
  if v_c.mode = 'clear' then
    insert into public.messages (conversation_id, sender_id, kind, body)
    values (p_conv, v_me, 'system', '@' || v_un || ' a quitté le groupe');
  end if;
  delete from public.conversation_keys where conversation_id = p_conv and user_id = v_me;
  delete from public.conversation_members where conversation_id = p_conv and user_id = v_me;
  if not exists (select 1 from public.conversation_members where conversation_id = p_conv) then
    delete from public.conversations where id = p_conv;
  end if;
end $$;

create or replace function public.update_group(p_conv uuid, p_name text, p_avatar text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  update public.conversations
     set name = coalesce(nullif(trim(p_name), ''), name),
         avatar_url = coalesce(p_avatar, avatar_url)
   where id = p_conv and kind = 'group';
end $$;

create or replace function public.set_theme(p_conv uuid, p_theme jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  if jsonb_typeof(p_theme) <> 'object' then raise exception 'Thème invalide'; end if;
  if char_length(p_theme::text) > 4000 then raise exception 'Thème trop volumineux'; end if;
  update public.conversations set theme = p_theme where id = p_conv;
end $$;

-- Marque la conversation comme lue (conversations "clear" seulement :
-- en mode chiffré le serveur ne garde aucune trace de lecture)
create or replace function public.mark_read(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.conversation_members cm
     set last_read_at = now()
    from public.conversations c
   where c.id = cm.conversation_id
     and cm.conversation_id = p_conv
     and cm.user_id = auth.uid()
     and c.mode = 'clear';
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'send_friend_request(text)',
    'respond_friend_request(bigint,boolean)',
    'remove_friend(text)',
    'create_conversation(text,text,text,text[],jsonb,text)',
    'add_member(uuid,text,text)',
    'leave_conversation(uuid)',
    'update_group(uuid,text,text)',
    'set_theme(uuid,jsonb)',
    'mark_read(uuid)',
    'is_member(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------- Realtime ----------
do $$
declare t text;
begin
  foreach t in array array['messages','conversations','conversation_members','friendships'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- Stockage (images, vocaux, fonds d'écran, avatars) ----------
insert into storage.buckets (id, name, public)
values ('communicer-media', 'communicer-media', true)
on conflict (id) do nothing;

drop policy if exists cm_media_read on storage.objects;
create policy cm_media_read on storage.objects for select
  using (bucket_id = 'communicer-media');

drop policy if exists cm_media_insert on storage.objects;
create policy cm_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'communicer-media' and (storage.foldername(name))[1] = auth.uid()::text);
