-- ============================================================================
--  FARMS — MIGRATION 29
--  Housekeeping. Two functions were redefined with extra arguments in later
--  migrations, so Postgres now holds both versions. A call that matches both
--  is ambiguous and fails at runtime, so the older ones are dropped.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- add_or_merge_planting: the 6-argument version predates field location.
drop function if exists public.add_or_merge_planting(uuid, crop_type, text, date, numeric, text);

-- add_or_merge_product: the 5-argument version predates milled/unmilled.
drop function if exists public.add_or_merge_product(uuid, text, crop_type, int, numeric);

-- Confirm only one of each remains.
select p.proname,
       pg_get_function_identity_arguments(p.oid) as arguments
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('add_or_merge_planting', 'add_or_merge_product')
 order by p.proname;

notify pgrst, 'reload schema';
