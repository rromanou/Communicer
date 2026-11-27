-- Lot 29 : correctifs (bans, IP, fond de profil, casino : jetons de casino séparés, croupier non observable, comptes de substitution du panneau, durcissement) — additif, relançable

-- ---------- 1) fond de profil : liens plus longs acceptés ----------
alter table public.profile_ext drop constraint if exists profile_ext_profile_bg_check;
alter table public.profile_ext add constraint profile_ext_profile_bg_check check (profile_bg is null or (char_length(profile_bg) between 12 and 1000 and profile_bg ~ '^https://[^[:space:]<>"''\\]+$'));
alter table public.profile_ext drop constraint if exists profile_ext_backdrop_check;
alter table public.profile_ext add constraint profile_ext_backdrop_check check (backdrop is null or (char_length(backdrop) between 12 and 1000 and backdrop ~ '^https://[^[:space:]<>"''\\]+$'));
alter table public.profile_ext drop constraint if exists profile_ext_bg_music_check;
alter table public.profile_ext add constraint profile_ext_bg_music_check check (bg_music is null or (char_length(bg_music) between 12 and 1000 and bg_music ~ '^https://[^[:space:]<>"''\\]+$'));

-- ---------- 2) bannissements : état pour soi-même, levée par nom, utilisateurs d'une IP ----------
create or replace function public.ban_me() returns jsonb language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then jsonb_build_object('banned', false) else public.ban_state(auth.uid()) end $$;

create or replace function public.staff_unban_user(p_username text, p_ips boolean default false) returns int language plpgsql security definer set search_path = public as $$
declare v uuid; me int := public.staff_rank_me(); n int := 0; k int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if me < 2 then raise exception 'Réservé aux administrateurs'; end if;
  select id into v from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  update public.site_bans set lifted_at = now(), lifted_by = auth.uid() where user_id = v and lifted_at is null and (until is null or until > now());
  get diagnostics n = row_count;
  if coalesce(p_ips, false) then
    if me < 3 then raise exception 'Seul le chef des administrateurs peut lever un bannissement d’adresse IP'; end if;
    update public.site_bans set lifted_at = now(), lifted_by = auth.uid() where user_id is null and lifted_at is null and (until is null or until > now())
      and ip in (select ip from public.user_ips where user_id = v);
    get diagnostics k = row_count; n := n + k;
  end if;
  perform public.log_admin('deban_utilisateur', p_username, jsonb_build_object('n', n, 'ips', coalesce(p_ips, false)));
  return n;
end $$;

create or replace function public.staff_ip_users(p_ip text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ip text := nullif(trim(coalesce(p_ip,'')), '');
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if public.staff_rank_me() < 3 then raise exception 'Réservé au chef des administrateurs'; end if;
  if v_ip is null or char_length(v_ip) > 64 or v_ip !~ '^[0-9a-fA-F:.]+$' then raise exception 'Adresse IP invalide'; end if;
  perform public.rate_ok('ip_users', 60, 600);
  perform public.log_admin('voir_utilisateurs_ip', v_ip, '{}'::jsonb);
  return coalesce((select jsonb_agg(jsonb_build_object('username', p.username, 'nickname', p.nickname, 'signup', u.is_signup, 'first', u.first_seen, 'last', u.last_seen) order by u.last_seen desc)
    from public.user_ips u join public.profiles p on p.id = u.user_id where u.ip = v_ip), '[]'::jsonb);
end $$;

-- ---------- 3) casino : jetons de casino séparés des jetons du compte ----------
create table if not exists public.casino_chips (user_id uuid primary key references public.profiles(id) on delete cascade, chips numeric not null default 0 check (chips >= 0));
alter table public.casino_chips enable row level security; revoke all on public.casino_chips from anon, authenticated;

create or replace function public._casino_move(p_user uuid, p_delta numeric, p_reason text) returns numeric language plpgsql security definer set search_path = public, extensions as $$
declare b numeric;
begin
  insert into public.casino_chips(user_id) values (p_user) on conflict do nothing;
  select chips into b from public.casino_chips where user_id = p_user for update;
  if p_delta < 0 and coalesce(b, 0) < -p_delta then raise exception 'Solde insuffisant : convertissez des jetons du compte en jetons de casino'; end if;
  update public.casino_chips set chips = chips + p_delta where user_id = p_user returning chips into b;
  return b;
end $$;

