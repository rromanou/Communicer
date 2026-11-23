-- ============================================================
-- Communicer! — PATCH ADDITIF n°2 (supprimer discussions, annuler demandes)
-- À exécuter APRÈS supabase.sql et patch_jeux.sql. Idempotent.
-- ============================================================

-- 1) Suppression "pour moi" : horodatage par membre
alter table public.conversation_members add column if not exists cleared_at timestamptz;

-- 2) Les messages antérieurs à la suppression ne sont plus lisibles par ce membre
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    public.is_member(conversation_id)
    and created_at > coalesce(
      (select cm.cleared_at from public.conversation_members cm
        where cm.conversation_id = messages.conversation_id and cm.user_id = auth.uid()),
      '-infinity'::timestamptz)
  );

-- 3) Supprimer une discussion (pour moi). Groupe : on quitte le groupe.
create or replace function public.delete_conversation(p_conv uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_c public.conversations%rowtype;
begin
  if not public.is_member(p_conv) then raise exception 'Accès refusé'; end if;
  select * into v_c from public.conversations where id = p_conv;
  if v_c.kind = 'group' then
    perform public.leave_conversation(p_conv);
    return 'left';
  end if;
  if v_c.kind = 'self' then
    delete from public.messages where conversation_id = p_conv;
    return 'cleared';
  end if;
  update public.conversation_members set cleared_at = clock_timestamp()
   where conversation_id = p_conv and user_id = v_me;
  -- plus personne n'a rien à lire : on supprime pour de bon
  if not exists (
    select 1 from public.conversation_members cm
     where cm.conversation_id = p_conv
       and (cm.cleared_at is null or cm.cleared_at < v_c.last_message_at)
  ) then
    delete from public.conversations where id = p_conv;
    return 'deleted';
  end if;
  return 'hidden';
end $$;

-- 4) Annuler une demande d'ami envoyée
create or replace function public.cancel_friend_request(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.friendships
                  where id = p_id and requester = auth.uid() and status = 'pending') then
    raise exception 'Demande introuvable';
  end if;
  delete from public.friendships where id = p_id;
end $$;

do $$
declare f text;
begin
  foreach f in array array['delete_conversation(uuid)','cancel_friend_request(bigint)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
