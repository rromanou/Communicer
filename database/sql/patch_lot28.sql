-- Lot 28 : récompense quotidienne pour les volontaires « écrire en mon nom » (2 jetons par jour où la case est cochée) — additif
alter table public.speak_volunteers add column if not exists last_reward date;
create or replace function public.speak_vol_set(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if coalesce(p_on, false) then
    insert into public.speak_volunteers(user_id, last_reward) values (auth.uid(), current_date) on conflict do nothing;
  else
    perform public.speak_vol_tick();   -- les jours déjà accumulés sont payés avant de décocher
    delete from public.speak_volunteers where user_id = auth.uid();
  end if;
end $$;
-- crédite 2 jetons pour chaque jour complet écoulé depuis le dernier crédit (60 jours au maximum d'un coup)
create or replace function public.speak_vol_tick() returns numeric language plpgsql security definer set search_path = public as $$
declare v public.speak_volunteers; n int; gain numeric := 0;
begin
  if auth.uid() is null then return 0; end if;
  select * into v from public.speak_volunteers where user_id = auth.uid() for update;
  if not found then return 0; end if;
  n := least(greatest(current_date - coalesce(v.last_reward, current_date), 0), 60);
  if n > 0 then
    gain := n * 2;
    perform public.tok_add(auth.uid(), gain, 'Volontaire (écrire en votre nom) : ' || n || ' jour' || case when n > 1 then 's' else '' end, null);
    update public.speak_volunteers set last_reward = current_date where user_id = auth.uid();
  elsif v.last_reward is null then
    update public.speak_volunteers set last_reward = current_date where user_id = auth.uid();
  end if;
  return gain;
end $$;
revoke all on function public.speak_vol_set(boolean), public.speak_vol_tick() from public, anon;
grant execute on function public.speak_vol_set(boolean), public.speak_vol_tick() to authenticated;
notify pgrst, 'reload schema';
