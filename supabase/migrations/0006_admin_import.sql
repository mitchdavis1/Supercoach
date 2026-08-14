-- Admin data import — set-based equivalents of the prototype's three
-- importers (Horse Pool / Weekly Acceptances / Cumulative Prizemoney).
--
-- The prototype's perf fix (33s -> <100ms at ~8,000 rows) was to stop doing
-- a linear scan per row and instead build a Map keyed by normalized horse
-- name before looping. The equivalent here is a single set-based SQL
-- statement per import (a join against a functional index on
-- normalize_horse_name(name)) instead of a client-side per-row round trip —
-- same idea, pushed all the way into one INSERT/UPSERT.
--
-- p_rows is a jsonb array parsed client-side from the uploaded spreadsheet
-- (header/column detection stays a client concern — same keyword regexes as
-- the prototype: /horse/i /trainer/i /venue/i /race/i /prize/i etc.) and
-- passed here already shaped as {name, trainer, key_races[], tags[], notes}
-- / {name, venue, race_number, race_date} / {name, total_prizemoney}.

create function public.normalize_horse_name(p text)
returns text
language sql
immutable
as $$
  select regexp_replace(lower(trim(coalesce(p, ''))), '\s+', ' ', 'g');
$$;

create index horses_normalized_name_idx on public.horses (public.normalize_horse_name(name));

create function public.require_admin()
returns void
language plpgsql
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'Admin access required';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- import_horse_pool — purely additive, matches existing horses by
-- normalized name, creates the rest. Returns {matched, created}.
-- ----------------------------------------------------------------------------

create function public.import_horse_pool(p_rows jsonb)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_created int;
  v_total int;
begin
  perform public.require_admin();

  with input as (
    select
      elem->>'name' as name,
      nullif(elem->>'trainer', '') as trainer,
      nullif(elem->>'notes', '') as notes,
      coalesce((select array_agg(x) from jsonb_array_elements_text(elem->'key_races') x), '{}') as key_races,
      coalesce((select array_agg(x) from jsonb_array_elements_text(elem->'tags') x), '{}') as tags
    from jsonb_array_elements(p_rows) elem
    where coalesce(elem->>'name', '') <> ''
  ),
  deduped as (
    select distinct on (public.normalize_horse_name(name)) *
    from input
  ),
  inserted as (
    insert into public.horses (name, trainer, key_races, tags, notes)
    select d.name, d.trainer, d.key_races,
      case when array_length(d.tags, 1) > 0 then d.tags else array['new'] end,
      d.notes
    from deduped d
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(d.name)
    )
    returning id
  )
  select
    (select count(*) from inserted),
    (select count(*) from input)
  into v_created, v_total;

  return jsonb_build_object('created', v_created, 'matched', v_total - v_created, 'total', v_total);
end;
$$;

-- ----------------------------------------------------------------------------
-- import_acceptances — REPLACES the whole "this week's runners" table.
-- Auto-creates any horse name not already in the pool (no preset price).
-- ----------------------------------------------------------------------------

create function public.import_acceptances(p_rows jsonb)
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
    delete from public.acceptances
  )
  insert into public.acceptances (horse_id, venue, race_number, race_date)
  select horse_id, venue, race_number, race_date from matched;

  get diagnostics v_row_count = row_count;

  return jsonb_build_object('rows_imported', v_row_count);
end;
$$;

-- ----------------------------------------------------------------------------
-- import_prizemoney — REPLACES each horse's cumulative total (never adds).
-- Rows with a zero/unparseable prizemoney value are skipped, exactly like
-- the prototype's `if (!prize) return;` — a horse absent from this import,
-- or present with $0, keeps whatever total it already had.
-- ----------------------------------------------------------------------------

create function public.import_prizemoney(p_rows jsonb)
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
      nullif(regexp_replace(coalesce(elem->>'total_prizemoney', ''), '[^0-9.\-]', '', 'g'), '')::numeric as total_prizemoney
    from jsonb_array_elements(p_rows) elem
    where coalesce(elem->>'name', '') <> ''
  ),
  valid as (
    select * from input where total_prizemoney is not null and total_prizemoney <> 0
  ),
  ensured as (
    insert into public.horses (name, tags)
    select distinct v.name, array['new'] from valid v
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
    )
    returning id, name
  ),
  matched as (
    select v.*, h.id as horse_id
    from valid v
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(v.name)
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
$$;

-- ----------------------------------------------------------------------------
-- reset_imported_data — dev/testing utility, mirrors resetImportedData().
-- Deletes any horse tagged 'new' (i.e. auto-created via import and never
-- given explicit tags) along with its acceptances/prizemoney rows, and
-- clears the rest of the acceptances/prizemoney tables.
-- ----------------------------------------------------------------------------

create function public.reset_imported_data()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  perform public.require_admin();

  delete from public.acceptances;
  delete from public.prizemoney;
  delete from public.horses where tags @> array['new'] and not exists (
    select 1 from public.league_draft_picks p where p.horse_id = horses.id
  );
end;
$$;

grant execute on function public.import_horse_pool(jsonb) to authenticated;
grant execute on function public.import_acceptances(jsonb) to authenticated;
grant execute on function public.import_prizemoney(jsonb) to authenticated;
grant execute on function public.reset_imported_data() to authenticated;
