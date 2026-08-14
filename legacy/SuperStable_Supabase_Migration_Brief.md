# Spring Racing Carnival SuperStable — Supabase Migration Brief

Handoff spec for moving the prototype (`src-supercoach-v5.html`) from a single-file,
localStorage-based simulation to a real Supabase-backed, multi-user product. Written
for whoever picks this up in Claude Code so the session starts from a real spec
rather than a blank page.

## 1. What exists today (source of truth for behavior)

A single static HTML/CSS/JS file with no backend. Every piece of "shared" state —
accounts, leagues, draft results, stables, transfers, horse pool, prizemoney — lives
in that one browser's `localStorage`. It correctly simulates the *intended* product
flow for one person at a time, but nothing is actually shared between two different
browsers or devices. The migration's job is to make the existing logic real, not to
redesign the product — the rules, scoring, and UX have already been built and tested;
they just need a backend under them.

## 2. The one architectural gap worth fixing during the migration, not after

The current prototype only ever modeled **one draft happening at a time**. In the
real product there will be many leagues running independent drafts simultaneously.
Every table and every piece of draft logic below must be **scoped per league** —
horse availability, the nomination clock, bids, and the resulting stable are all
per-`league_id`, not global. Two unrelated leagues drafting the same horse pool
should never see or affect each other's picks.

## 3. Schema (tables, not exhaustive column lists — Claude Code should finalize types/constraints)

- **`profiles`** — extends Supabase Auth users. `username`, `display_name`.
- **`leagues`** — `code` (unique, shareable), `name`, `manager_user_id`, `scheduled_draft_at`.
- **`league_members`** — `league_id`, `user_id`, `joined_at`. Many-to-many.
- **`horses`** — the global catalog. `name`, `emoji`, `trainer`/`meta`, `key_races`,
  `tags` (array), `notes`, `status` (active/retired/scratched). Populated via the
  admin import tools (see §5) — no preset price field; value is set entirely by
  auction bidding.
- **`league_draft_state`** — one row per league's draft. `status`
  (idle/nominating/bidding/complete), `current_nominator_user_id`,
  `current_lot_horse_id`, `current_bid`, `current_bidder_user_id`, `bid_count`,
  `nomination_deadline`, `bid_deadline`.
- **`league_draft_picks`** — `league_id`, `user_id`, `horse_id`, `price_paid`,
  `picked_at`. This is the durable record of who won what — budgets and "horses
  still available in this league's draft" should be **computed from this table**,
  not stored redundantly, to avoid sync bugs.
- **`stables`** — current roster. `league_id`, `user_id`, `horse_id`, `is_captain`,
  `is_vice_captain`, `paid_price`.
- **`transfers`** — `league_id`, `user_id`, `week_number`, `horse_out_id`,
  `horse_in_id`, `transferred_at`. Enforce "one per user per week" and "no two
  members holding the same horse" with real database constraints (unique index on
  `(league_id, horse_id)` in `stables`), not just client-side checks — this is what
  actually makes "first come, first served" real instead of a race condition.
- **`acceptances`** — this week's runners. `horse_id`, `venue`, `race_number`,
  `race_date`. Each import replaces the current week's rows (matches existing
  "replace, don't merge" behavior).
- **`prizemoney`** — `horse_id`, `total_prizemoney`, `updated_at`. Cumulative
  season-to-date total. **Import replaces the figure, it does not add to it** — this
  was a real bug caught and fixed in the prototype; don't reintroduce it here.

## 4. Realtime requirements

- **Draft room**: every nomination, bid, and clock tick needs to broadcast to all
  connected league members in real time (Supabase Realtime on `league_draft_state`
  and `league_draft_picks`). The nomination/bid countdown timers should be
  server-authoritative (e.g. a scheduled function or checked server-side on each
  action) — client-side `setInterval` timers, as used in the prototype, are fine
  for a solo demo but must not be trusted as the source of truth once multiple
  people can act concurrently.
- **League membership**: new joins should reflect live for everyone already in the
  league (e.g. the manager sees the member list update without refreshing).
- **Transfers**: must be handled as an atomic database transaction/constraint, not
  a client-side check-then-write — that's the only way to make contested transfers
  genuinely first-come-first-served.

## 5. Existing logic to carry over as-is (already built, tested, and correct)

These behaviors were validated against real data during the prototype phase and
should be preserved exactly, just re-hosted server-side:

- **Draft economics**: $100 salary cap, 10 horses per stable, no bench. $1 minimum
  reserve per empty remaining slot (`maxBid = budget - reserve`), flat $1 bid
  increments, $1 opening bids (horses have no preset price).
- **Scoring**: horses score 100% of live prizemoney; Captain scores 2×.
- **Admin data import**: three import types — Horse Pool (bulk names, optional
  trainer/key_races/tags/notes), Weekly Acceptances (replaces current week),
  Cumulative Prizemoney (replaces each horse's total — additive was the bug, see
  §3). Header/column detection is keyword-based (`/horse/i`, `/venue/i`, `/race/i`,
  `/prize/i`) so it tolerates real-world export formats without exact column names.
  At scale (~8,000 rows), matching must use an index/map lookup, not a linear scan
  per row — this was a real perf bug (33s → under 100ms) worth not reintroducing.
- **League/draft gating**: can't start a draft with no league; non-managers can't
  start before a scheduled time; the manager can override and start early or with
  no schedule set at all.

## 6. Auth

Replace the custom localStorage username/password system with Supabase Auth
(email/password is sufficient to start). `profiles.username` becomes the
user-facing display identity; the underlying Auth UID is the real foreign key
everywhere.

## 7. Frontend hosting

Supabase provides the backend only — the static frontend still needs a host.
GitHub Pages, Vercel, or Netlify are all suitable and roughly interchangeable for
this purpose; pick whichever is simplest to wire into the Claude Code deploy flow.

## 8. Suggested build order

1. Supabase project + schema + Auth (email/password)
2. League create/join/schedule, wired to real accounts
3. Draft room — server-authoritative state, realtime broadcast, existing bid/
   nomination logic ported in
4. Stables + My Stable view
5. Transfers, with the DB-level uniqueness constraint doing the real
   first-come-first-served enforcement
6. Admin import tools (horse pool, acceptances, prizemoney) pointed at real tables
7. Deploy frontend, connect to the live project
