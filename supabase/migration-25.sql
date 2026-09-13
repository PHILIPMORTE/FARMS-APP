-- ============================================================================
--  FARMS — MIGRATION 25
--  A planting records where on the farm it is, so several fields can be told
--  apart on the calendar and on the map.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.schedules
  add column if not exists field_latitude  numeric(10,7),
  add column if not exists field_longitude numeric(10,7);

create or replace function public.add_or_merge_planting(
  p_farm_id       uuid,
  p_crop          crop_type,
  p_variety       text,
  p_planting_date date,
  p_seed_kg       numeric,
  p_note          text default '',
  p_field_name    text default '',
  p_latitude      numeric default null,
  p_longitude     numeric default null
)
returns json
language plpgsql security definer set search_path = public
as $$
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
            case when p_planting_date > current_date then 'planned'::schedule_status
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
end $$;

grant execute on function public.add_or_merge_planting(
  uuid, crop_type, text, date, numeric, text, text, numeric, numeric) to authenticated;

notify pgrst, 'reload schema';
