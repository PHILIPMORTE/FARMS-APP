-- ============================================================================
--  FARMS — MIGRATION 2, STEP 1 of 2  (enums only)
--  Adds: administrator role, farm owner verification, attendance log,
--  order status tracking, stock editing with an audit trail.
--
--  Run this FIRST, on its own, then run migration-2b.sql.
--  Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------- enums ----
-- Postgres cannot add enum values inside a transaction block that also uses
-- them, so these run first and separately.
alter type user_role   add value if not exists 'admin';
alter type notif_type  add value if not exists 'verification';
alter type notif_type  add value if not exists 'order_status';
alter type notif_type  add value if not exists 'stock';

do $$ begin
  create type verification_status as enum ('pending','approved','rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type attendance_status as enum ('present','absent','half_day','leave');
exception when duplicate_object then null; end $$;

-- Shopee-style order lifecycle.
do $$ begin
  create type order_stage as enum (
    'placed','confirmed','preparing','ready','shipped','delivered','completed','cancelled'
  );
exception when duplicate_object then null; end $$;

-- Step 1 finished. Now run migration-2b.sql.
