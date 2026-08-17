# SuperStable — Spring Racing Carnival Fantasy Horse Racing

A multi-user, Supabase-backed fantasy horse racing game. Managers join a
league, win a stable of 10 horses in a live salary-cap auction draft, and
trade horses week to week as real Spring Racing Carnival prizemoney rolls
in.

This is a migration of a single-file localStorage prototype
(`legacy/src-supercoach-v5.html`) into a real backend, per
`legacy/SuperStable_Supabase_Migration_Brief.md`. The rules, draft
economics, scoring, and import logic are unchanged from that prototype —
only the storage layer moved from one browser's localStorage to Supabase
Postgres, with the draft and transfers now server-authoritative so they
work correctly across multiple concurrent leagues and managers.

## Stack

- **Frontend**: static HTML/CSS/vanilla JS (ES modules), no build step.
  `supabase-js` is loaded from a CDN (`esm.sh`), so this deploys as-is to
  GitHub Pages, Vercel, or Netlify — just static file hosting.
- **Backend**: Supabase (Postgres + Auth + Realtime). All business logic
  that needs to be trustworthy (draft clock, bid validation, transfer
  uniqueness) lives in Postgres functions (`supabase/migrations/`), not in
  the client — the client only calls RPCs and reads tables through Row
  Level Security.

## Project layout

```
index.html            Single-page app shell — all pages, hidden/shown via JS
css/styles.css         All styling (ported from the prototype)
js/
  config.js            Your Supabase URL + anon key (edit this)
  supabaseClient.js     Creates the supabase-js client from config.js
  state.js              Shared in-memory app state
  auth.js                Sign up / sign in / sign out (Supabase Auth)
  league.js              Create/join/schedule leagues, realtime membership
  draft.js                Draft room: nominate/bid, realtime, server clock
  stable.js                My Stable: current roster + earnings
  transfers.js              Weekly transfer flow
  scoring.js                 Leaderboard (100% prizemoney earned since acquiring each horse)
  admin-import.js             Horse pool / acceptances / prizemoney import
  inplay.js                    "My Stable — Acceptances" view
  app.js                        Entry point: page router, wires everything
supabase/migrations/    Ordered SQL migrations — schema, RLS, RPCs
legacy/                  The original prototype + migration brief, for reference
```

## Setup

### 1. Create the Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. In the SQL Editor, run each file in `supabase/migrations/` **in order**
   (0001 → 0016, skipping 0005 — removed along with the Captain/VC feature).
   They're plain SQL, so `supabase db push` via the CLI works
   too if you prefer.
3. In Authentication → Providers, email/password should already be enabled
   by default. Decide whether you want "Confirm email" on — if it's on,
   `handleJoin()` in `auth.js` already handles the "check your email"
   case; if it's off, new accounts sign in immediately after creating one.
4. **If "Confirm email" is on**, also set Authentication → URL Configuration
   → **Site URL** to your deployed URL (e.g.
   `https://your-user.github.io/your-repo/`) and add it to **Redirect
   URLs**. Supabase defaults Site URL to `http://localhost:3000`, so
   confirmation emails sent before this is changed will link somewhere
   that doesn't exist — the confirmation itself is still valid, only the
   landing page is wrong. Anyone who signed up before this was set needs a
   fresh confirmation email (or you can flip "Confirm email" off and skip
   this entirely for a small friend league).

### 2. Point the frontend at your project

Edit `js/config.js`:

```js
window.SUPERSTABLE_CONFIG = {
  SUPABASE_URL: 'https://your-project-ref.supabase.co',
  SUPABASE_ANON_KEY: 'your-anon-key',
};
```

Both values are in Project Settings → API. The anon key is safe to ship
client-side — every request it makes still runs through Row Level Security
as the signed-in user.

### 3. Import a horse pool and grant yourself admin

The Data Import (Admin) tab is hidden unless `profiles.is_admin = true`.
After signing up once through the app, promote yourself from the SQL
Editor:

```sql
update public.profiles set is_admin = true where username = 'your-username';
```

Then use the Data Import tab to upload a horse pool spreadsheet (a column
containing "horse" in its header is all that's required) before anyone
tries to start a draft — `start_draft()` will reject an empty pool.

With a large pool (thousands of horses), also use the **Draft Pool
Curation** card to **star** the horses you actually want appearing in the
draft room — either upload a file of names (matched against horses
already in the pool, purely additive — it never creates new horses and
never un-stars anything, so it's safe to re-run with an updated list), or
search the full pool and click ☆ to star individually. A few dozen up to
~100 is typical. Starred horses are what the nomination panel shows by
default (managers can still search the full pool for anything else) and
what auto-nomination draws from when a manager's clock expires; if
nothing is starred it falls back to the whole active pool so the draft
never deadlocks.

The same page has a **Reset League Draft** tool (admin-only) for testing —
enter a league's join code to wipe its drafted horses, stables, and
transfers and reset that league's draft back to idle, without touching the
league or its members.

### 4. Deploy the frontend

It's a static site — no build step. Any of these work:

- **GitHub Pages**: push this repo, enable Pages on the branch/folder.
- **Vercel** / **Netlify**: point either at the repo root, no build
  command needed (or `Output directory: .`).

### 5. Run a draft

1. Create a league (Join A League tab), share its code with your friends.
2. Optionally schedule a draft time — the manager can always start early or
   with no schedule set; everyone else has to wait for the scheduled time.
3. Start Draft. The nominator rotates in join order; nominating a horse
   opens it at a $1 bid in your name; the 20s bid clock resets on every
   raise; a 30s nomination clock auto-nominates a random horse if the
   person on the clock doesn't act in time. Nobody needs to keep a tab open
   for the clock to resolve — every RPC call (anyone bidding, nominating,
   or just calling `advance_draft`) checks and resolves an expired clock
   first.

## Design notes / things a future pass should look at

- **Weekly scoring isn't implemented** — this matches the prototype
  exactly (`setLbRound()` was a no-op stub there too). The leaderboard is
  always full-season: banked_earnings plus, for each horse currently held,
  `prizemoney.total_prizemoney` minus that stable row's baseline (what the
  horse had already earned when it joined — see `earnedForStableRow()` in
  `state.js`). A real "Week N" breakdown would need per-week prizemoney
  snapshots, which the source data (a single season-to-date cumulative
  import) doesn't currently provide.
- **Draft clock resolution relies on some client calling an RPC.** Every
  draft-room action self-heals an expired clock first, and any league
  member simply having the draft room open causes a tick every second via
  `advance_draft`. If literally everyone closes their tab mid-lot, the lot
  stays open until someone reconnects. A `pg_cron` job calling
  `advance_draft()` for in-progress leagues on a short interval would make
  this fully unattended if that matters for your use case.
- **The SQL migrations haven't been run against a live project yet** — they're
  written carefully against the brief and the extracted prototype logic,
  but give the draft flow (start → nominate → bid → timeout → award →
  complete) a real end-to-end runthrough with two accounts before trusting
  it with an actual league.
