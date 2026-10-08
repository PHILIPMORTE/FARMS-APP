-- ============================================================================
--  FARMS — MIGRATION 32
--  Time in and out must come from a phone's GPS, not a laptop.
--
--  A laptop positions itself from nearby WiFi or its internet address, often
--  hundreds of metres out. A phone with GPS is usually accurate to within
--  20 m. Requiring a tight accuracy figure insists on a real handset without
--  trusting what the browser claims to be.
--
--  Run migration-31.sql first. Safe to run more than once.
-- ============================================================================

alter table public.farms
  add column if not exists require_gps boolean not null default true,
  add column if not exists max_accuracy_m int not null default 75;

alter table public.attendance
  add column if not exists in_accuracy_m  int,
  add column if not exists out_accuracy_m int,
  add column if not exists in_device      text,
  add column if not exists out_device     text;

create or replace function public.farmer_time_in(
  p_job_id uuid default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy numeric default null,
  p_device text default null
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
         f.latitude, f.longitude, f.clock_radius_m, f.name as farm_name,
         f.require_gps, f.max_accuracy_m
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

  if v_app.latitude is not null and v_app.longitude is not null then
    if p_latitude is null or p_longitude is null then
      raise exception 'Turn on location so the farm can confirm you are on site.';
    end if;

    if v_app.require_gps then
      if p_device is distinct from 'mobile' then
        raise exception
          'Time in from your phone. A computer cannot give an accurate enough location.';
      end if;

      if p_accuracy is null or p_accuracy > v_app.max_accuracy_m then
        raise exception
          'Your location is only accurate to about % m. Go outside, wait for the GPS to settle, and try again.',
          coalesce(round(p_accuracy)::text, 'an unknown number of');
      end if;
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
     in_latitude, in_longitude, in_distance_m, in_accuracy_m, in_device)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me, coalesce(v_app.title, 'Farm work'),
          p_latitude, p_longitude, v_dist, round(p_accuracy)::int, p_device)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.farmer_time_in(uuid, numeric, numeric, numeric, text) to authenticated;

create or replace function public.farmer_time_out(
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy numeric default null,
  p_device text default null
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

    if v_farm.require_gps then
      if p_device is distinct from 'mobile' then
        raise exception
          'Time out from your phone. A computer cannot give an accurate enough location.';
      end if;

      if p_accuracy is null or p_accuracy > v_farm.max_accuracy_m then
        raise exception
          'Your location is only accurate to about % m. Go outside, wait for the GPS to settle, and try again.',
          coalesce(round(p_accuracy)::text, 'an unknown number of');
      end if;
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
         out_distance_m = v_dist,
         out_accuracy_m = round(p_accuracy)::int,
         out_device = p_device
   where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

grant execute on function public.farmer_time_out(numeric, numeric, numeric, text) to authenticated;

drop function if exists public.farmer_time_in(uuid, numeric, numeric);
drop function if exists public.farmer_time_out(numeric, numeric);

create or replace function public.my_job_locations()
returns table (
  job_id      uuid,
  farm_id     uuid,
  farm_name   text,
  latitude    numeric,
  longitude   numeric,
  radius_m    int,
  require_gps boolean,
  max_accuracy_m int
)
language sql stable security definer set search_path = public
as $$
  select j.id, f.id, f.name, f.latitude, f.longitude,
         f.clock_radius_m, f.require_gps, f.max_accuracy_m
    from job_applications a
    join job_posts j on j.id = a.job_id
    join farms f on f.id = j.farm_id
   where a.farmer_id = public.my_profile_id('farmer')
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active';
$$;

notify pgrst, 'reload schema';
