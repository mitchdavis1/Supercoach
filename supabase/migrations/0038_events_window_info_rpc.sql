-- Read-only helper so the client can display the current/next transfer
-- window for an 'events' league without reimplementing AEDT/AEST-aware
-- Monday-10am/Friday-8pm date math in plain JS (which has no timezone
-- library in this project). All the actual timezone arithmetic already
-- lives in events_week_start()/events_window_bounds() — this just packages
-- "today's computed week" plus whether it's currently open for display.
create or replace function public.get_events_window_info(p_league_id uuid)
returns table(week_number int, opens_at timestamptz, closes_at timestamptz, next_opens_at timestamptz, is_open boolean)
language sql
stable
as $$
  select
    public.events_week_number(w.ws),
    b.window_open,
    b.window_close,
    b.window_open + interval '7 days',
    now() >= b.window_open and now() < b.window_close
  from (select public.events_week_start((now() at time zone 'Australia/Melbourne')::date) as ws) w
  cross join lateral public.events_window_bounds(w.ws) b;
$$;
