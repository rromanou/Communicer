-- Lot 27 : notifications Android quand l'application est fermée — additif, relançable
-- L'application enregistre un jeton d'appareil (aléatoire, stocké haché). Une tâche Android périodique appelle notif_peek avec ce jeton
-- et reçoit seulement des NOMBRES (messages non lus, demandes d'ami, invitations, jetons) : jamais de contenu, donc rien de lisible en bout en bout.
create table if not exists public.notif_devices (
  token_hash text primary key, user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(), last_peek timestamptz, last_tok bigint);
create index if not exists notif_devices_user on public.notif_devices(user_id);
alter table public.notif_devices enable row level security; revoke all on public.notif_devices from anon, authenticated;

create or replace function public.notif_device_new() returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text; l bigint;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('notif_dev', 10, 3600);
  delete from public.notif_devices where user_id = auth.uid() and token_hash in (select token_hash from public.notif_devices where user_id = auth.uid() order by created_at desc offset 4);
  t := encode(extensions.gen_random_bytes(32), 'hex');
  select coalesce(max(id), 0) into l from public.token_log where user_id = auth.uid();
  insert into public.notif_devices(token_hash, user_id, last_tok) values (encode(extensions.digest(t, 'sha256'), 'hex'), auth.uid(), l);
  return t;
end $$;
create or replace function public.notif_device_drop(p_token text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.notif_devices where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
end $$;

-- appelée par Android, sans session : le jeton d'appareil fait foi
create or replace function public.notif_peek(p_token text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d public.notif_devices; m bigint; f bigint; i bigint; tk numeric; l bigint;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false); end if;
  perform public.rate_ok_ip('notif_peek', 120, 3600);
  select * into d from public.notif_devices where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') for update;
  if not found then return jsonb_build_object('ok', false); end if;
  select count(*) into m from public.messages x join public.conversation_members cm on cm.conversation_id = x.conversation_id and cm.user_id = d.user_id
   where x.sender_id <> d.user_id and x.created_at > cm.last_read_at and x.created_at > now() - interval '3 days';
  select count(*) into f from public.friendships where addressee = d.user_id and status = 'pending';
  select count(*) into i from public.group_invites where invitee = d.user_id;
  select coalesce(max(id), 0) into l from public.token_log where user_id = d.user_id;
  select coalesce(sum(delta), 0) into tk from public.token_log where user_id = d.user_id and id > coalesce(d.last_tok, l) and delta > 0 and reason not like 'reçu de @%';
  update public.notif_devices set last_peek = now(), last_tok = l where token_hash = d.token_hash;
  return jsonb_build_object('ok', true, 'msgs', m, 'friends', f, 'invites', i, 'tokens', case when tk > 0 then 1 else 0 end);
end $$;

revoke all on function public.notif_device_new(), public.notif_device_drop(text), public.notif_peek(text) from public;
grant execute on function public.notif_device_new(), public.notif_device_drop(text) to authenticated;
grant execute on function public.notif_peek(text) to anon, authenticated;
notify pgrst, 'reload schema';
