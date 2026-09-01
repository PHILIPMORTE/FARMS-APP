-- ============================================================================
--  FARMS — MIGRATION 20
--  Farmers may clock in at any time. The window tied to the job's work hours
--  is removed, so a shift is recorded whenever the work actually happens.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

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

  select a.job_id, j.farm_id, j.wage, j.title
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
     daily_wage, time_in, source, recorded_by, task)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me, coalesce(v_app.title, 'Farm work'))
  returning id into v_id;

  return v_id;
end $$;

create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
  v_add numeric(8,2) := 0;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You have not timed in today.';
  end if;

  if v_row.break_started_at is not null then
    v_add := round(extract(epoch from (now() - v_row.break_started_at)) / 60.0, 2);
  end if;

  update attendance
     set time_out = now(),
         break_minutes = coalesce(break_minutes, 0) + greatest(v_add, 0),
         break_started_at = null
   where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PAY PER JOB
-- A completed day earns the full agreed wage whatever the hours. Hours and
-- breaks are still recorded, so the log remains a truthful account of the day,
-- but they no longer scale the pay up or down.
-- ---------------------------------------------------------------------------
create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_hours numeric(6,2);
begin
  if new.time_in is not null and new.time_out is not null then
    v_hours := round(
      (extract(epoch from (new.time_out - new.time_in)) / 3600.0)
      - (coalesce(new.break_minutes, 0) / 60.0), 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage, 2);
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

notify pgrst, 'reload schema';
