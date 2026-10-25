-- ============================================================
-- Communicer! — PATCH ADDITIF n°4 (résultat du test de pureté sur le profil)
-- À exécuter APRÈS les patchs précédents. Idempotent.
-- ============================================================
alter table public.profiles add column if not exists purity smallint;
alter table public.profiles add column if not exists purity_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_purity_rng') then
    alter table public.profiles add constraint profiles_purity_rng check (purity is null or purity between 0 and 100);
  end if;
end $$;
grant update (purity, purity_at) on public.profiles to authenticated;
