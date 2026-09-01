-- ============================================================================
--  FARMS — MIGRATION 9
--  Let a farmer choose which job they are clocking in for.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- Every job this farmer is currently hired for, so the time clock can offer a
-- choice when they work for more than one farm.
create or replace function public.my_active_jobs()
returns table (
  job_id    uuid,
  job_title text,
  farm_id   uuid,
  farm_name text,
  wage      numeric,
  clocked   boolean
)
language sql stable security definer set search_path = public
as $$
  select j.id,
         j.title,
         f.id,
         f.name,
         j.wage,
         exists (
           select 1 from attendance a
            where a.farmer_id = public.my_profile_id('farmer')
              and a.job_id = j.id
              and a.work_date = current_date
         )
    from job_applications ap
    join job_posts j on j.id = ap.job_id
    join farms f on f.id = j.farm_id
   where ap.farmer_id = public.my_profile_id('farmer')
     and ap.status = 'accepted'
     and coalesce(ap.employment_status, 'active') = 'active'
   order by f.name, j.title;
$$;

grant execute on function public.my_active_jobs() to authenticated;

-- Clock in against a specific job.
create or replace function public.farmer_time_in(p_job_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
     and (p_job_id is null or a.job_id = p_job_id)
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for that job.';
  end if;

  if exists (
    select 1 from attendance
     where farmer_id = v_me and work_date = v_today and time_out is null
  ) then
    raise exception 'You are already timed in. Time out first.';
  end if;

  select id into v_id
    from attendance
   where farmer_id = v_me and work_date = v_today and job_id = v_app.job_id;

  if v_id is not null then
    raise exception 'You have already completed a shift for this job today.';
  end if;

  insert into attendance
    (farm_id, job_id, farmer_id, work_date, status, hours_worked,
     daily_wage, time_in, source, recorded_by)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.farmer_time_in(uuid) to authenticated;

notify pgrst, 'reload schema';
