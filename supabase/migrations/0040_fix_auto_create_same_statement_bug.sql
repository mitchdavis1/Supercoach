-- Fixes a real bug in two already-live importers, found while building
-- import_prizemoney_events() with the same (buggy) pattern it turns out
-- they both already used.
--
-- Postgres evaluates every CTE in a WITH clause against the snapshot
-- taken at the start of the statement — a plain SELECT in one CTE does
-- NOT see rows a sibling CTE just INSERTed earlier in the same statement,
-- unless it reads that sibling's own RETURNING output directly. Both
-- import_prizemoney() and import_acceptances() auto-create a horse that
-- isn't in the pool yet (the `ensured` CTE), then immediately try to
-- resolve its id by re-querying public.horses in a sibling `matched` CTE
-- — which can't see the row `ensured` just inserted. The net effect: a
-- genuinely new horse name gets added to the pool (tagged 'new'), but
-- the prizemoney/acceptance row for it is silently dropped, with no
-- error — exactly the "mystery missing prizemoney" pattern seen this
-- season for a couple of horses that turned out to have been auto-created
-- by one of these imports and never actually received their data.
--
-- Fix: resolve newly-created horses' ids from `ensured`'s own RETURNING
-- rather than re-querying the table, and union that with the
-- already-existed-before-this-import matches.

create or replace function public.import_prizemoney(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row_count int;
begin
  perform public.require_admin();

  with input as (
    select
      elem->>'name' as name,
      nullif(regexp_replace(coalesce(elem->>'total_prizemoney', ''), '[^0-9.\-]', '', 'g'), '')::numeric as total_prizemoney
    from jsonb_array_elements(p_rows) elem
    where coalesce(elem->>'name', '') <> ''
  ),
  valid as (
    select * from input where total_prizemoney is not null and total_prizemoney <> 0
  ),
  existing as (
    select v.*, h.id as horse_id
    from valid v
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
  ),
  to_create as (
    select distinct v.name from valid v
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
    )
  ),
  ensured as (
    insert into public.horses (name, tags)
    select name, array['new'] from to_create
    returning id, name
  ),
  newly_matched as (
    select v.*, e.id as horse_id
    from valid v
    join ensured e on public.normalize_horse_name(e.name) = public.normalize_horse_name(v.name)
  ),
  matched as (
    select * from existing
    union all
    select * from newly_matched
  ),
  upserted as (
    insert into public.prizemoney (horse_id, total_prizemoney, updated_at)
    select horse_id, total_prizemoney, now() from matched
    on conflict (horse_id) do update set
      total_prizemoney = excluded.total_prizemoney,
      updated_at = now()
    returning horse_id
  )
  select count(*) into v_row_count from upserted;

  return jsonb_build_object('rows_imported', v_row_count);
end;
$function$;

create or replace function public.import_acceptances(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  existing as (
    select i.*, h.id as horse_id
    from input i
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
  ),
  to_create as (
    select distinct i.name from input i
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
    )
  ),
  ensured as (
    insert into public.horses (name, tags)
    select name, array['new'] from to_create
    returning id, name
  ),
  newly_matched as (
    select i.*, e.id as horse_id
    from input i
    join ensured e on public.normalize_horse_name(e.name) = public.normalize_horse_name(i.name)
  ),
  matched as (
    select * from existing
    union all
    select * from newly_matched
  ),
  cleared as (
    delete from public.acceptances where true
  )
  insert into public.acceptances (horse_id, venue, race_number, race_date)
  select horse_id, venue, race_number, race_date from matched;

  get diagnostics v_row_count = row_count;

  return jsonb_build_object('rows_imported', v_row_count);
end;
$function$;

create or replace function public.import_prizemoney_events(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_inserted int;
  v_updated int;
  v_created jsonb;
begin
  perform public.require_admin();

  with input as (
    select
      nullif(elem->>'race_date', '')::date as race_date,
      nullif(trim(elem->>'venue'), '') as venue,
      nullif(regexp_replace(coalesce(elem->>'race_no', ''), '[^0-9]', '', 'g'), '')::int as race_no,
      nullif(trim(elem->>'horse'), '') as name,
      coalesce(nullif(regexp_replace(coalesce(elem->>'stake', ''), '[^0-9.\-]', '', 'g'), ''), '0')::numeric as stake
    from jsonb_array_elements(p_rows) elem
  ),
  valid as (
    select * from input
    where race_date is not null and venue is not null and race_no is not null and name is not null
  ),
  existing as (
    select v.*, h.id as horse_id
    from valid v
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
  ),
  to_create as (
    select distinct v.name from valid v
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
    )
  ),
  ensured as (
    insert into public.horses (name, tags)
    select name, array['new'] from to_create
    returning id, name
  ),
  newly_matched as (
    select v.*, e.id as horse_id
    from valid v
    join ensured e on public.normalize_horse_name(e.name) = public.normalize_horse_name(v.name)
  ),
  matched as (
    select * from existing
    union all
    select * from newly_matched
  ),
  upserted as (
    insert into public.prizemoney_events (race_date, venue, race_no, horse_id, stake, source_updated_at)
    select race_date, venue, race_no, horse_id, stake, now() from matched
    on conflict (race_date, venue, race_no, horse_id) do update set
      stake = excluded.stake,
      source_updated_at = now()
    returning (xmax = 0) as was_insert
  )
  select
    count(*) filter (where was_insert),
    count(*) filter (where not was_insert)
  into v_inserted, v_updated
  from upserted;

  select coalesce(jsonb_agg(name), '[]'::jsonb) into v_created from ensured;

  return jsonb_build_object('rows_inserted', coalesce(v_inserted, 0), 'rows_updated', coalesce(v_updated, 0), 'auto_created_horses', v_created);
end;
$function$;
