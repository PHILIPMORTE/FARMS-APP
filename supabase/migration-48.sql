-- ============================================================================
--  FARMS — MIGRATION 48
--  Working "Forgot password", email notices that reach phone accounts, and
--  plantings that remember their purok, and harvests that count only once.
--
--  WHAT WAS WRONG
--   1. "Forgot password?" could never work. It looked the email up while the
--      person was signed out, and the profiles table is closed to signed-out
--      users, so it always answered "no email is attached". It also pointed the
--      reset link at a page that does not exist.
--   2. Email notices (verified, hired, ready to harvest) were sent only to the
--      address of the sign-in account. Accounts made with a phone number sign in
--      through a made-up address (…@phone.farms.ph), so those people never got
--      an email, even after saving their real email on the Account page.
--   3. Adding a planting made the owner choose a purok, but the choice was thrown
--      away: it was checked on screen and never saved with the planting.
--   4. Recording a harvest twice (a second tap, or a retry after the connection
--      dropped) added the same crop to the inventory twice.
--
--  WHAT THIS DOES
--   • contact_email(profile)   the address to write to: the email saved on the
--                              Account page, else a real sign-in address.
--   • queue_message()          now uses it, so phone accounts get their notices.
--   • request_password_reset() emails a 6-digit code (valid 15 minutes).
--   • reset_password_with_code() checks the code and sets the new password.
--
--   • add_or_merge_planting()  now saves the purok with the planting, and the
--                              plantings made before this get their farm's purok.
--   • harvest_schedule()       refuses a planting that is already harvested or
--                              cancelled, so a harvest can never be counted twice.
--
--  The code is stored only as a hash, works once, is dead after 5 wrong tries,
--  and a person can ask for at most 3 codes in 15 minutes. There is no link in
--  the email, so there is nothing for an attacker to redirect.
--
--  Needs the email setup from migration-27 (Resend key in app_settings).
--  Run after migration-47. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. WHICH ADDRESS DO WE WRITE TO
-- ---------------------------------------------------------------------------
create or replace function public.contact_email(p_profile_id uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
           nullif(btrim(p.email), ''),
           case when u.email is not null and u.email not like '%@phone.farms.ph'
                then u.email end
         )
    from profiles p
    left join auth.users u on u.id = p.user_id
   where p.id = p_profile_id;
$$;

