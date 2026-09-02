-- ============================================================================
--  FARMS — MIGRATION 23
--  Consent to the Data Privacy Notice is recorded on the account itself, so
--  every route in, including Google sign-in, has to pass through it.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

create or replace function public.accept_privacy_notice()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update profiles
     set privacy_accepted_at = now()
   where user_id = auth.uid()
     and privacy_accepted_at is null;
end $$;

grant execute on function public.accept_privacy_notice() to authenticated;

create or replace function public.my_privacy_accepted()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select privacy_accepted_at is not null
       from profiles where user_id = auth.uid()
      order by created_at limit 1),
    false
  );
$$;

grant execute on function public.my_privacy_accepted() to authenticated;

-- Accounts created before this notice existed are treated as not yet consented,
-- so they are asked the next time they sign in.
notify pgrst, 'reload schema';
