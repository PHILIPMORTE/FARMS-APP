-- ============================================================================
--  FARMS — MIGRATION 14
--  Farmers can pause and resume a shift. Break time is subtracted from the
--  hours worked, so pay reflects time actually on the job.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.attendance
  add column if not exists break_started_at timestamptz,
  add column if not exists break_minutes numeric(8,2) not null default 0;

create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_standard numeric(5,2);
  v_hours    numeric(6,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

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
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage * (new.hours_worked / v_standard), 2);
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

create or replace function public.farmer_pause_shift()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
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
    raise exception 'You are not timed in right now.';
  end if;
  if v_row.break_started_at is not null then
    raise exception 'Your break has already started.';
  end if;

  update attendance set break_started_at = now() where id = v_row.id;
end $$;

create or replace function public.farmer_resume_shift()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_row   attendance%rowtype;
  v_added numeric(8,2);
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
    raise exception 'You are not timed in right now.';
  end if;
  if v_row.break_started_at is null then
    raise exception 'You are not on a break.';
  end if;

  v_added := round(extract(epoch from (now() - v_row.break_started_at)) / 60.0, 2);

  update attendance
     set break_minutes = coalesce(break_minutes, 0) + greatest(v_added, 0),
         break_started_at = null
   where id = v_row.id;
end $$;

grant execute on function public.farmer_pause_shift() to authenticated;
grant execute on function public.farmer_resume_shift() to authenticated;

-- A shift that is paused when the farmer times out closes the break first.
create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
  v_end time;
  v_now time := (now() at time zone 'Asia/Manila')::time;
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

  select end_time into v_end from job_posts where id = v_row.job_id;

  if v_end is not null then
    if v_now < (v_end - interval '1 hour') or v_now > (v_end + interval '1 hour') then
      raise exception 'You can only time out between % and % for this job.',
        to_char(v_end - interval '1 hour', 'FMHH12:MI AM'),
        to_char(v_end + interval '1 hour', 'FMHH12:MI AM');
    end if;
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

create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage,
       'start_time', j.start_time, 'end_time', j.end_time,
       'break_started_at', a.break_started_at,
       'break_minutes', a.break_minutes)
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

notify pgrst, 'reload schema';
