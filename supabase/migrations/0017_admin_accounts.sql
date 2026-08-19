-- Admin visibility into signed-up accounts, and a fix for the most common
-- way someone gets stuck: they never confirmed their email. That produces
-- exactly this pattern — auth.signUp() correctly refuses to recreate an
-- account for an email that already exists (even unconfirmed), while
-- signInWithPassword() is blocked until the email is confirmed, and the
-- app deliberately shows the same generic error for any sign-in failure
-- (see handleSignIn() in auth.js) — so from the outside it looks like
-- "the account exists AND doesn't exist" with no clue that confirmation
-- is the actual blocker. Force-confirming unblocks sign-in immediately
-- with the password the person already set — no reset email needed, and
-- no dependency on their inbox/spam filter/corporate mail scanner ever
-- delivering or them ever clicking a link.
--
-- auth.users isn't part of the exposed PostgREST schema, so both of these
-- have to be SECURITY DEFINER functions in public to reach it at all.

create function public.admin_list_accounts()
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
  select p.id, p.username, p.display_name, u.email, p.is_admin, p.created_at, u.email_confirmed_at, u.last_sign_in_at
  from public.profiles p
  join auth.users u on u.id = p.id
  order by p.created_at desc;
end;
$$;

create function public.admin_confirm_email(p_user_id uuid)
returns void
language plpgsql
security definer set search_path = public, auth
as $$
begin
  perform public.require_admin();

  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now())
  where id = p_user_id;
end;
$$;

grant execute on function public.admin_list_accounts() to authenticated;
grant execute on function public.admin_confirm_email(uuid) to authenticated;