create or replace function public.casino_chips_me() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Non connecté'; end if;
  return jsonb_build_object('chips', coalesce((select chips from public.casino_chips where user_id = uid), 0), 'tokens', coalesce((select balance from public.wallets where user_id = uid), 0));
end $$;

create or replace function public.casino_exchange(p_dir text, p_amount numeric) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); a numeric := floor(coalesce(p_amount, 0)); tb numeric;
begin
  if uid is null then raise exception 'Non connecté'; end if;
  if (public.ban_state(uid)->>'banned')::boolean then raise exception 'Compte suspendu'; end if;
  if a < 1 or a > 10000000 then raise exception 'Montant invalide'; end if;
  perform public.rate_ok('casino_xchg', 60, 60);
  insert into public.wallets(user_id) values (uid) on conflict do nothing;
  insert into public.casino_chips(user_id) values (uid) on conflict do nothing;
  select balance into tb from public.wallets where user_id = uid for update;
  if p_dir = 'in' then
    if coalesce(tb, 0) < a then raise exception 'Jetons du compte insuffisants'; end if;
    perform public.tok_add(uid, -a, 'casino : conversion en jetons de casino', null);
    update public.casino_chips set chips = chips + a where user_id = uid;
  elsif p_dir = 'out' then
    perform 1 from public.casino_chips where user_id = uid for update;
    if (select chips from public.casino_chips where user_id = uid) < a then raise exception 'Jetons de casino insuffisants'; end if;
    update public.casino_chips set chips = chips - a where user_id = uid;
    perform public.tok_add(uid, a, 'casino : conversion en jetons du compte', null);
  else raise exception 'Sens invalide'; end if;
  return public.casino_chips_me();
end $$;

create or replace function public._casino_uid() returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if (public.ban_state(auth.uid())->>'banned')::boolean then raise exception 'Compte suspendu'; end if;
  return auth.uid();
end $$;

create or replace function public._casino_me(p_t public.casino_tables, p_uid uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.casino_seats; w numeric;
begin
  select chips into w from public.casino_chips where user_id = p_uid;
  select * into s from public.casino_seats where table_id = p_t.id and user_id = p_uid;
  return jsonb_build_object('seat', case when found then s.seat end, 'wallet', coalesce(w, 0), 'stack', case when found then s.stack else 0 end,
    'cards', '[]'::jsonb, 'to_act', false, 'peeks', '[]'::jsonb, 'bets', '[]'::jsonb, 'bot_vote', _casino_vote_info(p_t.id, p_uid)) || _casino_me_light(p_t, p_uid);
end $$;

create or replace function public.casino_lobby() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); m int := _casino_members(); w record; games jsonb := '[]'::jsonb; g text; lbl text; tb jsonb; sl jsonb; r record;
begin
  perform public.rate_ok('casino_lobby', 120, 60);
  perform _lot_period_close();
  perform _casino_ensure();
  for r in select distinct table_id from public.casino_seats where kind = 'human' and seen_at < _casino_now() - make_interval(secs => _casino_ccn('seat_idle_s')::double precision) loop
    perform _casino_lock(r.table_id);
    perform _casino_tick(r.table_id);
  end loop;
  select coalesce((select chips from public.casino_chips where user_id = uid), 0) as b, coalesce((select medals from public.wallets where user_id = uid), 0) as md into w;
  foreach g in array array['poker', 'blackjack', 'roulette'] loop
    lbl := case g when 'poker' then 'Poker' when 'blackjack' then 'Blackjack' else 'Roulette' end;
    select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name,
        'humans', (select count(*) from public.casino_seats s where s.table_id = t.id and s.kind = 'human'),
        'bots', (select count(*) from public.casino_seats s where s.table_id = t.id and s.kind = 'bot'),
        'seats', 10, 'phase', t.phase, 'min_bet', t.min_bet, 'max_bet', t.max_bet) order by t.id), '[]'::jsonb) into tb from public.casino_tables t where t.game = g;
    games := games || jsonb_build_array(jsonb_build_object('game', g, 'label', lbl, 'tables', tb));
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'theme', theme, 'min_bet', min_bet, 'max_bet', max_bet) order by id), '[]'::jsonb) into sl from public.casino_slots;
  return jsonb_build_object('members', m, 'per_table', 10, 'balance', w.b, 'tokens', coalesce((select balance from public.wallets where user_id = uid), 0), 'medals', w.md, 'games', games, 'slots', sl, 'lot', _lot_info_json(uid));
end $$;

