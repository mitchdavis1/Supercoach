-- Supabase enables pg_safeupdate by default, which rejects any DELETE (or
-- UPDATE) with no WHERE clause at all — even a deliberate "clear the whole
-- table" one — with "DELETE requires a WHERE clause". Three of the
-- REPLACE-the-whole-table import/reset functions do exactly that
-- (import_acceptances, import_futures_odds, reset_imported_data) and hit
-- this the moment they're actually run. Fix: `where true`, which still
-- deletes every row but satisfies the safeguard syntactically.

create or replace function public.import_acceptances(p_rows jsonb)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_row_count int;
begin
  perform public.require_admin();

  with input as (
    select
      elem->>'name' as name,
      nullif(elem->>'venue', '') as venue,
      nullif(elem->>'race_number', '')::int as race_number,
      nullif(elem->>'race_date', '')::date as race_date
    from jsonb_array_elements(p_rows) elem
    where coalesce(elem->>'name', '') <> ''
  ),
  ensured as (
    insert into public.horses (name, tags)
    select distinct i.name, array['new'] from input i
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
    )
    returning id, name
  ),
  matched as (
    select i.*, h.id as horse_id
    from input i
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
  ),
  cleared as (
    delete from public.acceptances where true
  )
  insert into public.acceptances (horse_id, venue, race_number, race_date)
  select horse_id, venue, race_number, race_date from matched;

  get diagnostics v_row_count = row_count;

  return jsonb_build_object('rows_imported', v_row_count);
end;
$$;

create or replace function public.import_futures_odds(p_rows jsonb)
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
    delete from public.futures_odds where true
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

create or replace function public.reset_imported_data()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  perform public.require_admin();

  delete from public.acceptances where true;
  delete from public.prizemoney where true;
  delete from public.futures_odds where true;
  delete from public.horses where tags @> array['new'] and not exists (
    select 1 from public.league_draft_picks p where p.horse_id = horses.id
  );
end;
$$;
