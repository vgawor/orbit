-- The sign-up trigger runs on its own; nobody should call it directly.
revoke execute on function public.handle_new_user() from public, anon, authenticated;
