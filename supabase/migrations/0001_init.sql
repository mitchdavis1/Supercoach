-- SuperStable — initial schema
-- Fantasy horse racing game: leagues, per-league salary-cap auction draft,
-- stables, transfers, and admin-imported racing data.
--
-- Run against a fresh Supabase project (SQL editor or `supabase db push`).
-- Requires pgcrypto for gen_random_uuid() — enabled by default on Supabase.

-- ============================================================================
-- PROFILES — extends auth.users
-- ============================================================================

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles are viewable by any authenticated user"
  on public.profiles for select
  to authenticated
  using (true);

create policy "users can update their own profile"
  on public.profiles for update
  to authenticated
  using (id = auth.uid());

create policy "users can insert their own profile"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid());

-- Auto-create a profile row when a new auth user signs up.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================
-- LEAGUES
-- ============================================================================

create table public.leagues (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  manager_user_id uuid not null references public.profiles(id),
  scheduled_draft_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.leagues enable row level security;

create policy "leagues are viewable by any authenticated user"
  on public.leagues for select
  to authenticated
  using (true);

create policy "manager can update their league"
  on public.leagues for update
  to authenticated
  using (manager_user_id = auth.uid());

-- Leagues are created via the create_league() RPC (security definer), not
-- direct inserts, so the manager row and membership stay consistent.

-- ============================================================================
-- LEAGUE MEMBERS
-- ============================================================================

create table public.league_members (
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  team_name text,
  joined_at timestamptz not null default now(),
  primary key (league_id, user_id)
);

alter table public.league_members enable row level security;

create policy "members are viewable by any authenticated user"
  on public.league_members for select
  to authenticated
  using (true);

create policy "users can update their own membership row"
  on public.league_members for update
  to authenticated
  using (user_id = auth.uid());

create policy "users can leave a league"
  on public.league_members for delete
  to authenticated
  using (user_id = auth.uid());

-- Joining is via the join_league() RPC so the code lookup + insert is atomic.

-- ============================================================================
-- HORSES — global catalog (admin-managed)
-- ============================================================================

create table public.horses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  emoji text default '🐎',
  trainer text,
  key_races text[] not null default '{}',
  tags text[] not null default '{}',
  notes text,
  status text not null default 'active' check (status in ('active', 'retired', 'scratched')),
  is_starred boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index horses_name_idx on public.horses using gin (to_tsvector('english', name));
create index horses_status_idx on public.horses (status);
create index horses_starred_idx on public.horses (is_starred) where is_starred;

alter table public.horses enable row level security;

create policy "horses are viewable by any authenticated user"
  on public.horses for select
  to authenticated
  using (true);

create policy "admins can manage horses"
  on public.horses for all
  to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- ============================================================================
-- LEAGUE DRAFT STATE — one row per league, server-authoritative
-- ============================================================================

create table public.league_draft_state (
  league_id uuid primary key references public.leagues(id) on delete cascade,
  status text not null default 'idle' check (status in ('idle', 'nominating', 'bidding', 'complete')),
  nominator_order uuid[] not null default '{}',
  nominator_index int not null default 0,
  current_nominator_user_id uuid references public.profiles(id),
  current_lot_horse_id uuid references public.horses(id),
  current_bid int,
  current_bidder_user_id uuid references public.profiles(id),
  bid_count int not null default 0,
  nomination_deadline timestamptz,
  bid_deadline timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.league_draft_state enable row level security;

create policy "draft state is viewable by league members"
  on public.league_draft_state for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = league_draft_state.league_id and lm.user_id = auth.uid()
    )
  );

-- No direct insert/update/delete policies: all writes go through
-- security-definer RPCs (start_draft, nominate_horse, place_bid, advance_draft)
-- so the clock and turn order can never be forged by a client.

-- ============================================================================
-- LEAGUE DRAFT PICKS — durable record of who won what, per league
-- ============================================================================

create table public.league_draft_picks (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  horse_id uuid not null references public.horses(id),
  price_paid int not null check (price_paid > 0),
  picked_at timestamptz not null default now(),
  unique (league_id, horse_id)
);

create index league_draft_picks_league_user_idx on public.league_draft_picks (league_id, user_id);

alter table public.league_draft_picks enable row level security;

create policy "draft picks are viewable by league members"
  on public.league_draft_picks for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = league_draft_picks.league_id and lm.user_id = auth.uid()
    )
  );

-- Writes happen only inside advance_draft()'s SECURITY DEFINER transaction.

-- ============================================================================
-- STABLES — current roster per league/user
-- ============================================================================

create table public.stables (
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  horse_id uuid not null references public.horses(id),
  is_captain boolean not null default false,
  is_vice_captain boolean not null default false,
  paid_price int, -- what was paid in the draft; null once transferred (transfers carry no $ value)
  acquired_at timestamptz not null default now(),
  primary key (league_id, user_id, horse_id),
  unique (league_id, horse_id) -- a horse can only sit in one member's stable per league
);

create index stables_league_user_idx on public.stables (league_id, user_id);

alter table public.stables enable row level security;

create policy "stables are viewable by league members"
  on public.stables for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = stables.league_id and lm.user_id = auth.uid()
    )
  );

create policy "owners can set captain/vice-captain on their own horses"
  on public.stables for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Horse-in/horse-out writes happen only inside execute_transfer()'s
-- SECURITY DEFINER transaction — that's what makes the unique(league_id,
-- horse_id) constraint actually enforce first-come-first-served.

-- ============================================================================
-- TRANSFERS — weekly log, one per user per week
-- ============================================================================

create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  week_number int not null,
  horse_out_id uuid not null references public.horses(id),
  horse_in_id uuid not null references public.horses(id),
  transferred_at timestamptz not null default now(),
  unique (league_id, user_id, week_number)
);

alter table public.transfers enable row level security;

create policy "transfers are viewable by league members"
  on public.transfers for select
  to authenticated
  using (
    exists (
      select 1 from public.league_members lm
      where lm.league_id = transfers.league_id and lm.user_id = auth.uid()
    )
  );

-- Writes happen only inside execute_transfer().

-- ============================================================================
-- ACCEPTANCES — this week's runners (admin import replaces wholesale)
-- ============================================================================

create table public.acceptances (
  id uuid primary key default gen_random_uuid(),
  horse_id uuid not null references public.horses(id),
  venue text,
  race_number int,
  race_date date,
  created_at timestamptz not null default now()
);

create index acceptances_horse_idx on public.acceptances (horse_id);

alter table public.acceptances enable row level security;

create policy "acceptances are viewable by any authenticated user"
  on public.acceptances for select
  to authenticated
  using (true);

create policy "admins can manage acceptances"
  on public.acceptances for all
  to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- ============================================================================
-- PRIZEMONEY — cumulative season-to-date total per horse
-- ============================================================================

create table public.prizemoney (
  horse_id uuid primary key references public.horses(id),
  total_prizemoney numeric not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.prizemoney enable row level security;

create policy "prizemoney is viewable by any authenticated user"
  on public.prizemoney for select
  to authenticated
  using (true);

create policy "admins can manage prizemoney"
  on public.prizemoney for all
  to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- ============================================================================
-- REALTIME
-- ============================================================================

alter publication supabase_realtime add table
  public.league_draft_state,
  public.league_draft_picks,
  public.league_members;
