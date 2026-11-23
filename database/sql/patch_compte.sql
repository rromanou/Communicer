-- Communicer! — patch compte : noms interdits, courriel de contact, reprise des clés, envoi de jetons, badges réservés au commandant (additif)
-- Dépend de patch_systeme.sql.

-- ---------- noms interdits ----------
create or replace function public._within1(a text, b text) returns boolean language plpgsql immutable as $$
declare la int := length(a); lb int := length(b); i int := 1;
begin
  if abs(la - lb) > 1 then return false; end if;
  if a = b then return true; end if;
  while i <= la and i <= lb and substr(a, i, 1) = substr(b, i, 1) loop i := i + 1; end loop;
  if la = lb then return substr(a, i + 1) = substr(b, i + 1); end if;
  if la > lb then return substr(a, i + 1) = substr(b, i); end if;
  return substr(a, i) = substr(b, i + 1);
end $$;

create or replace function public.name_forbidden(p_name text) returns boolean language plpgsql immutable as $$
declare n text := lower(coalesce(p_name, '')); w text; ln int; k int; s int; len int; tok text;
  reserved text[] := array['administrateur','administrator','moderateur','moderator','communicer','security','rromanou','official','officiel','verified','support','claudea','claude_a','roman_b','romanb','system','github','verify','alert','staff','equipe','admin','modo','bot','mod'];
  insults text[] := array['connard','connasse','salope','putain','encule','enculer','batard','merde','pedophile','pedo','nazi','hitler','fuck','shit','bitch','asshole','cunt','nigger','nigga','faggot','whore','slut','retard','bastard','dickhead','hure','scheisse','arschloch','fotze','puta','mierda','cabron','pendejo','maricon','coglione','stronzo','vaffanculo','puttana','merda','caralho','filho_da_puta','viado','porra','nique','niquer','tarlouze','pute','negre','bougnoule','salaud','ordure'];
  insshort text[] := array['con','cul','fdp','ntm','pd','tg','cum','sex','xxx','kkk','pute','porn'];
begin
  if n ~ '^(del|user)\[[0-9]+\]$' or n in ('system','staff') then return false; end if;
  n := regexp_replace(translate(n, '013457@$', 'oleastas'), '[^a-z]', '', 'g');
  foreach w in array reserved loop
    ln := length(w);
    if position(w in n) > 0 then return true; end if;
    if ln >= 4 then
      for len in greatest(ln - 1, 1)..(ln + 1) loop
        for s in 1..greatest(length(n) - len + 1, 0) loop
          if public._within1(substr(n, s, len), w) then return true; end if;
        end loop;
      end loop;
    end if;
  end loop;
  foreach w in array insults loop
    if position(replace(w, '_', '') in n) > 0 then return true; end if;
  end loop;
  foreach tok in array regexp_split_to_array(lower(coalesce(p_name, '')), '[^a-z]+') loop
    if tok = any(insshort) then return true; end if;
  end loop;
  return false;
end $$;

create or replace function public.name_check(p_name text) returns boolean language sql immutable as $$ select not public.name_forbidden(p_name) $$;
grant execute on function public.name_check(text) to anon, authenticated;

create or replace function public.trg_name_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.username is distinct from old.username then
    if new.id in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002') then return new; end if;
    if public.name_forbidden(new.username) then raise exception 'Ce nom d’utilisateur n’est pas autorisé'; end if;
  end if;
  return new;
end $$;
drop trigger if exists name_guard on public.profiles;
create trigger name_guard before insert or update of username on public.profiles for each row execute function public.trg_name_guard();

-- ---------- courriel de contact (vérifié et utilisé par la fonction serveur « account-mail ») ----------
create table if not exists public.contact_emails (
  user_id uuid primary key references public.profiles(id) on delete cascade, email text not null,
  verified_at timestamptz, created_at timestamptz not null default now()
);
create unique index if not exists contact_emails_uq on public.contact_emails (lower(email)) where verified_at is not null;
create table if not exists public.email_codes (
  id bigint generated always as identity primary key, user_id uuid, email text not null, purpose text not null check (purpose in ('verify','reset')),
  code_hash text not null, expires_at timestamptz not null, tries int not null default 0, used boolean not null default false, created_at timestamptz not null default now()
);
create index if not exists email_codes_em on public.email_codes (lower(email), created_at desc);
alter table public.contact_emails enable row level security; alter table public.email_codes enable row level security;
revoke all on public.contact_emails, public.email_codes from anon, authenticated;
alter table public.profiles add column if not exists keys_reset_ok boolean not null default false;

create or replace function public.email_get() returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce((select jsonb_build_object('email', regexp_replace(email, '^(.).*(@.*)$', '\1***\2'), 'verified', verified_at is not null) from public.contact_emails where user_id = auth.uid()), jsonb_build_object('email', null, 'verified', false))
$$;
create or replace function public.email_remove() returns void language sql security definer set search_path = public as $$
  delete from public.contact_emails where user_id = auth.uid()
$$;

