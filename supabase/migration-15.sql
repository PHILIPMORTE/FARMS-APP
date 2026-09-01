-- ============================================================================
--  FARMS — MIGRATION 15
--  Wage payment now needs both sides. The farm owner marks a day as sent, and
--  it stays pending until the farmer confirms they received it. Once confirmed
--  it cannot be undone, so the record stands as proof for both parties.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

do $$ begin
  create type payment_state as enum ('unpaid','pending','paid');
exception when duplicate_object then null; end $$;

alter table public.attendance
  add column if not exists payment_status payment_state not null default 'unpaid',
  add column if not exists payment_sent_at timestamptz,
  add column if not exists payment_confirmed_at timestamptz;

update public.attendance
   set payment_status = 'paid',
       payment_confirmed_at = coalesce(payment_confirmed_at, paid_at, now())
 where paid = true and payment_status = 'unpaid';

-- ---------------------------------------------------------------------------
-- OWNER: mark a day's wage as sent. It becomes pending, not paid.
-- ---------------------------------------------------------------------------
create or replace function public.set_attendance_paid(
  p_attendance_id uuid,
  p_paid boolean
)
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

-- ---------------------------------------------------------------------------
-- FARMER: confirm the wage was received. This is final.
-- ---------------------------------------------------------------------------
create or replace function public.farmer_confirm_payment(p_attendance_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row  attendance%rowtype;
  v_me   uuid := public.my_profile_id('farmer');
  v_name text;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to confirm a payment.';
  end if;

  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That work day no longer exists.';
  end if;
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

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         coalesce(v_name, 'A worker') || ' confirmed receiving PHP ' || v_row.computed_pay ||
         ' for ' || to_char(v_row.work_date, 'FMMon DD, YYYY') || '.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;
end $$;

grant execute on function public.farmer_confirm_payment(uuid) to authenticated;

-- Farmers need to read their own attendance to confirm it; the existing
-- att_select policy already allows this.
notify pgrst, 'reload schema';
