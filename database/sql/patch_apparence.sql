-- Lot 11 : médaillons, blocages, discussions publiques (additif)
alter table public.wallets add column if not exists medals numeric not null default 0;
alter table public.conversations add column if not exists is_public boolean not null default false;

create table if not exists public.user_blocks (
  blocker uuid not null references public.profiles(id) on delete cascade,
  blocked uuid not null references public.profiles(id) on delete cascade,
  at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.user_blocks enable row level security;
revoke all on public.user_blocks from anon, authenticated;

create or replace function public.medals_me() returns numeric language sql security definer set search_path = public as $$
  select coalesce((select medals from public.wallets where user_id = auth.uid()), 0)
$$;

create or replace function public.medals_give(p_username text, p_amount numeric) returns numeric language plpgsql security definer set search_path = public as $$
declare u uuid; n numeric;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 1000000 then raise exception 'Quantité invalide'; end if;
  select id into u from public.profiles where lower(username) = lower(regexp_replace(coalesce(p_username,''), '^@', ''));
  if u is null then raise exception 'Utilisateur introuvable'; end if;
  insert into public.wallets(user_id) values (u) on conflict do nothing;
  update public.wallets set medals = greatest(0, medals + p_amount) where user_id = u returning medals into n;
  perform public.log_admin('medaillon', p_username, jsonb_build_object('delta', p_amount));
  return n;
end $$;

create or replace function public.medals_of(p_username text) returns numeric language sql security definer set search_path = public as $$
  select coalesce((select w.medals from public.wallets w join public.profiles p on p.id = w.user_id where lower(p.username) = lower(regexp_replace(coalesce(p_username,''), '^@', ''))), 0)
$$;

create or replace function public.block_set(p_username text, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  select id into u from public.profiles where lower(username) = lower(regexp_replace(coalesce(p_username,''), '^@', ''));
  if u is null then raise exception 'Utilisateur introuvable'; end if;
  if u = auth.uid() then raise exception 'Vous ne pouvez pas vous bloquer vous-même'; end if;
  if p_on then insert into public.user_blocks(blocker, blocked) values (auth.uid(), u) on conflict do nothing;
  else delete from public.user_blocks where blocker = auth.uid() and blocked = u; end if;
end $$;

-- ids masqués pour moi : ceux que j'ai bloqués (mine=true) et ceux qui m'ont bloqué (mine=false)
create or replace function public.blocks_me() returns table(user_id uuid, mine boolean) language sql security definer set search_path = public as $$
  select blocked, true from public.user_blocks where blocker = auth.uid()
  union all select blocker, false from public.user_blocks where blocked = auth.uid()
$$;

create or replace function public.blocks_names() returns table(username text) language sql security definer set search_path = public as $$
  select p.username from public.user_blocks b join public.profiles p on p.id = b.blocked where b.blocker = auth.uid() order by p.username
$$;

create or replace function public.is_blocked_pair(a uuid, b uuid) returns boolean language sql security definer set search_path = public as $$
  select exists(select 1 from public.user_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;

-- aucun message entre deux personnes bloquées (directs) ; discussions publiques : liens limités
create or replace function public.trg_msg_rules() returns trigger language plpgsql security definer set search_path = public as $$
declare cv record; o uuid; b text;
begin
  select kind, is_public into cv from public.conversations where id = new.conversation_id;
  if cv.kind = 'direct' then
    for o in select user_id from public.conversation_members where conversation_id = new.conversation_id and user_id <> new.sender_id loop
      if public.is_blocked_pair(new.sender_id, o) then raise exception 'Message impossible : blocage actif'; end if;
    end loop;
  end if;
  if cv.is_public and new.kind = 'text' and new.body is not null then
    b := regexp_replace(new.body, 'https://rromanou\.github\.io/Communicer/[^\s]*', '', 'gi');
    if b ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|io|ca|fr|me|gg|ly|xyz|app|dev|co)\y)' then
      raise exception 'Discussion publique : seul le lien https://rromanou.github.io/Communicer/ est accepté';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_msg_rules on public.messages;
create trigger trg_msg_rules before insert on public.messages for each row execute function public.trg_msg_rules();

create or replace function public.public_set(p_conv uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
declare cv record;
begin
  select kind, mode into cv from public.conversations where id = p_conv;
  if cv.kind is distinct from 'group' then raise exception 'Seuls les groupes peuvent être publics'; end if;
  if not exists(select 1 from public.conversation_members where conversation_id = p_conv and user_id = auth.uid() and role in ('admin','owner'))
     and public.staff_rank_me() < 4 then raise exception 'Réservé aux administrateurs du groupe'; end if;
  if p_on and cv.mode is distinct from 'clear' then raise exception 'Une discussion publique doit être en mode non chiffré'; end if;
  update public.conversations set is_public = p_on where id = p_conv;
end $$;

create or replace function public.public_list() returns table(id uuid, name text, members bigint, joined boolean) language sql security definer set search_path = public as $$
  select c.id, c.name, (select count(*) from public.conversation_members m where m.conversation_id = c.id),
         exists(select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = auth.uid())
  from public.conversations c where c.is_public order by 3 desc, c.name limit 100
$$;

create or replace function public.public_join(p_conv uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if not exists(select 1 from public.conversations where id = p_conv and is_public) then raise exception 'Discussion introuvable'; end if;
  insert into public.conversation_members(conversation_id, user_id, role) values (p_conv, auth.uid(), 'member') on conflict do nothing;
end $$;

revoke all on function public.medals_me(), public.medals_give(text,numeric), public.medals_of(text), public.block_set(text,boolean), public.blocks_me(), public.blocks_names(), public.is_blocked_pair(uuid,uuid), public.public_set(uuid,boolean), public.public_list(), public.public_join(uuid) from public, anon;
grant execute on function public.medals_me(), public.medals_give(text,numeric), public.medals_of(text), public.block_set(text,boolean), public.blocks_me(), public.blocks_names(), public.public_set(uuid,boolean), public.public_list(), public.public_join(uuid) to authenticated;
