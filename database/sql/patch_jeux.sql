-- ============================================================
-- Communicer! — PATCH ADDITIF (jeux, bloc-note, envoi fiable)
-- À exécuter APRÈS supabase.sql. Idempotent : peut être relancé.
-- ============================================================

-- 1) Nouveau type de conversation : 'self' (Bloc-note)
do $$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.conversations'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%''direct''%' loop
    execute format('alter table public.conversations drop constraint %I', r.conname);
  end loop;
  alter table public.conversations
    add constraint conversations_kind_check check (kind in ('direct','group','self'));
end $$;

-- 2) Nouveau type de message : 'game' (résultats de partie)
do $$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.messages'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%''voice''%' loop
    execute format('alter table public.messages drop constraint %I', r.conname);
  end loop;
  alter table public.messages
    add constraint messages_kind_check check (kind in ('text','image','voice','drawing','system','game'));
end $$;

-- 3) Un seul Bloc-note par utilisateur
create unique index if not exists conversations_self_uq
  on public.conversations (created_by) where kind = 'self';

create or replace function public.ensure_notepad()
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  select id into v_id from public.conversations where kind = 'self' and created_by = v_me;
  if v_id is not null then return v_id; end if;
  begin
    insert into public.conversations (kind, mode, name, created_by)
    values ('self', 'clear', 'Bloc-note', v_me) returning id into v_id;
    insert into public.conversation_members (conversation_id, user_id, role)
    values (v_id, v_me, 'admin');
  exception when unique_violation then
    select id into v_id from public.conversations where kind = 'self' and created_by = v_me;
  end;
  return v_id;
end $$;

-- 4) Envoi de message par fonction (messages d'erreur explicites, plus de 403 opaque)
create or replace function public.send_message(
  p_conv uuid, p_kind text, p_body text, p_media text default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_row public.messages;
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if not public.is_member(p_conv) then
    raise exception 'Vous ne faites pas partie de cette conversation';
  end if;
  if p_kind not in ('text','image','voice','drawing','game') then
    raise exception 'Type de message invalide';
  end if;
  insert into public.messages (conversation_id, sender_id, kind, body, media_path)
  values (p_conv, v_me, p_kind, p_body, p_media)
  returning * into v_row;
  return v_row;
end $$;

do $$
declare f text;
begin
  foreach f in array array['ensure_notepad()', 'send_message(uuid,text,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
