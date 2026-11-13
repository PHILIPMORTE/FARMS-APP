-- ============================================================================
--  FARMS — MIGRATION 44
--  A notice when a planting changes colour on the calendar.
--
--    yellow  (70% of the growing period has passed)
--            "Sweet Corn is almost ready to harvest: 9 days left."   in the app
--    green   (the harvest date has come)
--            "Sweet Corn is ready to harvest."            in the app and by email
--
--  Red needs no notice: it is the state a planting starts in.
--
--  Each notice is sent once per planting. A planting that is first seen already
--  past yellow (for example one entered with an earlier planting date) gets only
--  the green notice, never a late yellow one.
--
--  Dates follow the Philippines (Asia/Manila), the same day the calendar uses, and
--  the green email now names the crop's own unit instead of always saying sacks.
--
--  WHEN IT RUNS
--  notify_ready_harvests() is called when the owner opens the Dashboard or the
--  Planting Calendar, so a notice appears the next time the owner opens FARMS.
--  To send them every morning even if nobody opens the app, see the optional
--  schedule at the end of this file.
--
--  Run migration-43.sql first. Safe to run more than once.
-- ============================================================================

alter table public.schedules
  add column if not exists almost_notified_at timestamptz;

-- ---------------------------------------------------------------------------
-- The work itself. p_owner = one owner, or null for every owner (for a schedule).
-- Not callable from the app: only through notify_ready_harvests() below, which
-- passes in the signed-in owner.
-- ---------------------------------------------------------------------------
create or replace function public.notify_growth_stages(p_owner uuid default null)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  r       record;
  v_n     int  := 0;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_name  text;
  v_days  int;
begin
  -- YELLOW: at least 70% of the way from planting to the harvest date, not yet green
  for r in
    select s.id, s.crop, s.variety, s.harvest_date, f.owner_id
      from schedules s
      join farms f on f.id = s.farm_id
     where s.status not in ('harvested', 'cancelled')
       and s.planting_date is not null
       and s.harvest_date  is not null
       and s.harvest_date > s.planting_date
       and s.harvest_date > v_today
       and (v_today - s.planting_date) * 100 >= 70 * (s.harvest_date - s.planting_date)
       and s.almost_notified_at is null
       and (p_owner is null or f.owner_id = p_owner)
  loop
    v_name := coalesce(nullif(r.variety, ''), r.crop::text);
    v_days := r.harvest_date - v_today;

    insert into notifications (user_id, message, type, link)
    values (r.owner_id,
            v_name || ' is almost ready to harvest: ' || v_days || ' day' ||
              case when v_days = 1 then '' else 's' end || ' left.',
            'harvest', '/owner/calendar');

    update schedules set almost_notified_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;

  -- GREEN: the harvest date has come
  for r in
    select s.id, s.crop, s.variety, s.harvest_date, s.expected_sacks,
           f.owner_id, f.name as farm_name
      from schedules s
      join farms f on f.id = s.farm_id
     where s.status not in ('harvested', 'cancelled')
       and s.harvest_date is not null
       and s.harvest_date <= v_today
       and s.harvest_notified_at is null
       and (p_owner is null or f.owner_id = p_owner)
  loop
    v_name := coalesce(nullif(r.variety, ''), r.crop::text);

    perform public.queue_message(
      r.owner_id,
      'Your ' || v_name || ' is ready to harvest',
      'FARMS: Your ' || v_name || ' at ' || r.farm_name || ' reached its harvest date on ' ||
      to_char(r.harvest_date, 'FMMon DD, YYYY') || '. The target is ' ||
      public.unit_phrase(r.crop, r.expected_sacks) || '. Open FARMS to record the harvest.');

    insert into notifications (user_id, message, type, link)
    values (r.owner_id, v_name || ' is ready to harvest.', 'harvest', '/owner/calendar');

    -- a planting that is green never needs the yellow notice afterwards
    update schedules
       set harvest_notified_at = now(),
           almost_notified_at  = coalesce(almost_notified_at, now())
     where id = r.id;
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

revoke all on function public.notify_growth_stages(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- What the app calls. It only ever acts for the signed-in farm owner.
-- ---------------------------------------------------------------------------
create or replace function public.notify_ready_harvests()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid := public.my_profile_id('owner');
begin
  if v_owner is null then
    return 0;
  end if;
  return public.notify_growth_stages(v_owner);
end $$;

grant execute on function public.notify_ready_harvests() to authenticated;

-- ---------------------------------------------------------------------------
-- OPTIONAL: send the notices every morning even if nobody opens the app.
--   1. In Supabase: Database > Extensions > enable pg_cron.
--   2. Then run the line below once. 01:00 UTC is 9:00 in the morning in the
--      Philippines.
--
--   select cron.schedule('farms-growth-notices', '0 1 * * *',
--                        $cron$ select public.notify_growth_stages(null) $cron$);
--
--   To stop it later:  select cron.unschedule('farms-growth-notices');
-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';
