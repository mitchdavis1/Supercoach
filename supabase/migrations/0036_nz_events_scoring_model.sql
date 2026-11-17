-- ============================================================================
-- NZ SUPERSTABLE: date-based prizemoney ledger + per-league scoring model
-- ============================================================================
-- The AU season's scoring (stables.baseline_prizemoney snapshot + a running
-- league_members.banked_earnings total, measured against a single mutable
-- cumulative prizemoney.total_prizemoney per horse) assumed a prizemoney
-- file would arrive roughly weekly. For the NZ season, Mitch may go 4+
-- weeks between scraper runs while transfers keep happening weekly, so
-- scores need to be computed from dated per-race earnings events and each
-- horse's actual ownership period, not a two-snapshot delta.
--
-- This adds that model alongside the existing one rather than replacing
-- it: existing AU leagues keep running on the untouched legacy path
-- (scoring_model = 'legacy'); new leagues opt into the dated-events path
-- (scoring_model = 'events'). Nothing here touches stables.baseline_prizemoney,
-- league_members.banked_earnings, prizemoney, import_prizemoney(), or
-- process_league_waivers_if_due()'s existing behaviour for 'legacy'
-- leagues — per Mitch's call to archive the AU season as viewable history
-- rather than wipe it.

alter table public.leagues
  add column scoring_model text not null default 'legacy'
    check (scoring_model in ('legacy', 'events'));

-- Game window: the date range inside which an 'events' league's prizemoney
-- events actually count toward scores. Admin-configurable, not
-- hard-coded, since the brief flagged the NZ window (likely 1 Dec - 31
-- Mar) as not yet final. Scoped per-league rather than global in case two
-- 'events' leagues ever run different windows.
create table public.league_game_window (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  window_start date not null,
  window_end date not null,
  check (window_end > window_start)
);

alter table public.league_game_window enable row level security;

create policy "game window is viewable by any authenticated user"
  on public.league_game_window for select
  to authenticated
  using (true);

create policy "admins can manage the game window"
  on public.league_game_window for all
  to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- Per-race, per-horse earnings. Unlike `prizemoney` (a single mutable
-- cumulative total per horse, replaced wholesale on every import), this is
-- an event log: one row per horse per race, dated, so a scraper run any
-- number of weeks after the fact can be reconciled correctly against
-- exactly which manager owned the horse on that date, and an amended
-- result (protest/DQ) just upserts the same row rather than needing a
-- full re-import of every horse's running total.
create table public.prizemoney_events (
  id uuid primary key default gen_random_uuid(),
  race_date date not null,
  venue text not null,
  race_no int not null,
  horse_id uuid not null references public.horses(id),
  stake numeric not null default 0,
  source_updated_at timestamptz not null default now(),
  unique (race_date, venue, race_no, horse_id)
);

create index prizemoney_events_horse_idx on public.prizemoney_events (horse_id);
create index prizemoney_events_date_idx on public.prizemoney_events (race_date);

alter table public.prizemoney_events enable row level security;

create policy "prizemoney events are viewable by any authenticated user"
  on public.prizemoney_events for select
  to authenticated
  using (true);

create policy "admins can manage prizemoney events"
  on public.prizemoney_events for all
  to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- Ownership periods: written alongside (never instead of) the existing
-- `stables` current-roster mutations, by the same draft/waiver functions.
-- `stables` stays the single source of truth for "who currently owns this
-- horse right now" — every page already queries it that way, and rewriting
-- that would be its own large, risky change. This table is purely additive
-- history for scoring an 'events' league, where a manager's score needs to
-- know exactly which race dates fall inside their ownership of a horse —
-- something `stables.acquired_at` alone can't answer once a horse changes
-- hands, since today that row is simply deleted, not closed out with an
-- end date (see stable_history for the AU season's narrower, forward-only
-- equivalent of this problem).
create table public.ownership_periods (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  horse_id uuid not null references public.horses(id),
  start_date date not null,
  end_date date, -- null = still owned
  created_at timestamptz not null default now(),
  check (end_date is null or end_date > start_date)
);

create index ownership_periods_league_horse_idx on public.ownership_periods (league_id, horse_id);
create index ownership_periods_league_user_idx on public.ownership_periods (league_id, user_id);

alter table public.ownership_periods enable row level security;

create policy "ownership periods are viewable by league members"
  on public.ownership_periods for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = ownership_periods.league_id and lm.user_id = auth.uid()
    )
  );

-- No direct insert/update/delete policies: writes happen only inside the
-- SECURITY DEFINER draft/waiver functions, same reasoning as `stables`.
