-- Lot 30 : jetons de casino modifiables par les administrateurs, siège derrière le croupier interdit — additif, relançable
create or replace function public.admin_chips(p_username text, p_amount numeric, p_reason text) returns numeric language plpgsql security definer set search_path = public as $$
declare v uuid; b numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000000 or p_amount <> round(p_amount) then raise exception 'Montant invalide (entier non nul, 100 000 000 au maximum)'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Raison obligatoire'; end if;
  perform public.rate_ok('admin_chips', 60, 600);
  v := public.staff_id_of(p_username);
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  insert into public.casino_chips(user_id) values (v) on conflict do nothing;
  select chips into b from public.casino_chips where user_id = v for update;
  if p_amount < 0 and b + p_amount < 0 then raise exception 'Solde de casino insuffisant pour ce retrait'; end if;
  update public.casino_chips set chips = chips + p_amount where user_id = v returning chips into b;
  perform public.log_admin(case when p_amount > 0 then 'jetons_casino_donnes' else 'jetons_casino_retires' end, p_username, jsonb_build_object('montant', p_amount, 'raison', p_reason));
  return b;
end $$;
create or replace function public.admin_chips_get(p_username text) returns numeric language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if public.staff_rank_me() < 2 then raise exception 'Réservé aux administrateurs'; end if;
  return coalesce((select chips from public.casino_chips where user_id = public.staff_id_of(p_username)), 0);
end $$;
revoke all on function public.admin_chips(text, numeric, text), public.admin_chips_get(text) from public, anon;
grant execute on function public.admin_chips(text, numeric, text), public.admin_chips_get(text) to authenticated;

-- le siège 5 est derrière le croupier : on ne peut pas le choisir
create or replace function public.casino_join(p_table bigint, p_seat int default null, p_buyin numeric default null) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; me public.casino_seats; sn int; b numeric; un text; other record; bmin numeric; bmax numeric;
begin
  perform public.rate_ok('casino_join', 60, 60);
  select * into t from public.casino_tables where id = p_table;
  if not found then raise exception 'Table introuvable'; end if;
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  select * into me from public.casino_seats where table_id = p_table and user_id = uid;
  if found then
    -- déjà assis ici : recharge de jetons au poker entre deux mains
    if t.game = 'poker' and p_buyin is not null then
      if me.status in ('active', 'allin') then raise exception 'Phase incorrecte'; end if;
      b := floor(p_buyin);
      if b <= 0 or me.stack + b > _casino_ccn('poker_buyin_max') then raise exception 'Mise hors limites'; end if;
      perform _casino_move(uid, -b, 'casino : recharge ' || t.name);
      update public.casino_seats set stack = stack + b, seen_at = _casino_now() where table_id = p_table and seat = me.seat;
      perform _casino_touch(p_table);
      perform _pk_kick(p_table);
    end if;
    return jsonb_build_object('seat', me.seat);
  end if;
  -- déjà assis ailleurs : on quitte l'autre table d'abord
  select * into other from public.casino_seats where user_id = uid;
  if found then
    perform _casino_lock(other.table_id);
    perform _casino_drop_seat(other.table_id, other.seat);
  end if;
  if p_seat is null then sn := _casino_free_seat(p_table);
  else
    if p_seat < 0 or p_seat > 9 or p_seat = 5 then raise exception 'Place invalide'; end if;
    if exists(select 1 from public.casino_seats where table_id = p_table and seat = p_seat) then raise exception 'Place déjà prise'; end if;
    sn := p_seat;
  end if;
  if sn is null then raise exception 'Table pleine'; end if;
  b := 0;
  if t.game = 'poker' then
    bmin := _casino_ccn('poker_buyin_min'); bmax := _casino_ccn('poker_buyin_max');
    b := floor(coalesce(p_buyin, bmin));
    if b < bmin or b > bmax then raise exception 'Mise hors limites'; end if;
    perform _casino_move(uid, -b, 'casino : quitte-ou-double ' || t.name);
  end if;
  select username into un from public.profiles where id = uid;
  insert into public.casino_seats(table_id, seat, kind, user_id, name, look, stack, status, seen_at)
    values (p_table, sn, 'human', uid, coalesce(un, 'joueur'), _casino_look(uid), b, 'waiting', _casino_now());
  perform _casino_log(p_table, coalesce(un, 'joueur') || ' s’assoit.');
  perform _casino_touch(p_table);
  perform _casino_wake(p_table);
  return jsonb_build_object('seat', sn);
end $$;
notify pgrst, 'reload schema';
