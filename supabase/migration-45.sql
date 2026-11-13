-- ============================================================================
--  FARMS — MIGRATION 45
--  Geofencing is chosen for each job, when the owner posts it.
--
--  Until now geofencing was one switch for the whole farm (farms.require_gps).
--  It is now a choice made on each job: job_posts.geofenced.
--
--    geofenced     workers can record time in and out only from a phone with an
--                  accurate GPS reading, while inside the purok of the job. The
--                  position, distance, accuracy and device are stored.
--    not geofenced workers can record time in and out from anywhere. No location
--                  is asked for or stored, and the shift reads "Not checked".
--
--  New jobs are geofenced unless the owner says otherwise. Jobs that already exist
--  keep the behaviour they had: they are geofenced, except those of a farm that had
--  switched geofencing off. The farm-wide setting is no longer used.
--
--  Run migration-44.sql first. Safe to run more than once.
-- ============================================================================

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'job_posts' and column_name = 'geofenced'
  ) then
    alter table public.job_posts add column geofenced boolean not null default true;
    -- existing jobs of a farm that had turned geofencing off stay off
    update public.job_posts j set geofenced = false
      from public.farms f
     where f.id = j.farm_id and f.require_gps = false;
  end if;
end $$;

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
  v_in    boolean;
  v_check boolean;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage, j.title, j.purok_id,
         f.latitude as farm_lat, f.longitude as farm_lng,
         f.clock_radius_m, f.name as farm_name,
         j.geofenced, f.max_accuracy_m,
         p.name as purok_name, p.boundary as purok_boundary,
         p.latitude as purok_lat, p.longitude as purok_lng
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
    join farms f on f.id = j.farm_id
    left join puroks p on p.id = j.purok_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
     and (p_job_id is null or a.job_id = p_job_id)
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for that job.';
  end if;

  -- The farm owner decides, for each job, whether it is geofenced.
  v_check := coalesce(v_app.geofenced, true);

  -- The reading must come from a telephone and be accurate enough to trust.
  if v_check
     and (v_app.purok_boundary is not null or v_app.farm_lat is not null) then
    if p_latitude is null or p_longitude is null then
      raise exception 'Turn on location so the farm can confirm you are on site.';
    end if;
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

  -- Preferred test: is the farmer standing inside the purok of the job?
  if v_check and v_app.purok_boundary is not null
     and jsonb_array_length(v_app.purok_boundary) >= 3 then
    v_in := public.point_in_boundary(p_latitude, p_longitude, v_app.purok_boundary);
    if not v_in then
      raise exception
        'You are not inside %. This job is in %, and you can only time in from there.',
        v_app.purok_name, v_app.purok_name;
    end if;
    v_dist := public.distance_metres(p_latitude, p_longitude,
                                     v_app.purok_lat, v_app.purok_lng);

  -- Fallback: the older radius around the farm pin.
  elsif v_check and v_app.farm_lat is not null and v_app.farm_lng is not null then
    v_dist := public.distance_metres(p_latitude, p_longitude,
                                     v_app.farm_lat, v_app.farm_lng);
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
     in_latitude, in_longitude, in_distance_m, in_accuracy_m, in_device, in_purok_id)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me, coalesce(v_app.title, 'Farm work'),
          case when v_check then p_latitude end, case when v_check then p_longitude end, v_dist,
          case when v_check then round(p_accuracy)::int end, case when v_check then p_device end,
          case when v_check then v_app.purok_id end)
  returning id into v_id;

  return v_id;
end $$;

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
  v_pk   puroks%rowtype;
  v_add  numeric(8,2) := 0;
  v_dist int;
  v_check boolean;
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
  select p.* into v_pk
    from job_posts j join puroks p on p.id = j.purok_id
   where j.id = v_row.job_id;

  -- The farm owner decides, for each job, whether it is geofenced.
  select coalesce(jp.geofenced, true) into v_check from job_posts jp where jp.id = v_row.job_id;
  v_check := coalesce(v_check, true);

  if v_check
     and (v_pk.boundary is not null or v_farm.latitude is not null) then
    if p_latitude is null or p_longitude is null then
      raise exception 'Turn on location so the farm can confirm you are on site.';
    end if;
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

  if v_check and v_pk.boundary is not null and jsonb_array_length(v_pk.boundary) >= 3 then
    if not public.point_in_boundary(p_latitude, p_longitude, v_pk.boundary) then
      raise exception
        'You are not inside %. You can only time out from the purok where the work is.',
        v_pk.name;
    end if;
    v_dist := public.distance_metres(p_latitude, p_longitude, v_pk.latitude, v_pk.longitude);
  elsif v_check and v_farm.latitude is not null and v_farm.longitude is not null then
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
         out_latitude = case when v_check then p_latitude end,
         out_longitude = case when v_check then p_longitude end,
         out_distance_m = v_dist,
         out_accuracy_m = case when v_check then round(p_accuracy)::int end,
         out_device = case when v_check then p_device end,
         out_purok_id = case when v_check then v_pk.id end
   where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

drop function if exists public.my_job_locations();

create or replace function public.my_job_locations()
returns table (
  job_id         uuid,
  farm_id        uuid,
  farm_name      text,
  latitude       numeric,
  longitude      numeric,
  radius_m       int,
  geofenced      boolean,
  max_accuracy_m int,
  purok_id       uuid,
  purok_name     text,
  purok_boundary jsonb
)
language sql stable security definer set search_path = public
as $$
  select j.id, f.id, f.name, f.latitude, f.longitude,
         f.clock_radius_m, j.geofenced, f.max_accuracy_m,
         p.id, p.name, p.boundary
    from job_applications a
    join job_posts j on j.id = a.job_id
    join farms f on f.id = j.farm_id
    left join puroks p on p.id = j.purok_id
   where a.farmer_id = public.my_profile_id('farmer')
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active';
$$;

grant execute on function public.my_job_locations() to authenticated;

notify pgrst, 'reload schema';