-- après une réinitialisation de mot de passe, la personne régénère ses clés (les anciennes ne sont plus déchiffrables)
create or replace function public.keys_reset(p_enc text, p_salt text, p_pub jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce((select keys_reset_ok from public.profiles where id = auth.uid()), false) then raise exception 'Réinitialisation non autorisée'; end if;
  insert into public.user_keys(user_id, enc_private_key, salt) values (auth.uid(), p_enc, p_salt)
    on conflict (user_id) do update set enc_private_key = excluded.enc_private_key, salt = excluded.salt;
  update public.profiles set public_key = p_pub, keys_reset_ok = false where id = auth.uid();
end $$;
create or replace function public.keys_reset_pending() returns boolean language sql security definer stable set search_path = public as $$
  select coalesce((select keys_reset_ok from public.profiles where id = auth.uid()), false)
$$;

-- ---------- envoi de jetons (article payant à 2 449) ----------
insert into public.shop_items(code, kind, name, descr, price, sort) values
  ('send_tokens', 'feature', 'Envoi de jetons', 'Permet d’envoyer des jetons à d’autres utilisateurs', 2449, 14)
on conflict (code) do update set kind = excluded.kind, name = excluded.name, descr = excluded.descr, price = excluded.price, sort = excluded.sort;

create or replace function public.tokens_send(p_username text, p_amount numeric) returns numeric language plpgsql security definer set search_path = public as $$
declare v uuid; nm text; me text; b numeric; sent numeric;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  perform public.rate_ok('tsend:' || auth.uid()::text, 20, 3600);
  perform public._need_right(auth.uid(), 'transfer');
  if not exists(select 1 from public.inventory where user_id = auth.uid() and code = 'send_tokens') then raise exception 'Achetez d’abord « Envoi de jetons » dans la boutique'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 or p_amount <> round(p_amount, 1) then raise exception 'Montant invalide (1 à 10 000)'; end if;
  select id, username into v, nm from public.profiles where username = lower(regexp_replace(trim(coalesce(p_username,'')), '^@', ''));
  if v is null then raise exception 'Utilisateur introuvable'; end if;
  if v = auth.uid() then raise exception 'Vous ne pouvez pas vous envoyer des jetons'; end if;
  if public.ban_state(v) ->> 'banned' = 'true' then raise exception 'Ce compte est suspendu'; end if;
  select coalesce(sum(-delta), 0) into sent from public.token_log where user_id = auth.uid() and reason like 'envoi à @%' and at > now() - interval '24 hours';
  if sent + p_amount > 20000 then raise exception 'Limite de 20 000 jetons par 24 h'; end if;
  insert into public.wallets(user_id) values (auth.uid()) on conflict do nothing;
  select balance into b from public.wallets where user_id = auth.uid() for update;
  if b < p_amount then raise exception 'Jetons insuffisants'; end if;
  me := (select username from public.profiles where id = auth.uid());
  perform public.tok_add(auth.uid(), -p_amount, 'envoi à @' || nm, auth.uid());
  perform public.tok_add(v, p_amount, 'reçu de @' || me, auth.uid());
  perform public.sys_notify(v, 'Vous avez reçu ' || p_amount::text || ' jetons de @' || me || '.');
  return b - p_amount;
end $$;

-- ---------- badges : seul le commandant en décerne ----------
create or replace function public.admin_badge(p_username text, p_code text, p_give boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if public.staff_rank_me() < 4 then raise exception 'Seul le commandant peut décerner ou retirer des badges'; end if;
  if not exists(select 1 from public.badge_defs where code = p_code) then raise exception 'Badge introuvable'; end if;
  if p_code = 'moderateur' then raise exception 'Le badge Modérateur est automatique'; end if;
  v := public.staff_id_of(p_username);
  if p_give then perform public.badge_grant(v, p_code, auth.uid());
  else delete from public.user_badges where user_id = v and code = p_code; update public.profile_ext set badges = array_remove(badges, p_code) where user_id = v; end if;
  perform public.log_admin(case when p_give then 'badge_donne' else 'badge_retire' end, p_username, jsonb_build_object('badge', p_code));
end $$;
create or replace function public.badge_requests_list()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'user', p.username, 'code', r.code, 'note', r.note, 'at', r.created_at) order by r.id) from public.badge_requests r join public.profiles p on p.id = r.user_id where r.status = 'pending'), '[]'::jsonb);
end $$;
create or replace function public.badge_request_decide(p_id bigint, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r public.badge_requests;
begin
  if public.staff_rank_me() < 4 then raise exception 'Seul le commandant peut décider d’une demande de badge'; end if;
  select * into r from public.badge_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Demande introuvable'; end if;
  update public.badge_requests set status = case when p_ok then 'accepted' else 'refused' end, decided_by = auth.uid(), decided_at = now() where id = p_id;
  if p_ok then perform public.badge_grant(r.user_id, r.code, auth.uid()); end if;
  perform public.log_admin(case when p_ok then 'badge_demande_acceptee' else 'badge_demande_refusee' end, (select username from public.profiles where id = r.user_id), jsonb_build_object('badge', r.code));
end $$;

do $$ declare f text; begin foreach f in array array['email_get()','email_remove()','keys_reset(text,text,jsonb)','keys_reset_pending()','tokens_send(text,numeric)'] loop
  execute format('revoke all on function public.%s from public, anon', f); execute format('grant execute on function public.%s to authenticated', f); end loop; end $$;
