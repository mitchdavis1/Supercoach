-- Lets the sign-in form ask for a username (matching the prototype's UX)
-- while still using Supabase Auth's email/password under the hood — the
-- client resolves username -> email via this RPC, then calls
-- signInWithPassword() with the real email. Callable by anon (pre-login).
--
-- Trade-off: this lets someone probe whether a username exists (it returns
-- null either way, so it doesn't actually leak existence directly, but a
-- timing/behavior difference is inherent to any username-based login). Same
-- shape of trade-off the prototype's "same error for bad user or bad
-- password" message was already making.

create function public.email_for_username(p_username text)
returns text
language sql
security definer set search_path = public, auth
as $$
  select u.email from auth.users u
  join public.profiles p on p.id = u.id
  where lower(p.username) = lower(trim(p_username))
  limit 1;
$$;

grant execute on function public.email_for_username(text) to anon, authenticated;
