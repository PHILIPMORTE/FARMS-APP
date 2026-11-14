-- ============================================================================
--  FARMS — MIGRATION 46
--  Time clock fixes, and one place for "today".
--
--  1. TIME IN FAILED FOR A JOB THAT IS NOT GEOFENCED.
--     An older copy of farmer_time_in(p_job_id) was still in the database next to
--     the current one. A call that sent only the job id, which is what the app
--     does when the owner has switched geofencing off, matched both and failed with
--     "function farmer_time_in(uuid) is not unique". The old copy is dropped.
--
--  2. A SHIFT STARTED BEFORE 8 AM COULD NOT BE TIMED OUT.
--     The database runs on UTC. Its "today" changes at 8 AM in the Philippines, so
--     a farmer who timed in at 6 AM was told "You have not timed in today" after
--     8 AM, and the Today panel showed nothing. Every date the time clock and the
--     other date-dependent functions use is now the Philippine date, through one
--     function, today_ph(). An open shift is found whatever day it started, so a
--     shift that runs past midnight or was never closed can always be timed out.
--
--  Run migration-45.sql first. Safe to run more than once.
-- ============================================================================

create or replace function public.today_ph()
returns date
language sql stable
as $$ select (now() at time zone 'Asia/Manila')::date $$;

grant execute on function public.today_ph() to anon, authenticated;

alter table public.attendance   alter column work_date set default public.today_ph();
alter table public.transactions alter column date      set default public.today_ph();

-- The stale copy that made the call ambiguous.
drop function if exists public.farmer_time_in(uuid);

-- ---------------------------------------------------------------------------
-- Time in
-- ---------------------------------------------------------------------------
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
  v_today date := public.today_ph();
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

  -- One open shift at a time, whatever day it began.
  if exists (
    select 1 from attendance
     where farmer_id = v_me and time_out is null
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

-- ---------------------------------------------------------------------------
-- Time out: closes the farmer's open shift, whatever day it began.
-- ---------------------------------------------------------------------------
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
   where farmer_id = v_me and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You have not timed in.';
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

-- ---------------------------------------------------------------------------
-- The shift in progress, whatever day it began
-- ---------------------------------------------------------------------------
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
        and a.time_out is null
      order by a.time_in desc
      limit 1),
    'null'::json
  );
$$;

-- ---------------------------------------------------------------------------
-- Jobs the farmer works, marked done for the day by the Philippine date
-- ---------------------------------------------------------------------------
create or replace function public.my_active_jobs()
returns table (
  job_id uuid, job_title text, farm_id uuid, farm_name text,
  wage numeric, start_time time, end_time time, clocked boolean
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
              and a.work_date = public.today_ph()
         )
    from job_applications ap
    join job_posts j on j.id = ap.job_id
    join farms f on f.id = j.farm_id
   where ap.farmer_id = public.my_profile_id('farmer')
     and ap.status = 'accepted'
     and coalesce(ap.employment_status, 'active') = 'active'
   order by f.name, j.title;
$$;

-- ---------------------------------------------------------------------------
-- Break start and end act on the open shift, whatever day it began
-- ---------------------------------------------------------------------------
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
   where farmer_id = v_me and time_out is null
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
   where farmer_id = v_me and time_out is null
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

-- ---------------------------------------------------------------------------
-- The same Philippine date in the other functions that used the server date
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_or_merge_planting(p_farm_id uuid, p_crop crop_type, p_variety text, p_planting_date date, p_seed_kg numeric, p_note text DEFAULT ''::text, p_field_name text DEFAULT ''::text, p_latitude numeric DEFAULT NULL::numeric, p_longitude numeric DEFAULT NULL::numeric)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_existing schedules%rowtype;
  v_est      json;
  v_seed     numeric;
  v_days     int;
  v_id       uuid;
  v_merged   boolean := false;