create or replace function public.slots_spin(p_machine bigint, p_bet numeric) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); m public.casino_slots; st text[]; pay jsonb := (select v from public.casino_slot_cfg where k = 'pay'); bets jsonb := (select v from public.casino_slot_cfg where k = 'bets');
  p int[]; g text[]; l int; ln int[] := _slots_lines(); mult numeric; tot numeric := 0; lines jsonb := '[]'::jsonb; syms text[]; sy text; w numeric; bal numeric; reels jsonb := '[]'::jsonb; c int; r int; n int;
begin
  perform public.rate_ok('casino_slot', _casino_ccn('slot_rate_per_min')::int, 60);
  select * into m from public.casino_slots where id = p_machine;
  if not found then raise exception 'Machine introuvable'; end if;
  if p_bet is null or not bets @> to_jsonb(p_bet) or p_bet < m.min_bet or p_bet > m.max_bet then raise exception 'Mise hors limites'; end if;
  perform _casino_move(uid, -p_bet, 'casino : machine à sous ' || m.name);
  st := array(select jsonb_array_elements_text((select v from public.casino_slot_cfg where k = 'strip')));
  p := array[_casino_rand(20), _casino_rand(20), _casino_rand(20)];
  g := array[st[p[1] % 20 + 1], st[p[2] % 20 + 1], st[p[3] % 20 + 1], st[(p[1] + 1) % 20 + 1], st[(p[2] + 1) % 20 + 1], st[(p[3] + 1) % 20 + 1], st[(p[1] + 2) % 20 + 1], st[(p[2] + 2) % 20 + 1], st[(p[3] + 2) % 20 + 1]];
  for l in 0..4 loop
    syms := array[g[ln[l*6+1] * 3 + ln[l*6+2] + 1], g[ln[l*6+3] * 3 + ln[l*6+4] + 1], g[ln[l*6+5] * 3 + ln[l*6+6] + 1]];
    mult := _slots_pay(syms, pay);
    if mult > 0 then
      w := round(mult * p_bet / 5, 1);
      tot := tot + w;
      sy := coalesce((select s from unnest(syms) s where s <> 'joker' limit 1), 'joker');
      n := case when mult = (pay->>'cherry2')::numeric and not (syms[1] = syms[2] and syms[2] = syms[3]) and sy = 'cherry' and mult < (pay->>'cherry')::numeric then 2 else 3 end;
      lines := lines || jsonb_build_array(jsonb_build_object('line', l + 1, 'symbol', sy, 'n', n, 'pay', w));
    end if;
  end loop;
  if tot > 0 then bal := _casino_move(uid, tot, 'casino : gain machine ' || m.name); else bal := coalesce((select chips from public.casino_chips where user_id = uid), 0); end if;
  perform _casino_bank(p_bet - tot, 'machine ' || m.name);
  for c in 0..2 loop
    reels := reels || jsonb_build_array(jsonb_build_array(g[c + 1], g[c + 4], g[c + 7]));
  end loop;
  return jsonb_build_object('reels', reels, 'win', tot, 'lines', lines, 'balance', bal, 'big', tot >= p_bet * 20);
end $$;

