-- Per-horse trade-out ledger, in support of the "My League" teams view
-- showing each manager's no-longer-rostered horses and what they
-- contributed. banked_earnings only ever stored a running SUM — once a
-- horse left a stable there was no record of which horse contributed how
-- much, since baseline_prizemoney was deleted along with the stable row.
-- This adds a permanent, itemized record alongside that same sum, written
-- at the exact same moment inside process_league_waivers_if_due().
--
-- Only covers trades processed from this point forward — a handful of
-- horses traded before this migration existed have no baseline/contribution
-- history left to reconstruct (that data was already gone), so they simply
-- won't appear in the "no longer rostered" list. Not fixable retroactively;
-- acceptable given the season's real data only just started.

create table public.stable_history (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  horse_id uuid not null references public.horses(id),
  contributed_prizemoney numeric not null,
  week_number int not null,
  left_at timestamptz not null default now()
);

create index stable_history_league_user_idx on public.stable_history (league_id, user_id);

alter table public.stable_history enable row level security;

create policy "stable history is viewable by league members"
  on public.stable_history for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = stable_history.league_id and lm.user_id = auth.uid()
    )
  );

-- Writes happen only inside process_league_waivers_if_due()'s SECURITY DEFINER transaction.

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
  v_contributed numeric;
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
            v_contributed := greatest(v_horse_out_total - v_out.baseline_prizemoney, 0);

            delete from public.stables
            where league_id = p_league_id and user_id = v_user and horse_id = v_req.horse_out_id;

            update public.league_members
            set banked_earnings = banked_earnings + v_contributed
            where league_id = p_league_id and user_id = v_user;

            insert into public.stable_history (league_id, user_id, horse_id, contributed_prizemoney, week_number)
            values (p_league_id, v_user, v_req.horse_out_id, v_contributed, v_week.week_number);

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
