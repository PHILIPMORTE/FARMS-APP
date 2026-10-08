-- ============================================================================
--  FARMS — MIGRATION 31
--  A farmer must be at the farm to clock in or out. The distance is worked out
--  in the database, not the browser, and the position is stored on the record
--  so the farm owner can see where each shift was started and ended.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- How far a worker may be from the farm and still clock in. Held per farm so a
-- large farm can allow more room than a small one.
alter table public.farms
  add column if not exists clock_radius_m int not null default 300;

alter table public.attendance
  add column if not exists in_latitude   numeric(10,7),
  add column if not exists in_longitude  numeric(10,7),
  add column if not exists in_distance_m int,
  add column if not exists out_latitude  numeric(10,7),
  add column if not exists out_longitude numeric(10,7),
  add column if not exists out_distance_m int;

-- ---------------------------------------------------------------------------
-- Distance between two points on the earth, in metres. The haversine formula,
-- accurate enough at these distances and avoids needing PostGIS.
-- ---------------------------------------------------------------------------
create or replace function public.distance_metres(
  lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric
)
returns int
language plpgsql immutable
as $$
declare
  r  numeric := 6371000;
  p1 numeric := radians(lat1);
  p2 numeric := radians(lat2);
  dp numeric := radians(lat2 - lat1);
  dl numeric := radians(lon2 - lon1);
  a  numeric;
begin
  if lat1 is null or lon1 is null or lat2 is null or lon2 is null then
    return null;
  end if;

  a := sin(dp / 2) * sin(dp / 2)
     + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);

  return round(r * 2 * atan2(sqrt(a), sqrt(1 - a)))::int;
end $$;

grant execute on function public.distance_metres(numeric, numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Where is the farm, and how close must the worker be? Used by the time clock
-- to show the distance before the button is pressed.
-- ---------------------------------------------------------------------------
create or replace function public.my_job_locations()
returns table (
  job_id     uuid,
  farm_id    uuid,
  farm_name  text,
  latitude   numeric,
  longitude  numeric,
  radius_m   int
)
language sql stable security definer set search_path = public
as $$
  select j.id, f.id, f.name, f.latitude, f.longitude, f.clock_radius_m
    from job_applications a
    join job_posts j on j.id = a.job_id
    join farms f on f.id = j.farm_id
   where a.farmer_id = public.my_profile_id('farmer')
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active';
$$;

grant execute on function public.my_job_locations() to authenticated;

-- ---------------------------------------------------------------------------
-- CLOCK IN, AT THE FARM
-- ---------------------------------------------------------------------------
create or replace function public.farmer_time_in(
  p_job_id uuid default null,
  p_latitude numeric default null,
  p_longitude numeric default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
  v_dist  int;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage, j.title,
         f.latitude, f.longitude, f.clock_radius_m, f.name as farm_name
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
    join farms f on f.id = j.farm_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
     and (p_job_id is null or a.job_id = p_job_id)
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for that job.';
  end if;

  -- Only enforced when the farm has actually been pinned on the map.
  if v_app.latitude is not null and v_app.longitude is not null then
    if p_latitude is null or p_longitude is null then
      raise exception 'Turn on location so the farm can confirm you are on site.';
    end if;

    v_dist := public.distance_metres(p_latitude, p_longitude, v_app.latitude, v_app.longitude);

    if v_dist > v_app.clock_radius_m then
      raise exception
        'You are about % m from %. Move within % m of the farm to time in.',
        v_dist, v_app.farm_name, v_app.clock_radius_m;
    end if;
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
     daily_wage, time_in, source, recorded_by, task,
     in_latitude, in_longitude, in_distance_m)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me, coalesce(v_app.title, 'Farm work'),
          p_latitude, p_longitude, v_dist)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.farmer_time_in(uuid, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- CLOCK OUT, AT THE FARM
-- ---------------------------------------------------------------------------
create or replace function public.farmer_time_out(
  p_latitude numeric default null,
  p_longitude numeric default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me   uuid := public.my_profile_id('farmer');
  v_row  attendance%rowtype;
  v_farm farms%rowtype;
  v_add  numeric(8,2) := 0;
  v_dist int;
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

  select * into v_farm from farms where id = v_row.farm_id;

  if v_farm.latitude is not null and v_farm.longitude is not null then
    if p_latitude is null or p_longitude is null then
      raise exception 'Turn on location so the farm can confirm you are on site.';
    end if;

    v_dist := public.distance_metres(p_latitude, p_longitude, v_farm.latitude, v_farm.longitude);

    if v_dist > v_farm.clock_radius_m then
      raise exception
        'You are about % m from %. Move within % m of the farm to time out.',
        v_dist, v_farm.name, v_farm.clock_radius_m;
    end if;
  end if;

  if v_row.break_started_at is not null then
    v_add := round(extract(epoch from (now() - v_row.break_started_at)) / 60.0, 2);
  end if;

  update attendance
     set time_out = now(),
         break_minutes = coalesce(break_minutes, 0) + greatest(v_add, 0),
         break_started_at = null,
         out_latitude = p_latitude,
         out_longitude = p_longitude,
         out_distance_m = v_dist
   where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

grant execute on function public.farmer_time_out(numeric, numeric) to authenticated;

-- The old argument-less versions would be ambiguous against the new ones.
drop function if exists public.farmer_time_out();

-- The time clock needs the job id back so it knows which farm to fence against.
create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage,
       'job_id', a.job_id,
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
