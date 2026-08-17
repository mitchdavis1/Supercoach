-- import_starred_horses — bulk-star a list of names against the EXISTING
-- pool. Matches by normalized name only, like the other importers, but
-- deliberately never inserts new horses (an unmatched name here is almost
-- always a typo against the already-imported pool, not a genuinely new
-- horse) and never un-stars anything already starred — purely additive, so
-- re-running this with an updated file is always safe.

create function public.import_starred_horses(p_rows jsonb)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_total int;
  v_matched int;
  v_newly_starred int;
  v_unmatched jsonb;
begin
  perform public.require_admin();

  with input as (
    select distinct on (public.normalize_horse_name(elem->>'name')) elem->>'name' as name
    from jsonb_array_elements(p_rows) elem
    where coalesce(elem->>'name', '') <> ''
  ),
  matched_horses as (
    select h.id
    from input i
    join public.horses h on public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
  ),
  updated as (
    update public.horses h set is_starred = true, updated_at = now()
    where h.id in (select id from matched_horses) and not h.is_starred
    returning h.id
  ),
  unmatched_names as (
    select i.name
    from input i
    where not exists (
      select 1 from public.horses h where public.normalize_horse_name(h.name) = public.normalize_horse_name(i.name)
    )
  )
  select
    (select count(*) from input),
    (select count(*) from matched_horses),
    (select count(*) from updated),
    coalesce((select jsonb_agg(name order by name) from unmatched_names), '[]'::jsonb)
  into v_total, v_matched, v_newly_starred, v_unmatched;

  return jsonb_build_object(
    'total', v_total,
    'matched', v_matched,
    'newly_starred', v_newly_starred,
    'already_starred', v_matched - v_newly_starred,
    'unmatched', v_unmatched
  );
end;
$$;

grant execute on function public.import_starred_horses(jsonb) to authenticated;
