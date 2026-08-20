-- Shorten the "bid exceeds cap" error message so it reads cleanly as a
-- toast/alert; the draft room now also shows the max bid proactively
-- under the bid controls, so the error itself doesn't need to explain the
-- reserve-for-remaining-slots mechanic in full.

create or replace function public.place_bid(p_league_id uuid, p_bid_amount int default null)
returns public.league_draft_state
language plpgsql
security definer set search_path = public
as $$
declare
  v_state public.league_draft_state;
  v_bid int;
  v_max_bid int;
  v_remaining_slots int;
begin
  if not exists (select 1 from public.league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'You are not a member of this league';
  end if;

  perform public.advance_draft_if_expired(p_league_id);

  select * into v_state from public.league_draft_state where league_id = p_league_id for update;

  if v_state.status <> 'bidding' then
    raise exception 'There is no active lot to bid on right now';
  end if;

  if v_state.current_bidder_user_id = auth.uid() then
    raise exception 'You are already the highest bidder on this lot';
  end if;

  select remaining_slots, max_bid into v_remaining_slots, v_max_bid from public.league_budget(p_league_id, auth.uid());

  if v_remaining_slots <= 0 then
    raise exception 'Your stable is already full — you cannot bid on more horses';
  end if;

  v_bid := coalesce(p_bid_amount, v_state.current_bid + 1);

  if v_bid <= v_state.current_bid then
    raise exception 'Your bid must be higher than the current bid of $%', v_state.current_bid;
  end if;

  if v_bid > v_max_bid then
    raise exception 'Bid exceeds remaining cap space — your max is $%', v_max_bid;
  end if;

  update public.league_draft_state set
    current_bid = v_bid,
    current_bidder_user_id = auth.uid(),
    bid_count = v_state.bid_count + 1,
    bid_deadline = case
      when v_state.bid_deadline - now() < interval '10 seconds' then now() + interval '10 seconds'
      else v_state.bid_deadline
    end,
    updated_at = now()
  where league_id = p_league_id
  returning * into v_state;

  return v_state;
end;
$$;