revoke all on function public.contact_email(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. EMAIL NOTICES USE IT
-- ---------------------------------------------------------------------------
create or replace function public.queue_message(
  p_profile_id uuid,
  p_subject text,
  p_body text
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_email text := public.contact_email(p_profile_id);
begin
  if v_email is null then
    return;
  end if;

  insert into message_outbox (profile_id, channel, recipient, subject, body)
  values (p_profile_id, 'email', v_email, p_subject, p_body);

  perform public.send_queued_emails();
end $$;

revoke execute on function public.queue_message(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. RESET CODES
-- ---------------------------------------------------------------------------
create table if not exists public.password_resets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,
  code_hash   text not null,
  attempts    int  not null default 0,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists password_resets_user_idx
  on public.password_resets (user_id, created_at desc);

-- Nobody reads this table directly. Only the two functions below touch it.
alter table public.password_resets enable row level security;
revoke all on public.password_resets from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. ASK FOR A CODE
--    Returns {status: ...}:
--      sent          code emailed (email_hint shows a masked address)
--      not_found     no account with that number
--      no_email      the account has no email saved
--      use_google    the account signs in with Google, there is no password
--      wait          asked again too soon (seconds says how long)
--      too_many      3 codes in the last 15 minutes
--      email_failed  the email could not be handed to the mail service
-- ---------------------------------------------------------------------------
create or replace function public.request_password_reset(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_row    record;
  v_code   text;
  v_bytes  bytea;
  v_last   timestamptz;
  v_recent int;
  v_out    uuid;
  v_status text;
  v_first  text;
  v_at     int;
begin
  if p_phone is null or p_phone !~ '^\+639[0-9]{9}$' then
    raise exception 'Use a Philippine mobile number, like 09171234567.';
  end if;

  select p.id, p.user_id, p.name,
         public.contact_email(p.id) as em,
         u.email as auth_email, u.phone as auth_phone
    into v_row
    from profiles p
    left join auth.users u on u.id = p.user_id
   where p.phone = p_phone
   order by (public.contact_email(p.id) is not null) desc, p.created_at desc
   limit 1;

  if v_row.id is null then
    return jsonb_build_object('status', 'not_found');
  end if;

  -- A Google account has no password to reset.
  if v_row.auth_email is not null
     and v_row.auth_email not like '%@phone.farms.ph'
     and v_row.auth_phone is null then
    return jsonb_build_object('status', 'use_google');
  end if;

  if v_row.em is null then
    return jsonb_build_object('status', 'no_email');
  end if;

  select max(created_at), count(*) filter (where created_at > now() - interval '15 minutes')
    into v_last, v_recent
    from password_resets where user_id = v_row.user_id;

  if v_last is not null and v_last > now() - interval '60 seconds' then
    return jsonb_build_object(
      'status', 'wait',
      'seconds', greatest(1, ceil(extract(epoch from (v_last + interval '60 seconds' - now())))::int));
  end if;
  if v_recent >= 3 then
    return jsonb_build_object('status', 'too_many');
  end if;

  -- a new code replaces any older one
  update password_resets set used_at = now()
   where user_id = v_row.user_id and used_at is null;

  v_bytes := gen_random_bytes(4);
  v_code := lpad((
              (get_byte(v_bytes, 0)::bigint * 16777216
             + get_byte(v_bytes, 1) * 65536
             + get_byte(v_bytes, 2) * 256
             + get_byte(v_bytes, 3)) % 1000000)::text, 6, '0');

  insert into password_resets (user_id, code_hash, expires_at)
  values (v_row.user_id,
          encode(digest(v_code || ':' || v_row.user_id::text, 'sha256'), 'hex'),
          now() + interval '15 minutes');

  v_first := split_part(coalesce(nullif(btrim(v_row.name), ''), 'there'), ' ', 1);

  insert into message_outbox (profile_id, channel, recipient, subject, body)
  values (v_row.id, 'email', v_row.em, 'Your FARMS password reset code',
          'Hello ' || v_first || E',\n\n' ||
          'Your FARMS password reset code is: ' || v_code || E'\n\n' ||
          E'It works once and expires in 15 minutes. Enter it in the app together with your new password.\n\n' ||
          'If you did not ask for this, ignore this email. Your password has not changed.')
  returning id into v_out;

  perform public.send_queued_emails();

  select status::text into v_status from message_outbox where id = v_out;

  if v_status is distinct from 'sent' then
    -- not handed over: take the code back so it is not mailed later by surprise
    delete from message_outbox where id = v_out;
    update password_resets set used_at = now()
     where user_id = v_row.user_id and used_at is null;
    return jsonb_build_object('status', 'email_failed');
  end if;

  -- the code is only needed in the inbox, not in our records
  update message_outbox set body = 'Password reset code (removed after sending).' where id = v_out;

  v_at := position('@' in v_row.em);
  return jsonb_build_object(
    'status', 'sent',
    'email_hint', left(v_row.em, 1) || '***' || substr(v_row.em, v_at));
end $$;

revoke all on function public.request_password_reset(text) from public;
grant execute on function public.request_password_reset(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. USE THE CODE
--    Returns {ok: true}, or {ok: false, reason: ...}:
--      no_code | expired | wrong (remaining says how many tries are left) | locked
--    A wrong code is returned, not raised, so the failed try is really counted.
-- ---------------------------------------------------------------------------
create or replace function public.reset_password_with_code(
  p_phone text,
  p_code text,
  p_new_password text
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_r      record;
  v_hash   text;
  v_prof   uuid;
begin
  if p_phone is null or p_phone !~ '^\+639[0-9]{9}$' then
    raise exception 'Use a Philippine mobile number, like 09171234567.';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'Enter the 6-digit code from the email.';
  end if;
  if p_new_password is null or length(p_new_password) < 8 then
    raise exception 'Use at least 8 characters.';
  end if;

  select r.* into v_r
    from password_resets r
    join profiles p on p.user_id = r.user_id
   where p.phone = p_phone and r.used_at is null
   order by r.created_at desc
   limit 1
   for update of r;

  if v_r.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_code');
  end if;

  if v_r.expires_at < now() then
    update password_resets set used_at = now() where id = v_r.id;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  if v_r.attempts >= 5 then
    update password_resets set used_at = now() where id = v_r.id;
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;

  v_hash := encode(digest(p_code || ':' || v_r.user_id::text, 'sha256'), 'hex');

  if v_hash <> v_r.code_hash then
    update password_resets
       set attempts = attempts + 1,
           used_at = case when attempts + 1 >= 5 then now() end
     where id = v_r.id;
    if v_r.attempts + 1 >= 5 then
      return jsonb_build_object('ok', false, 'reason', 'locked');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'wrong',
                              'remaining', 5 - (v_r.attempts + 1));
  end if;

  update auth.users
     set encrypted_password = crypt(p_new_password, gen_salt('bf', 10)),
         updated_at = now()
   where id = v_r.user_id;

  -- everyone signed in with the old password is signed out
  delete from auth.sessions where user_id = v_r.user_id;

  update password_resets set used_at = now() where user_id = v_r.user_id and used_at is null;

  select id into v_prof from profiles where user_id = v_r.user_id and phone = p_phone limit 1;
  if v_prof is not null then
    perform public.queue_message(
      v_prof,
      'Your FARMS password was changed',
      'FARMS: The password for your account was just changed. ' ||
      'If this was not you, reset it again right away and contact the farm administrator.');
  end if;

  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.reset_password_with_code(text, text, text) from public;
grant execute on function public.reset_password_with_code(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. A PLANTING REMEMBERS ITS PUROK
--    The old 9-argument version is dropped first, so a call is never ambiguous
--    between two versions.
-- ---------------------------------------------------------------------------
drop function if exists public.add_or_merge_planting(
  uuid, crop_type, text, date, numeric, text, text, numeric, numeric);

create or replace function public.add_or_merge_planting(
  p_farm_id uuid,
  p_crop crop_type,
  p_variety text,
  p_planting_date date,
  p_seed_kg numeric,
  p_note text default '',
  p_field_name text default '',
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_purok_id uuid default null
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
           purok_id = coalesce(p_purok_id, purok_id),
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
       field_name, field_latitude, field_longitude, purok_id)
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
            p_latitude, p_longitude, p_purok_id)
    returning id into v_id;
  end if;

  return json_build_object(
    'id', v_id, 'merged', v_merged,
    'seed_kg', v_seed,
    'expected_sacks', (v_est ->> 'expected_sacks')::int
  );
end $$;

revoke all on function public.add_or_merge_planting(
  uuid, crop_type, text, date, numeric, text, text, numeric, numeric, uuid) from public, anon;
grant execute on function public.add_or_merge_planting(
  uuid, crop_type, text, date, numeric, text, text, numeric, numeric, uuid) to authenticated;

-- plantings made before now get the purok their farm is in
update public.schedules s
   set purok_id = f.purok_id
  from public.farms f
 where f.id = s.farm_id and s.purok_id is null and f.purok_id is not null;

-- ---------------------------------------------------------------------------
-- 7. A HARVEST CAN ONLY BE RECORDED ONCE
--    Recording a harvest twice (a second tap, or a retry after the connection
--    dropped) used to add the same crop to the inventory twice. A planting that
--    was cancelled could be harvested too. Same signature as before.
-- ---------------------------------------------------------------------------
create or replace function public.harvest_schedule(
  p_schedule_id uuid,
  p_actual_sacks integer,
  p_price numeric default null
)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_sched   schedules%rowtype;
  v_sacks   int := floor(coalesce(p_actual_sacks, 0))::int;
  v_variety text;
  v_result  json;
  v_pid     uuid;
begin
  select * into v_sched from schedules where id = p_schedule_id for update;
  if not found then raise exception 'That planting no longer exists.'; end if;
  if not public.owns_farm(v_sched.farm_id) then
    raise exception 'You can only harvest your own plantings.';
  end if;
  if v_sched.status = 'harvested' then
    raise exception 'This planting was already harvested. Nothing was added again.';
  end if;
  if v_sched.status = 'cancelled' then
    raise exception 'This planting was cancelled, so it cannot be harvested.';
  end if;
  if v_sacks < 0 then raise exception 'The harvested quantity cannot be negative.'; end if;

  v_variety := coalesce(nullif(v_sched.variety, ''), initcap(v_sched.crop::text));

  update schedules
     set actual_sacks = v_sacks,
         status = 'harvested',
         harvested_at = now()
   where id = p_schedule_id;

  if v_sacks > 0 then
    insert into inventory (farm_id, crop, quantity)
    values (v_sched.farm_id, v_sched.crop, v_sacks);

    if p_price is not null and p_price > 0 then
      select (public.add_or_merge_product(
                v_sched.farm_id, v_variety, v_sched.crop, v_sacks, p_price)::json ->> 'id')::uuid
        into v_pid;

      update schedules set listed_product_id = v_pid where id = p_schedule_id;
    end if;
  end if;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         'Harvest recorded: ' || public.unit_phrase(v_sched.crop, v_sacks) || ' of ' || v_variety || '.',
         'harvest', '/owner/calendar'
    from farms f where f.id = v_sched.farm_id;

  select json_build_object('sacks', v_sacks, 'product_id', v_pid) into v_result;
  return v_result;
end $$;

notify pgrst, 'reload schema';
