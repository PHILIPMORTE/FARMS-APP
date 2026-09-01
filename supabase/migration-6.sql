-- ============================================================================
--  FARMS — MIGRATION 6
--  Wage payment tracking on the daily work log.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.attendance
  add column if not exists paid boolean not null default false,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by uuid references public.profiles(id) on delete set null;

create index if not exists attendance_paid_idx on public.attendance(farm_id, paid);

-- ---------------------------------------------------------------------------
-- Mark a day's wage as paid, or undo it. Recording the payment on the ledger
-- keeps Finance honest: the wage was already booked as a Labor expense when
-- the worker was hired, so marking it paid only stamps who settled it and when.
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

  if p_paid and v_row.computed_pay <= 0 then
    raise exception 'There is no wage to pay for this day.';
  end if;

  update attendance
     set paid    = p_paid,
         paid_at = case when p_paid then now() else null end,
         paid_by = case when p_paid then v_me else null end
   where id = p_attendance_id;

  if p_paid then
    insert into notifications (user_id, message, type, link)
    values (v_row.farmer_id,
            'Your wage of PHP ' || v_row.computed_pay || ' for ' ||
            to_char(v_row.work_date, 'FMMon DD, YYYY') || ' has been paid.',
            'general', '/farmer/applications');
  end if;
end $$;

-- Settle every unpaid day for one worker in a month, in a single step.
create or replace function public.pay_worker_month(
  p_farmer_id uuid,
  p_month text
)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_farm  uuid;
  v_me    uuid := public.my_profile_id('owner');
  v_count int;
  v_total numeric;
begin
  select id into v_farm from farms where owner_id = v_me limit 1;
  if v_farm is null then
    raise exception 'No farm found for this account.';
  end if;

  select count(*), coalesce(sum(computed_pay), 0)
    into v_count, v_total
    from attendance
   where farm_id = v_farm
     and farmer_id = p_farmer_id
     and to_char(work_date, 'YYYY-MM') = p_month
     and paid = false
     and computed_pay > 0;

  if v_count = 0 then
    return 0;
  end if;

  update attendance
     set paid = true, paid_at = now(), paid_by = v_me
   where farm_id = v_farm
     and farmer_id = p_farmer_id
     and to_char(work_date, 'YYYY-MM') = p_month
     and paid = false
     and computed_pay > 0;

  insert into notifications (user_id, message, type, link)
  values (p_farmer_id,
          'You have been paid PHP ' || v_total || ' for ' || v_count ||
          ' work day(s).',
          'general', '/farmer/applications');

  return v_count;
end $$;

notify pgrst, 'reload schema';
