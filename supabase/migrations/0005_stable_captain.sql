-- Captain / Vice-Captain selection — one of each per member per league.
-- Wrapped in RPCs (rather than relying solely on the direct UPDATE policy)
-- so "only one captain" is enforced transactionally instead of racily.

create function public.set_captain(p_league_id uuid, p_horse_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.stables
    where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_id
  ) then
    raise exception 'That horse is not in your stable';
  end if;

  update public.stables set is_captain = false
  where league_id = p_league_id and user_id = auth.uid() and is_captain = true;

  update public.stables set is_captain = true
  where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_id;
end;
$$;

create function public.set_vice_captain(p_league_id uuid, p_horse_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.stables
    where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_id
  ) then
    raise exception 'That horse is not in your stable';
  end if;

  update public.stables set is_vice_captain = false
  where league_id = p_league_id and user_id = auth.uid() and is_vice_captain = true;

  update public.stables set is_vice_captain = true
  where league_id = p_league_id and user_id = auth.uid() and horse_id = p_horse_id;
end;
$$;

grant execute on function public.set_captain(uuid, uuid) to authenticated;
grant execute on function public.set_vice_captain(uuid, uuid) to authenticated;
