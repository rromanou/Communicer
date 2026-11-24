-- Lot 23 : notifications (jetons reçus) — additif
create or replace function public.notif_tokens(p_since bigint default null) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); l bigint;
begin
  if me is null then raise exception 'Non connecté'; end if;
  select coalesce(max(id), 0) into l from public.token_log where user_id = me;
  if p_since is null then return jsonb_build_object('last', l, 'items', '[]'::jsonb); end if;
  return jsonb_build_object('last', l, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'delta', x.delta, 'reason', x.reason, 'at', x.at) order by x.id)
    from (select id, delta, reason, at from public.token_log
           where user_id = me and id > p_since and delta > 0 and reason not like 'reçu de @%'   -- les envois entre membres sont déjà annoncés par @system
           order by id limit 20) x), '[]'::jsonb));
end $$;
revoke all on function public.notif_tokens(bigint) from public, anon;
grant execute on function public.notif_tokens(bigint) to authenticated;

notify pgrst, 'reload schema';
