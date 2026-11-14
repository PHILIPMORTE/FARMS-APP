-- ============================================================================
-- Migration 49 - the red numbers in the top menu, for logins with more than one role
--
-- PROBLEM
--   One login (one phone) can hold an owner, a farmer and a buyer account.
--   nav_badges() stopped at the FIRST role it found, so a login that was an
--   owner and also a buyer never got the buyer's "Orders" number, and a farmer
--   who was also an admin never got the farmer numbers.
--
-- FIX
--   nav_badges() now returns the numbers for EVERY role the login has. Each
--   number has its own name (owner_market, buyer_orders, ...), so nothing clashes
--   and every menu reads only its own.
--
-- Safe to run more than once. Run after migration-48.
-- ============================================================================

create or replace function public.nav_badges()
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner  uuid := public.my_profile_id('owner');
  v_farmer uuid := public.my_profile_id('farmer');
  v_buyer  uuid := public.my_profile_id('buyer');
  v_admin  boolean := public.is_admin();
  v_farm   uuid;
  v_out    jsonb := '{}'::jsonb;
begin
  if v_owner is not null then
    select id into v_farm from farms where owner_id = v_owner limit 1;

    v_out := v_out || jsonb_build_object(
      -- applicants waiting for a decision
      'owner_jobs', (
        select count(*) from job_applications a
          join job_posts j on j.id = a.job_id
         where j.owner_id = v_owner and a.status = 'pending'),

      -- orders that are still open
      'owner_orders', (
        select count(*) from orders o
          join products p on p.id = o.product_id
         where p.farm_id = v_farm
           and o.stage not in ('completed','cancelled')),

      -- shifts that are finished but not yet paid
      'owner_attendance', (
        select count(*) from attendance
         where farm_id = v_farm
           and (payment_status = 'unpaid' and time_out is not null)),

      -- harvests ready but not yet recorded
      'owner_calendar', (
        select count(*) from schedules
         where farm_id = v_farm
           and status not in ('harvested','cancelled')
           and harvest_date is not null
           and harvest_date <= public.today_ph()),

      -- produce harvested but never listed for sale
      'owner_market', (
        select count(*) from schedules s
         where s.farm_id = v_farm
           and s.status = 'harvested'
           and coalesce(s.actual_sacks, 0) > 0
           and s.listed_product_id is null)
    );
  end if;

  if v_farmer is not null then
    v_out := v_out || jsonb_build_object(
      -- accepted jobs
      'farmer_applications', (
        select count(*) from job_applications
         where farmer_id = v_farmer and status = 'accepted'
           and coalesce(employment_status, 'active') = 'active'),

      -- a shift left open
      'farmer_logs', (
        select count(*) from attendance
         where farmer_id = v_farmer and time_out is null),

      -- wages sent, waiting for the farmer to confirm
      'farmer_history', (
        select count(*) from attendance
         where farmer_id = v_farmer and payment_status = 'pending')
    );
  end if;

  if v_buyer is not null then
    v_out := v_out || jsonb_build_object(
      'buyer_orders', (
        select count(*) from orders
         where buyer_id = v_buyer and stage not in ('completed','cancelled'))
    );
  end if;

  if v_admin then
    v_out := v_out || jsonb_build_object(
      'admin_verifications', (
        select count(*) from owner_verifications where status = 'pending'),
      'admin_requests', (
        select count(*) from admin_requests where status = 'pending')
    );
  end if;

  return v_out::json;
end $$;

grant execute on function public.nav_badges() to authenticated;

notify pgrst, 'reload schema';
