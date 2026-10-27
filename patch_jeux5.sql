-- Patch 5 : sauvegarde de Romanomoney dans le compte (additif, relançable)
create table if not exists public.romanomoney_saves(
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null check (length(code) <= 400000),
  updated_at timestamptz not null default now()
);
alter table public.romanomoney_saves enable row level security;
drop policy if exists rmn_select on public.romanomoney_saves;
drop policy if exists rmn_insert on public.romanomoney_saves;
drop policy if exists rmn_update on public.romanomoney_saves;
create policy rmn_select on public.romanomoney_saves for select to authenticated using (user_id = auth.uid());
create policy rmn_insert on public.romanomoney_saves for insert to authenticated with check (user_id = auth.uid());
create policy rmn_update on public.romanomoney_saves for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.romanomoney_saves to authenticated;
