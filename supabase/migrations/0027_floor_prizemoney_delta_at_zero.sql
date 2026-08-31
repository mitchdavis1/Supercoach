-- A horse's cumulative prizemoney should only ever increase in reality, but
-- a re-imported (corrected, or in testing simply inconsistent) total lower
-- than what was snapshotted as a stable row's baseline would otherwise bank
-- a negative delta when that horse is traded away — permanently docking a
-- manager's score for prizemoney the horse never actually lost. Floor the
-- banked delta at 0, matching the same floor just applied client-side to
-- earnedForStableRow() for currently-held horses.

create or replace function public.process_league_waivers_if_due(p_league_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_draft_done_at timestamptz;
  v_week record;
  v_order uuid[];
  v_new_order uuid[];
  v_user uuid;
  v_req public.waiver_requests;
  v_out public.stables;
  v_out_found boolean;
  v_horse_out_total numeric;
  v_choice_total numeric;
  v_choice uuid;
  v_awarded uuid;
  i int;
begin
  if not exists (select 1 from public.league_waiver_order where league_id = p_league_id) then
    return;
  end if;

  select max(picked_at) into v_draft_done_at from public.league_draft_picks where league_id = p_league_id;

  for v_week in
    select * from public.season_weeks sw
    where sw.closes_at <= now()
      and (v_draft_done_at is null or sw.opens_at > v_draft_done_at)
      and not exists (
        select 1 from public.league_waiver_runs r
        where r.league_id = p_league_id and r.week_number = sw.week_number
      )
    order by sw.week_number asc
  loop
    select array_agg(user_id order by position) into v_order
    from public.league_waiver_order where league_id = p_league_id;

    if v_order is not null then
      foreach v_user in array v_order loop
        select * into v_req from public.waiver_requests
        where league_id = p_league_id and user_id = v_user and week_number = v_week.week_number and status = 'pending'
        for update;

        if found then
          select * into v_out from public.stables
          where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id
          for update;
          v_out_found := found;

          v_awarded := null;
          foreach v_choice in array array_remove(array[v_req.choice_1_horse_id, v_req.choice_2_horse_id, v_req.choice_3_horse_id], null) loop
            if exists (select 1 from public.horses where id = v_choice and status = 'active')
               and not exists (select 1 from public.stables where league_id = p_league_id and horse_id = v_choice) then
              v_awarded := v_choice;
              exit;
            end if;
          end loop;

          if v_awarded is not null and v_out_found then
            v_horse_out_total := coalesce((select total_prizemoney from public.prizemoney where horse_id = v_req.horse_out_id), 0);
            v_choice_total := coalesce((select total_prizemoney from public.prizemoney where horse_id = v_awarded), 0);

            delete from public.stables
            where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id;

            update public.league_members
            set banked_earnings = banked_earnings + greatest(v_horse_out_total - v_out.baseline_prizemoney, 0)
            where league_id = p_league_id and user_id = v_user;

            insert into public.stables (league_id, user_id, horse_id, paid_price, baseline_prizemoney)
            values (p_league_id, v_user, v_awarded, null, v_choice_total);

            insert into public.transfers (league_id, user_id, week_number, horse_out_id, horse_in_id)
            values (p_league_id, v_user, v_week.week_number, v_req.horse_out_id, v_awarded);

            update public.waiver_requests
            set status = 'fulfilled', resulting_horse_in_id = v_awarded, processed_at = now()
            where id = v_req.id;
          else
            update public.waiver_requests
            set status = 'rejected', processed_at = now()
            where id = v_req.id;
          end if;
        end if;
      end loop;
    end if;

    if v_order is not null and array_length(v_order, 1) > 0 then
      v_new_order := v_order[2:array_length(v_order, 1)] || v_order[1:1];
      for i in 1..array_length(v_new_order, 1) loop
        update public.league_waiver_order
        set position = i
        where league_id = p_league_id and user_id = v_new_order[i];
      end loop;
    end if;

    insert into public.league_waiver_runs (league_id, week_number) values (p_league_id, v_week.week_number);
  end loop;
end;
$$;
