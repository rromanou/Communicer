
-- ============================================================
-- Communicer! — PATCH ADDITIF n°4 (CORRIGÉ)
-- Test de pureté du profil
-- Compatible Supabase — Idempotent
-- Run without RLS
-- ============================================================

-- 1. Créer la table profiles si elle n'existe pas.
--    L'identifiant référence l'utilisateur Supabase.
create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade
);

-- 2. Ajouter les colonnes de pureté.
alter table public.profiles
    add column if not exists purity smallint;

alter table public.profiles
    add column if not exists purity_at timestamptz;

-- 3. Ajouter la contrainte de validation.
do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'profiles_purity_rng'
          and conrelid = 'public.profiles'::regclass
    ) then
        alter table public.profiles
            add constraint profiles_purity_rng
            check (purity is null or purity between 0 and 100);
    end if;
end
$$;

-- 4. Autoriser les utilisateurs authentifiés
--    à modifier uniquement les colonnes de pureté.
grant update (purity, purity_at)
on public.profiles
to authenticated;

-- ============================================================
-- FIN DU PATCH
-- ============================================================
