-- Admin import for the dated prizemoney ledger (prizemoney_events),
-- parallel to the existing cumulative import_prizemoney() rather than
-- replacing it — AU leagues keep using the cumulative one untouched.
--
-- CSV columns: race_date, venue, race_no, horse, stake. Matches `horse`
-- to the pool the same way every other importer does
-- (normalize_horse_name()), auto-creating a horse that isn't in the pool
-- yet (tagged 'new', same as import_prizemoney()/import_horse_pool() —
-- per Mitch's call to auto-add rather than report-only). Upserts on the
-- (race_date, venue, race_no, horse_id) unique key, so re-importing an
-- overlapping date range or an amended result (protest/DQ changing a
-- stake) is always safe — never a silent drop.
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
  ensured as (
    insert into public.horses (name, tags)
    select distinct v.name, array['new'] from valid v
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
    )
    returning name
  ),
  matched as (
    select v.*, h.id as horse_id
    from valid v
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
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

-- Admin testing/correction tool: clear events in a date range (e.g. to
-- wipe a bad scrape and re-import it) without touching anything outside
-- that range.
create or replace function public.clear_prizemoney_events(p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_count int;
begin
  perform public.require_admin();

  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a valid from/to date range';
  end if;

  delete from public.prizemoney_events where race_date >= p_from and race_date <= p_to;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;
