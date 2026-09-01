-- ============================================================================
--  FARMS — STEP 2: keep one administrator, then apply the constraint.
--
--  This removes the extra admin PROFILES only. The underlying login accounts
--  in auth.users are untouched, so those people can still sign in under their
--  other roles. Only the duplicated admin role is removed.
--
--  Run STEP 1 first if you have not: you may prefer to keep a different one.
-- ============================================================================

delete from public.profiles
 where role = 'admin'
   and id <> (
     select id from public.profiles
      where role = 'admin'
      order by created_at
      limit 1
   );

create unique index if not exists profiles_single_admin
  on public.profiles ((role))
  where role = 'admin';

notify pgrst, 'reload schema';
