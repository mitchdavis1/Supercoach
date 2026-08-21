-- Futures markets — admin-imported, optional per horse. A horse can sit in
-- more than one future race's market (e.g. both the Caulfield Cup and the
-- Melbourne Cup), so this is a separate table keyed on (horse_id,
-- race_name) rather than a column on horses/prizemoney. Shown wherever it's
-- useful to see what a horse might be building towards: the draft room's
-- bidding lot (so bidders can weigh it before they buy) and My Stable (a
-- forward-looking view alongside this week's acceptances).
--
-- Import REPLACES the whole table each time, same reasoning as
-- import_acceptances — futures odds move and old markets go stale, so
-- there's no "add to" case that makes sense. Unlike acceptances/prizemoney,
-- it does NOT auto-create unmatched horse names — a futures market only
-- matters for a horse that's already draftable, so an unmatched name is
-- reported back to the admin rather than silently creating a new horse.

create table public.futures_odds (
  id uuid primary key default gen_random_uuid(),
  horse_id uuid not null references public.horses(id) on delete cascade,
  race_name text not null,
  odds numeric,
  updated_at timestamptz not null default now(),
  unique (horse_id, race_name)
);

create index futures_odds_horse_idx on public.futures_odds (horse_id);

alter table public.futures_odds enable row level security;

create policy "futures odds are viewable by any authenticated user"
  on public.futures_odds for select
  to authenticated
  using (true);

-- Writes happen only inside import_futures_odds()'s SECURITY DEFINER transaction.

create function public.import_futures_odds(p_rows jsonb)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row_count int;
  v_unmatched jsonb;
begin
  perform public.require_admin();

  with input as (
    select distinct
      elem->>'name' as name,
      nullif(elem->>'race_name', '') as race_name,
      nullif(regexp_replace(coalesce(elem->>'odds', ''), '[^0-9.]', '', 'g'), '')::numeric as odds
    from jsonb_array_elements(p_rows) elem
    where coalesce(elem->>'name', '') <> '' and coalesce(elem->>'race_name', '') <> ''
  ),
  matched as (
    select i.*, h.id as horse_id
    from input i
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
  ),
  cleared as (
    delete from public.futures_odds
  ),
  inserted as (
    insert into public.futures_odds (horse_id, race_name, odds)
    select horse_id, race_name, odds from matched
    returning 1
  )
  select
    (select count(*) from inserted),
    (select coalesce(jsonb_agg(distinct i.name), '[]'::jsonb) from input i where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
    ))
  into v_row_count, v_unmatched;

  return jsonb_build_object('rows_imported', v_row_count, 'unmatched', v_unmatched);
end;
$$;

grant execute on function public.import_futures_odds(jsonb) to authenticated;

create or replace function public.reset_imported_data()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  perform public.require_admin();

  delete from public.acceptances;
  delete from public.prizemoney;
  delete from public.futures_odds;
  delete from public.horses where tags @> array['new'] and not exists (
    select 1 from public.league_draft_picks p where p.horse_id = horses.id
  );
end;
$$;