create or replace function public.lot_zim_claim(p_ticket text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets; pl jsonb; bal numeric; prize numeric; cur text;
begin
  perform public.rate_ok('casino_zim', 20, 60);
  t := _lot_find(p_ticket, uid);
  if not t.scr_zim then raise exception 'Grattez d’abord cette zone'; end if;
  if t.zim_claimed then raise exception 'Déjà réclamé'; end if;
  pl := _lot_dec(t.id);
  cur := _lot_zim_code(_lot_zim_slot());
  prize := coalesce((pl->'zim'->>'prize')::numeric, 0);
  update public.casino_tickets set zim_claimed = true where id = t.id;
  if not t.fake and prize > 0 and pl->'zim'->>'code' = cur then
    bal := _casino_move(uid, prize, 'casino : Zimemberg ' || _lot_label(t.no));
    perform _casino_bank(-prize, 'Zimemberg ' || _lot_label(t.no));
    return jsonb_build_object('won', true, 'prize', prize, 'balance', bal, 'penalty', false);
  end if;
  bal := coalesce((select chips from public.casino_chips where user_id = uid), 0);
  if _casino_cc('zim_wrong_penalty') = 'all' and coalesce(bal, 0) > 0 then
    update public.casino_chips set chips = 0 where user_id = uid;
    perform _casino_bank(bal, 'pénalité Zimemberg');
    return jsonb_build_object('won', false, 'prize', 0, 'balance', 0, 'penalty', true);
  end if;
  return jsonb_build_object('won', false, 'prize', 0, 'balance', coalesce(bal, 0), 'penalty', false);
end $$;

create or replace function public.lot_bank(p_ticket text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tickets; pl jsonb; items jsonb := '[]'::jsonb; per public.casino_periods; tok numeric; med numeric; bal numeric; md numeric; free_no int; kind text; amt numeric;
begin
  perform public.rate_ok('casino_bank', 40, 60);
  perform _lot_period_close();
  t := _lot_find(p_ticket, uid);
  if t.fake then
    update public.casino_tickets set confiscated = true where id = t.id;
    return jsonb_build_object('items', '[]'::jsonb, 'balance', (coalesce((select chips from public.casino_chips where user_id = uid), 0)), 'medals', (select medals from public.wallets where user_id = uid), 'fake', true);
  end if;
  pl := _lot_dec(t.id);
  -- Tanhgokrom
  if t.scr_tan and not t.tan_claimed then
    select * into per from public.casino_periods where winner_ticket = t.id and not claimed and not expired for update;
    if found then
      insert into public.casino_pot(delta, reason) values (-per.pot, 'cagnotte versée ' || _lot_label(t.no));
      update public.casino_periods set claimed = true where period = per.period;
      update public.casino_tickets set tan_claimed = true where id = t.id;
      bal := _casino_move(uid, per.pot, 'casino : cagnotte Tanhgokrom ' || _lot_label(t.no));
      items := items || jsonb_build_array(jsonb_build_object('kind', 'tan', 'label', 'Cagnotte Tanhgokrom', 'tokens', per.pot, 'medals', 0, 'free_ticket', null));
    end if;
  end if;
  -- Tomateeom
  if t.scr_tom and not t.tom_claimed and pl->'tom'->'prize'->>'kind' <> 'none' then
    kind := pl->'tom'->'prize'->>'kind'; amt := (pl->'tom'->'prize'->>'amount')::numeric;
    update public.casino_tickets set tom_claimed = true where id = t.id;
    if kind = 'ticket' then
      free_no := _lot_make(uid);
      items := items || jsonb_build_array(jsonb_build_object('kind', 'tom', 'label', 'Billet gratuit', 'tokens', 0, 'medals', 0, 'free_ticket', _lot_label(free_no)));
    else
      bal := _casino_move(uid, amt, 'casino : Tomateeom ' || _lot_label(t.no));
      perform _casino_bank(-amt, 'Tomateeom ' || _lot_label(t.no));
      items := items || jsonb_build_array(jsonb_build_object('kind', 'tom', 'label', amt::bigint || ' jetons', 'tokens', amt, 'medals', 0, 'free_ticket', null));
    end if;
  end if;
  -- Poutinà : seulement si le puzzle était possible ET relié
  if t.scr_pou and t.pou_done and t.pou_solved and not t.pou_claimed and (pl->'pou'->>'possible')::boolean then
    med := (pl->'pou'->>'medals')::numeric;
    update public.casino_tickets set pou_claimed = true where id = t.id;
    insert into public.wallets(user_id) values (uid) on conflict do nothing;
    update public.wallets set medals = medals + med where user_id = uid;
    perform public.tok_add(uid, 0, 'casino : Poutinà ' || med::bigint || ' médaillons ' || _lot_label(t.no), null);
    items := items || jsonb_build_array(jsonb_build_object('kind', 'pou', 'label', med::bigint || ' médaillons', 'tokens', 0, 'medals', med, 'free_ticket', null));
  end if;
  bal := coalesce((select chips from public.casino_chips where user_id = uid), 0); select medals into md from public.wallets where user_id = uid;
  return jsonb_build_object('items', items, 'balance', coalesce(bal, 0), 'medals', coalesce(md, 0), 'fake', false);
end $$;

create or replace function public.casino_cheat_start(p_table bigint, p_seat int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := _casino_uid(); t public.casino_tables; tg public.casino_seats; me public.casino_seats; last_st timestamptz; pidx int; aid bigint; isbot boolean; secs numeric := _casino_ccn('cheat_secs'); need int := _casino_ccn('cheat_need')::int;
begin
  perform public.rate_ok('casino_cheat', 20, 60);
  perform _casino_lock(p_table);
  perform _casino_tick(p_table);
  select * into t from public.casino_tables where id = p_table;
  if not found or t.game <> 'poker' then raise exception 'On ne triche qu’au poker'; end if;
  if p_seat = 10 then raise exception 'Les cartes du croupier ne peuvent pas être observées'; end if;
  if t.phase not in ('preflop', 'flop', 'turn', 'river') then raise exception 'Aucune main en cours'; end if;
  select * into tg from public.casino_seats where table_id = p_table and seat = p_seat;
  if not found or tg.status not in ('active', 'allin') or array_length(tg.cards, 1) is null then raise exception 'Cette personne n’a pas de cartes en jeu'; end if;
  select * into me from public.casino_seats where table_id = p_table and user_id = uid;
  if found and me.seat = p_seat then raise exception 'Vous ne pouvez pas vous observer vous-même'; end if;
  if exists(select 1 from public.casino_cheats where cheater = uid and status = 'running' and ends > _casino_now()) then raise exception 'Une observation est déjà en cours'; end if;
  select max(started) into last_st from public.casino_cheats where cheater = uid;
  if last_st is not null and last_st + make_interval(secs => _casino_ccn('cheat_cooldown_s')::double precision) > _casino_now() then raise exception 'Triche en recharge, patientez'; end if;
  if _casino_ccn('cheat_ignore_block') = 0 and exists(select 1 from public.casino_cheats where cheater = uid and table_id = p_table and hand_no = t.hand_no and target_seat = p_seat and status in ('caught', 'failed')) then
    raise exception 'Vous ne pouvez plus observer cette personne pendant cette partie'; end if;
  select count(*) into pidx from public.casino_peeks where cheater = uid and table_id = p_table and hand_no = t.hand_no and seat = p_seat;
  if pidx >= 2 then raise exception 'Vous connaissez déjà ses deux cartes'; end if;
  isbot := tg.kind in ('bot', 'dealer');
  insert into public.casino_cheats(table_id, hand_no, cheater, cheater_seat, target_seat, target_user, target_bot, need, started, ends, catch_at)
    values (p_table, t.hand_no, uid, me.seat, p_seat, tg.user_id, isbot, need, _casino_now(), _casino_now() + make_interval(secs => secs::double precision),
      case when isbot and _casino_rfloat() < _casino_ccn('cheat_bot_p') then _casino_now() + make_interval(secs => (secs * (0.15 + _casino_rfloat() * 0.8))::double precision) end)
    returning casino_cheats.id into aid;
  perform _casino_touch(p_table);
  return jsonb_build_object('attempt', aid, 'secs', secs::int, 'need', need);
end $$;

do $$ declare f text; begin
  foreach f in array array['ban_me()','staff_unban_user(text,boolean)','staff_ip_users(text)','casino_chips_me()','casino_exchange(text,numeric)'] loop
    execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  revoke all on function public._casino_move(uuid, numeric, text) from public, anon, authenticated;
end $$;

-- ---------- 4) panneau : liste des volontaires, comptes de substitution ----------
create table if not exists public.panel_puppets (user_id uuid primary key references public.profiles(id) on delete cascade, created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now());
alter table public.panel_puppets enable row level security; revoke all on public.panel_puppets from anon, authenticated;

create or replace function public.speak_vol_list() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  perform public.rate_ok('vol_list', 60, 600);
  perform public._panel_log('vol_list', '{}'::jsonb);
  return coalesce((select jsonb_agg(jsonb_build_object('username', p.username, 'nickname', p.nickname, 'since', v.at) order by p.username)
    from public.speak_volunteers v join public.profiles p on p.id = v.user_id), '[]'::jsonb);
end $$;

create or replace function public.panel_puppet_new(p_username text, p_nickname text) returns text language plpgsql security definer set search_path = public as $$
declare un text := lower(regexp_replace(trim(coalesce(p_username,'')), '^@', '')); nk text := nullif(trim(coalesce(p_nickname,'')), ''); v uuid := gen_random_uuid();
  v_inst uuid := coalesce((select id from auth.instances limit 1), '00000000-0000-0000-0000-000000000000');
begin
  perform public._panel_need(2);
  perform public.rate_ok('puppet_new', 10, 3600);
  if un !~ '^[a-z0-9_]{3,20}$' then raise exception 'Nom d’utilisateur invalide (3 à 20 lettres minuscules, chiffres ou _)'; end if;
  if nk is not null and char_length(nk) > 40 then raise exception 'Surnom trop long (40 caractères)'; end if;
  if exists(select 1 from public.profiles where username = un) then raise exception 'Ce nom d’utilisateur existe déjà'; end if;
  if (select count(*) from public.panel_puppets where created_by = auth.uid()) >= 30 then raise exception 'Trop de comptes de substitution'; end if;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v, v_inst, 'authenticated', 'authenticated', 'sub_' || replace(v::text, '-', '') || '@communicer.app', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());
  begin update auth.users set banned_until = 'infinity' where id = v; exception when others then null; end;
  insert into public.profiles(id, username, nickname) values (v, un, nk);
  insert into public.panel_puppets(user_id, created_by) values (v, auth.uid());
  perform public._panel_log('puppet_new', jsonb_build_object('username', un));
  return un;
end $$;

create or replace function public.panel_puppets_list() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._panel_need(2);
  return coalesce((select jsonb_agg(jsonb_build_object('username', p.username, 'nickname', p.nickname, 'by', (select username from public.profiles where id = x.created_by)) order by p.username)
    from public.panel_puppets x join public.profiles p on p.id = x.user_id), '[]'::jsonb);
end $$;

create or replace function public.panel_puppet_say(p_conv uuid, p_username text, p_text text, p_reason text) returns bigint language plpgsql security definer set search_path = public as $$
declare v uuid; m text; mid bigint;
begin
  perform public._panel_need(2);
  perform public.rate_ok('puppet_say', 30, 3600);
  if char_length(trim(coalesce(p_reason,''))) < 10 then raise exception 'Indiquez un motif justifié (10 caractères minimum)'; end if;
  if char_length(trim(coalesce(p_text,''))) not between 1 and 2000 then raise exception 'Message de 1 à 2000 caractères'; end if;
  select x.user_id into v from public.panel_puppets x join public.profiles p on p.id = x.user_id where p.username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Compte de substitution introuvable'; end if;
  select mode into m from public.conversations where id = p_conv; if m is null then raise exception 'Discussion introuvable'; end if;
  if m = 'e2e' then raise exception 'Discussion chiffrée : impossible d’y écrire'; end if;
  insert into public.conversation_members(conversation_id, user_id) values (p_conv, v) on conflict do nothing;
  insert into public.messages(conversation_id, sender_id, kind, body, via) values (p_conv, v, 'text', trim(p_text), 'A') returning messages.id into mid;
  perform public._panel_log('puppet_say', jsonb_build_object('conv', p_conv, 'compte', p_username, 'motif', left(p_reason, 200)));
  return mid;
end $$;

create or replace function public.panel_puppet_drop(p_username text) returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._panel_need(3);
  select x.user_id into v from public.panel_puppets x join public.profiles p on p.id = x.user_id where p.username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Compte de substitution introuvable'; end if;
  delete from auth.users where id = v;
  perform public._panel_log('puppet_drop', jsonb_build_object('username', p_username));
end $$;


-- ---------- 4b) durcissement du panneau : limite d'appels, compte suspendu refusé, journal infalsifiable ----------
create or replace function public._panel_need(p_rank int) returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if (public.ban_state(auth.uid())->>'banned')::boolean then raise exception 'Compte suspendu'; end if;
  if not public._panel_ok(auth.uid()) then raise exception 'Panneau non débloqué'; end if;
  if public.staff_rank_of(auth.uid()) < p_rank then raise exception 'Rang insuffisant'; end if;
end $$;
revoke all on function public._panel_need(int) from public, anon, authenticated;
create or replace function public._panel_log_lock() returns trigger language plpgsql as $$ begin raise exception 'Le journal du panneau ne se modifie pas'; end $$;
drop trigger if exists panel_log_lock on public.panel_log;
create trigger panel_log_lock before update or delete on public.panel_log for each row execute function public._panel_log_lock();

-- ---------- 5) durcissement : toutes les fonctions du panneau, du personnel et d'administration exigent une session ----------
do $$ declare r record; begin
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace = 'public'::regnamespace
     and (p.proname like 'panel\_%' or p.proname like 'speak\_%' or p.proname like 'ui\_layout\_%' or p.proname like 'staff\_%' or p.proname like 'admin\_%') loop
    execute format('revoke all on function %s from public, anon', r.f);
    execute format('grant execute on function %s to authenticated', r.f);
  end loop;
end $$;
notify pgrst, 'reload schema';