begin
  if not public.owns_farm(p_farm_id) then
    raise exception 'You can only plan plantings on your own farm.';
  end if;
  if coalesce(p_seed_kg, 0) <= 0 then
    raise exception 'Enter the seed weight in kilograms.';
  end if;
  if coalesce(trim(p_variety), '') = '' then
    raise exception 'Choose or name the variety.';
  end if;

  select * into v_existing
    from schedules
   where farm_id = p_farm_id
     and crop = p_crop
     and lower(trim(variety)) = lower(trim(p_variety))
     and planting_date = p_planting_date
     and coalesce(lower(trim(field_name)), '') = coalesce(lower(trim(p_field_name)), '')
     and status <> 'cancelled'
   order by created_at
   limit 1
   for update;

  if found then
    if v_existing.status = 'harvested' then
      raise exception 'That planting was already harvested, so seed cannot be added to it.';
    end if;
    v_seed := coalesce(v_existing.seed_kg, 0) + p_seed_kg;
  else
    v_seed := p_seed_kg;
  end if;

  v_est := public.estimate_harvest(p_crop, p_variety, v_seed);
  v_days := (v_est ->> 'days_to_harvest')::int;

  if found then
    update schedules
       set seed_kg = v_seed,
           expected_sacks = (v_est ->> 'expected_sacks')::int,
           harvest_date = (p_planting_date + (v_days || ' days')::interval)::date,
           field_latitude  = coalesce(p_latitude, field_latitude),
           field_longitude = coalesce(p_longitude, field_longitude),
           note = case
                    when coalesce(trim(p_note), '') = '' then note
                    else coalesce(nullif(note, '') || ' | ', '') || trim(p_note)
                  end
     where id = v_existing.id;

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into schedules
      (farm_id, crop, variety, planting_month, planting_date, harvest_date,
       estimated_months, seed_kg, expected_sacks, status, note,
       field_name, field_latitude, field_longitude)
    values (p_farm_id, p_crop, trim(p_variety),
            to_char(p_planting_date, 'YYYY-MM'),
            p_planting_date,
            (p_planting_date + (v_days || ' days')::interval)::date,
            greatest(1, round(v_days / 30.0)::int),
            v_seed,
            (v_est ->> 'expected_sacks')::int,
            case when p_planting_date > public.today_ph() then 'planned'::schedule_status
                 else 'planted'::schedule_status end,
            nullif(trim(p_note), ''),
            nullif(trim(p_field_name), ''),
            p_latitude, p_longitude)
    returning id into v_id;
  end if;

  return json_build_object(
    'id', v_id, 'merged', v_merged,
    'seed_kg', v_seed,
    'expected_sacks', (v_est ->> 'expected_sacks')::int
  );
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_confirm_payment(p_attendance_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row  attendance%rowtype;
  v_me   uuid := public.my_profile_id('farmer');
  v_name text;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to confirm a payment.';
  end if;

  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then raise exception 'That work day no longer exists.'; end if;
  if v_row.farmer_id <> v_me then
    raise exception 'You can only confirm your own wages.';
  end if;
  if v_row.payment_status = 'paid' then
    raise exception 'You have already confirmed this payment.';
  end if;
  if v_row.payment_status <> 'pending' then
    raise exception 'The farm owner has not sent this wage yet.';
  end if;

  update attendance
     set payment_status = 'paid',
         payment_confirmed_at = now(),
         paid = true,
         paid_at = now()
   where id = p_attendance_id;

  select name into v_name from profiles where id = v_me;

  insert into transactions (farm_id, type, category, amount, description, date)
  values (v_row.farm_id, 'expense', 'Labor', v_row.computed_pay,
          'Wage paid to ' || coalesce(v_name, 'a worker') || ' for ' ||
          to_char(v_row.work_date, 'FMMon DD, YYYY'),
          public.today_ph());

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         coalesce(v_name, 'A worker') || ' confirmed receiving PHP ' || v_row.computed_pay || '.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;
end $function$;

CREATE OR REPLACE FUNCTION public.generate_harvest_reminders()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_owner   uuid := public.my_profile_id('owner');
  v_row     record;
  v_created int := 0;
  v_msg     text;
begin
  if v_owner is null then
    return 0;
  end if;

  for v_row in
    select s.id,
           s.crop,
           f.name as farm_name,
           -- First day of the estimated harvest month
           (to_date(s.planting_month, 'YYYY-MM')
             + (s.estimated_months || ' months')::interval)::date as harvest_start
      from schedules s
      join farms f on f.id = s.farm_id
     where f.owner_id = v_owner
  loop
    -- Only inside the 3-day window before the harvest month begins
    if v_row.harvest_start - public.today_ph() between 0 and 3 then
      v_msg := 'Harvest reminder: your ' || v_row.crop || ' at ' ||
               coalesce(v_row.farm_name, 'your farm') ||
               ' is due around ' || to_char(v_row.harvest_start, 'FMMonth YYYY');

      -- One reminder per schedule per harvest date
      if not exists (
        select 1 from notifications
         where user_id = v_owner
           and type = 'harvest'
           and message = v_msg
      ) then
        insert into notifications (user_id, message, type, link)
        values (v_owner, v_msg, 'harvest', '/owner/calendar');
        v_created := v_created + 1;
      end if;
    end if;
  end loop;

  return v_created;
end $function$;

CREATE OR REPLACE FUNCTION public.nav_badges()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    return json_build_object(
      -- applications that have been decided since the farmer last looked
      'farmer_applications', (
        select count(*) from job_applications
         where farmer_id = v_farmer and status = 'accepted'
           and coalesce(employment_status, 'active') = 'active'),

      -- a shift left open
      'farmer_logs', (
        select count(*) from attendance
         where farmer_id = v_farmer and time_out is null),

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
end $function$;

CREATE OR REPLACE FUNCTION public.set_order_stage(p_order_id uuid, p_stage order_stage, p_note text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order   orders%rowtype;
  v_product products%rowtype;
  v_farm    farms%rowtype;
  v_buyer   text;
  v_me      uuid := coalesce(public.my_profile_id('owner'), public.my_profile_id('admin'));
  v_left    int;
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  select * into v_product from products where id = v_order.product_id for update;
  select * into v_farm    from farms    where id = v_product.farm_id;
  select name into v_buyer from profiles where id = v_order.buyer_id;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only update orders for your own farm.';
  end if;

  if v_order.stage = p_stage then return; end if;
  if v_order.stage in ('completed','cancelled') then
    raise exception 'This order is already %, so it cannot be changed.', v_order.stage;
  end if;
  if p_stage = 'completed' and v_order.paid = false then
    raise exception 'Mark this order as paid before completing it.';
  end if;

  if p_stage = 'completed' then
    v_left := greatest(v_product.quantity - v_order.quantity, 0);

    update products
       set quantity = v_left,
           reserved = greatest(reserved - v_order.quantity, 0),
           status = case when v_left <= 0 then 'sold'::product_status
                         else 'available'::product_status end,
           buyer_id = case when v_left <= 0 then v_order.buyer_id else buyer_id end
     where id = v_product.id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_product.id, v_product.farm_id, v_me, v_product.quantity, v_left,
            'Order completed - ' || public.unit_phrase(v_product.crop, v_order.quantity) || ' released to ' ||
            coalesce(v_buyer,'the buyer'), 'order');

    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_product.farm_id, 'income', 'Crop Sales', v_order.total_price,
            public.unit_phrase(v_product.crop, v_order.quantity) || ' of ' || v_product.variety || ' sold to ' ||
            coalesce(v_buyer,'a buyer'), public.today_ph());
  end if;

  if p_stage = 'cancelled' then
    update products
       set reserved = greatest(reserved - v_order.quantity, 0),
           status = case when status = 'reserved' then 'available'::product_status
                         else status end
     where id = v_product.id;
  end if;

  update orders
     set stage = p_stage,
         status = case
                    when p_stage = 'cancelled' then 'cancelled'::order_status
                    when p_stage = 'completed' then 'completed'::order_status
                    else 'pending'::order_status
                  end,
         cancel_reason = case when p_stage = 'cancelled' then nullif(p_note,'') else cancel_reason end,
         updated_at = now()
   where id = p_order_id;

  insert into order_events (order_id, stage, note, changed_by)
  values (p_order_id, p_stage, nullif(p_note,''), v_me);

  insert into notifications (user_id, message, type, link)
  values (v_order.buyer_id,
          'Your order of ' || v_product.variety || ' is now: ' ||
          replace(initcap(p_stage::text), '_', ' '),
          'order_status', '/buyer/orders');
end $function$;

-- ---------------------------------------------------------------------------
-- A wage cannot be sent for a shift that is still running
-- ---------------------------------------------------------------------------
create or replace function public.set_attendance_paid(p_attendance_id uuid, p_paid boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row attendance%rowtype;
  v_me  uuid := public.my_profile_id('owner');
begin
  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That work day no longer exists.';
  end if;

  if not public.owns_farm(v_row.farm_id) and not public.is_admin() then
    raise exception 'You can only settle wages for your own farm.';
  end if;

  if v_row.payment_status = 'paid' then
    raise exception 'The farmer already confirmed this payment, so it cannot be changed.';
  end if;

  if p_paid then
    if v_row.time_in is not null and v_row.time_out is null then
      raise exception 'This worker has not timed out yet. Send the wage once the shift has ended.';
    end if;

    if v_row.computed_pay <= 0 then
      raise exception 'There is no wage to pay for this day.';
    end if;

    update attendance
       set payment_status = 'pending',
           payment_sent_at = now(),
           paid_by = v_me,
           paid = false
     where id = p_attendance_id;

    insert into notifications (user_id, message, type, link)
    values (v_row.farmer_id,
            'Your wage of PHP ' || v_row.computed_pay || ' for ' ||
            to_char(v_row.work_date, 'FMMon DD, YYYY') ||
            ' has been sent. Confirm once you receive it.',
            'general', '/farmer/history');
  else
    update attendance
       set payment_status = 'unpaid',
           payment_sent_at = null,
           paid_by = null,
           paid = false
     where id = p_attendance_id;
  end if;
end $$;

notify pgrst, 'reload schema';
