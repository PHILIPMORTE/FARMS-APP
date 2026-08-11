-- ============================================================================
--  FARMS — UPDATE PATCH
--  Run this in the Supabase SQL Editor.
--  Adds the functions the app now calls, and updates hiring so wages are
--  recorded automatically. Safe to run more than once.
-- ============================================================================

-- Hiring now books the wage as a Labor expense on the farm's ledger.
create or replace function public.decide_application(p_application_id uuid, p_decision app_status)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app   job_applications%rowtype;
  v_job   job_posts%rowtype;
  v_farm        farms%rowtype;
  v_owner       uuid := public.my_profile_id('owner');
  v_days        int;
  v_cost        numeric(12,2);
  v_farmer_name text;
begin
  if p_decision not in ('accepted','rejected') then
    raise exception 'Decision must be accepted or rejected.';
  end if;

  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;

  select * into v_job from job_posts where id = v_app.job_id for update;

  if v_owner is null or v_job.owner_id <> v_owner then
    raise exception 'You can only review applications on your own job posts.';
  end if;
  if v_app.status <> 'pending' then
    raise exception 'This application was already reviewed.';
  end if;

  select * into v_farm from farms where id = v_job.farm_id;

  update job_applications set status = p_decision, updated_at = now()
   where id = p_application_id;

  if p_decision = 'accepted' then
    if v_job.filled_slots >= v_job.slots then
      raise exception 'Every slot on this job is already filled.';
    end if;

    update job_posts
       set filled_slots = filled_slots + 1,
           status = case when filled_slots + 1 >= slots then 'filled'::job_status else status end
     where id = v_job.id;

    -- Hiring costs money, so the wage lands on the farm's books automatically.
    -- A job that runs start..end is paid for every day inclusive; a job with no
    -- end date is booked as a single day's wage.
    v_days := greatest(1, (coalesce(v_job.end_date, v_job.start_date) - v_job.start_date) + 1);
    v_cost := v_job.wage * v_days;

    select name into v_farmer_name from profiles where id = v_app.farmer_id;

    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_job.farm_id, 'expense', 'Labor', v_cost,
            coalesce(v_farmer_name, 'A farmer') || ' hired for ' || v_job.title ||
            ' (' || v_days || ' day' || case when v_days = 1 then '' else 's' end ||
            ' at PHP ' || v_job.wage || '/day)',
            v_job.start_date);

    insert into notifications (user_id, message, type, link)
    values (v_app.farmer_id,
            'You have been hired for ' || v_job.title || ' at ' || coalesce(v_farm.name,'the farm'),
            'hired', '/farmer/applications');
  else
    insert into notifications (user_id, message, type, link)
    values (v_app.farmer_id,
            'Your application for ' || v_job.title || ' was not accepted',
            'rejected', '/farmer/applications');
  end if;
end $$;


-- ============================================================================
-- HARVEST REMINDERS
-- Call this on load; it creates a reminder for any schedule whose harvest month
-- starts within 3 days, and will not duplicate one it has already written.
-- ============================================================================
create or replace function public.generate_harvest_reminders()
returns int
language plpgsql security definer set search_path = public
as $$
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
    if v_row.harvest_start - current_date between 0 and 3 then
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
end $$;


-- ============================================================================
-- PHONE AVAILABILITY CHECK
-- The registration form must be able to say "this number is already registered
-- as a Farm Owner" BEFORE an auth user is created. At that point the person is
-- not signed in, and profiles_select is restricted to authenticated users — so
-- a plain select returns nothing and the check silently passes.
--
-- This runs as SECURITY DEFINER and returns only a boolean, so anonymous
-- callers can test one (phone, role) pair without being able to read the
-- profiles table or enumerate who is registered.
-- ============================================================================
create or replace function public.phone_role_taken(p_phone text, p_role user_role)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles where phone = p_phone and role = p_role
  );
$$;

revoke all on function public.phone_role_taken(text, user_role) from public;
grant execute on function public.phone_role_taken(text, user_role) to anon, authenticated;


-- ============================================================================
-- DELETE A JOB POST
-- Deleting a post cascades to its applications, but deliberately NOT to
-- transactions: a wage already booked when someone was hired is real money
-- that was committed, so it stays on the books. transactions has no foreign
-- key to job_posts, which is what guarantees this.
--
-- Applicants are told before the post disappears, so nobody is left waiting
-- on something that no longer exists.
-- ============================================================================
create or replace function public.delete_job_post(p_job_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_job   job_posts%rowtype;
  v_farm  farms%rowtype;
  v_owner uuid := public.my_profile_id('owner');
  v_app   record;
begin
  select * into v_job from job_posts where id = p_job_id for update;
  if not found then
    raise exception 'That job post no longer exists.';
  end if;

  if v_owner is null or v_job.owner_id <> v_owner then
    raise exception 'You can only delete your own job posts.';
  end if;

  select * into v_farm from farms where id = v_job.farm_id;

  -- Tell everyone who applied, wording it by their outcome.
  for v_app in
    select farmer_id, status from job_applications where job_id = p_job_id
  loop
    insert into notifications (user_id, message, type, link)
    values (
      v_app.farmer_id,
      case
        when v_app.status = 'accepted' then
          'The job "' || v_job.title || '" at ' || coalesce(v_farm.name, 'the farm') ||
          ' has been removed. Contact the farm owner about work already agreed.'
        else
          'The job "' || v_job.title || '" at ' || coalesce(v_farm.name, 'the farm') ||
          ' is no longer available.'
      end,
      'general', '/farmer/jobs');
  end loop;

  -- Cascades to job_applications only. Wages in transactions are untouched.
  delete from job_posts where id = p_job_id;
end $$;

-- Refresh PostgREST so the new functions are visible to the app immediately.
notify pgrst, 'reload schema';
