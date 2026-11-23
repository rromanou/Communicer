-- ============================================================
-- Communicer! — PATCH ADDITIF n°3 (messages éphémères, description de profil, statistiques de jeux)
-- À exécuter APRÈS supabase.sql, patch_jeux.sql et patch_jeux2.sql. Idempotent.
-- ============================================================

-- 1) Description de profil (300 caractères maximum)
alter table public.profiles add column if not exists bio text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_bio_len') then
    alter table public.profiles add constraint profiles_bio_len check (bio is null or char_length(bio) <= 300);
  end if;
end $$;

grant update (bio) on public.profiles to authenticated;

-- 2) Messages éphémères : date d'expiration, invisibles dès qu'elle est passée
alter table public.messages add column if not exists expires_at timestamptz;
create index if not exists messages_exp_idx on public.messages (expires_at) where expires_at is not null;

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    public.is_member(conversation_id)
    and (expires_at is null or expires_at > now())
    and created_at > coalesce(
      (select cm.cleared_at from public.conversation_members cm
        where cm.conversation_id = messages.conversation_id and cm.user_id = auth.uid()),
      '-infinity'::timestamptz)
  );

-- send_message accepte maintenant une durée de vie (secondes) facultative
drop function if exists public.send_message(uuid, text, text, text);
create or replace function public.send_message(
  p_conv uuid, p_kind text, p_body text, p_media text default null, p_ttl int default null)
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
  if p_ttl is not null and (p_ttl < 1 or p_ttl > 86400) then
    raise exception 'Durée invalide (1 s à 24 h)';
  end if;
  insert into public.messages (conversation_id, sender_id, kind, body, media_path, expires_at)
  values (p_conv, v_me, p_kind, p_body, p_media,
          case when p_ttl is null then null else now() + make_interval(secs => p_ttl) end)
  returning * into v_row;
  return v_row;
end $$;

-- Suppression définitive des messages expirés (appelée par les clients)
create or replace function public.purge_expired_messages()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  delete from public.messages m
   where m.expires_at is not null and m.expires_at <= now()
     and public.is_member(m.conversation_id);
  get diagnostics n = row_count;
  return n;
end $$;

-- 3) Statistiques de jeux (taux de victoire, temps moyen avant victoire)
create table if not exists public.game_stats (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  game       text not null check (game ~ '^[a-z0-9_]{2,24}$'),
  played     int  not null default 0,
  wins       int  not null default 0,
  win_secs   bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, game)
);
alter table public.game_stats enable row level security;
drop policy if exists game_stats_select on public.game_stats;
create policy game_stats_select on public.game_stats for select to authenticated using (true);
grant select on public.game_stats to authenticated;

create or replace function public.record_game(p_game text, p_won boolean, p_secs int)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); s int := greatest(0, least(coalesce(p_secs, 0), 86400));
begin
  if v_me is null then raise exception 'Non connecté'; end if;
  if p_game is null or p_game !~ '^[a-z0-9_]{2,24}$' then raise exception 'Jeu invalide'; end if;
  insert into public.game_stats (user_id, game, played, wins, win_secs)
  values (v_me, p_game, 1, case when p_won then 1 else 0 end, case when p_won then s else 0 end)
  on conflict (user_id, game) do update
    set played = game_stats.played + 1,
        wins = game_stats.wins + case when p_won then 1 else 0 end,
        win_secs = game_stats.win_secs + case when p_won then s else 0 end,
        updated_at = now();
end $$;

do $$
declare f text;
begin
  foreach f in array array['send_message(uuid,text,text,text,int)', 'purge_expired_messages()', 'record_game(text,boolean,int)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
