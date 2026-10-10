-- ============================================================================
--  FARMS — MIGRATION 37
--  Counts of items waiting for the signed-in user, so the navigation can show
--  a badge on the section that needs attention.
--
--  Every count is of work the user must act on, not of records they merely
--  own. A farm owner with forty orders all completed sees no badge.
--
--  Safe to run more than once.
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
begin
  if v_owner is not null then
    select id into v_farm from farms where owner_id = v_owner limit 1;

    return json_build_object(
      -- applicants waiting for a decision
      'owner_jobs', (
        select count(*) from job_applications a
          join job_posts j on j.id = a.job_id
         where j.owner_id = v_owner and a.status = 'pending'),

      -- orders that need the farm owner to act
      'owner_orders', (
        select count(*) from orders o
          join products p on p.id = o.product_id
         where p.farm_id = v_farm
           and o.stage not in ('completed','cancelled')),

      -- wages the worker has confirmed nothing on yet, and shifts still open
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
           and harvest_date <= current_date),

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
    return json_build_object(
      -- applications that have been decided since the farmer last looked
      'farmer_applications', (
        select count(*) from job_applications
         where farmer_id = v_farmer and status = 'accepted'
           and coalesce(employment_status, 'active') = 'active'),

      -- a shift left open
      'farmer_logs', (
        select count(*) from attendance
         where farmer_id = v_farmer and work_date = current_date and time_out is null),

      -- wages sent, awaiting the farmer's confirmation
      'farmer_history', (
        select count(*) from attendance
         where farmer_id = v_farmer and payment_status = 'pending')
    );
  end if;

  if v_buyer is not null then
    return json_build_object(
      'buyer_orders', (
        select count(*) from orders
         where buyer_id = v_buyer and stage not in ('completed','cancelled'))
    );
  end if;

  if v_admin then
    return json_build_object(
      'admin_verifications', (
        select count(*) from owner_verifications where status = 'pending'),
      'admin_requests', (
        select count(*) from admin_requests where status = 'pending')
    );
  end if;

  return '{}'::json;
end $$;

grant execute on function public.nav_badges() to authenticated;

notify pgrst, 'reload schema';
