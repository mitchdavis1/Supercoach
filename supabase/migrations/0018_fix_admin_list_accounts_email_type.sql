-- Fix: auth.users.email is character varying, not text, but
-- admin_list_accounts() declared its return column as text and selected
-- the column unqualified — RETURN QUERY requires an exact type match,
-- producing "structure of query does not match function result type".

create or replace function public.admin_list_accounts()
returns table (
  id uuid,
  username text,
  display_name text,
  email text,
  is_admin boolean,
  created_at timestamptz,
  email_confirmed_at timestamptz,
  last_sign_in_at timestamptz
)
language plpgsql
security definer set search_path = public, auth
as $$
begin
  perform public.require_admin();

  return query
  select p.id, p.username, p.display_name, u.email::text, p.is_admin, p.created_at, u.email_confirmed_at, u.last_sign_in_at
  from public.profiles p
  join auth.users u on u.id = p.id
  order by p.created_at desc;
end;
$$;
