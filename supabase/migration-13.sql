-- ============================================================================
--  FARMS — MIGRATION 13
--  Work hours on a job post, and a clock-in window tied to them.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.job_posts
  add column if not exists start_time time not null default '06:00',
  add column if not exists end_time   time not null default '15:00';

-- ---------------------------------------------------------------------------
-- A farmer may clock in or out only within one hour either side of the times
-- the farm owner set. Enforced here as well as in the interface, so the window
-- cannot be bypassed by calling the API directly.
-- ---------------------------------------------------------------------------
drop function if exists public.my_active_jobs();

drop function if exists public.farmer_time_in();

create function public.my_active_jobs()
returns table (
  job_id     uuid,
  job_title  text,
  farm_id    uuid,
  farm_name  text,
  wage       numeric,
  start_time time,
  end_time   time,
  clocked    boolean
)
language sql stable security definer set search_path = public
as $$
  select j.id,
         j.title,
         f.id,
         f.name,
         j.wage,
         j.start_time,
         j.end_time,
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

create or replace function public.farmer_time_in(p_job_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
  v_now   time := (now() at time zone 'Asia/Manila')::time;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage, j.start_time, j.end_time, j.title
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

  if v_now < (v_app.start_time - interval '1 hour')
     or v_now > (v_app.start_time + interval '1 hour') then
    raise exception 'You can only time in between % and % for this job.',
      to_char(v_app.start_time - interval '1 hour', 'FMHH12:MI AM'),
      to_char(v_app.start_time + interval '1 hour', 'FMHH12:MI AM');
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

grant execute on function public.farmer_time_in(uuid) to authenticated;

create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
  v_end time;
  v_now time := (now() at time zone 'Asia/Manila')::time;
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

  select end_time into v_end from job_posts where id = v_row.job_id;

  if v_end is not null then
    if v_now < (v_end - interval '1 hour') or v_now > (v_end + interval '1 hour') then
      raise exception 'You can only time out between % and % for this job.',
        to_char(v_end - interval '1 hour', 'FMHH12:MI AM'),
        to_char(v_end + interval '1 hour', 'FMHH12:MI AM');
    end if;
  end if;

  update attendance set time_out = now() where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

grant execute on function public.farmer_time_out() to authenticated;

create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage,
       'start_time', j.start_time, 'end_time', j.end_time)
       from attendance a
       join farms f on f.id = a.farm_id
       left join job_posts j on j.id = a.job_id
      where a.farmer_id = public.my_profile_id('farmer')
        and a.work_date = current_date
        and a.time_out is null
      limit 1),
    'null'::json
  );
$$;

grant execute on function public.my_open_shift() to authenticated;

notify pgrst, 'reload schema';
