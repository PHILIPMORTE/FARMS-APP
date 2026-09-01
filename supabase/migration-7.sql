-- ============================================================================
--  FARMS — MIGRATION 7
--  Product photos, verification for every role, order payment gate,
--  single administrator, and farmer self-service time in / time out.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. PRODUCT PHOTOS
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists pp_read on storage.objects;
create policy pp_read on storage.objects for select
  using (bucket_id = 'product-photos');

drop policy if exists pp_write on storage.objects;
create policy pp_write on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists pp_update on storage.objects;
create policy pp_update on storage.objects for update to authenticated
  using (bucket_id = 'product-photos'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists pp_delete on storage.objects;
create policy pp_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.products
  add column if not exists photo_url text;

-- ---------------------------------------------------------------------------
-- 2. VERIFICATION FOR EVERY ROLE
-- The table was owner-only. Farmers and buyers now go through the same review.
-- ---------------------------------------------------------------------------
alter table public.owner_verifications
  add column if not exists role user_role not null default 'owner';

update public.owner_verifications v
   set role = p.role
  from public.profiles p
 where p.id = v.profile_id
   and v.role is distinct from p.role;

alter table public.owner_verifications
  alter column farm_name drop not null,
  alter column farm_address drop not null;

create or replace function public.my_verification_status()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select v.status::text
       from owner_verifications v
       join profiles p on p.id = v.profile_id
      where p.user_id = auth.uid()
      order by v.submitted_at desc
      limit 1),
    'none'
  );
$$;

create or replace function public.verification_status_for(p_profile uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select status::text from owner_verifications where profile_id = p_profile),
    'none'
  );
$$;

grant execute on function public.verification_status_for(uuid) to authenticated;

-- Approving now works for any role: a farm is only created for owners.
create or replace function public.review_owner_verification(
  p_verification_id uuid,
  p_decision verification_status,
  p_notes text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row  owner_verifications%rowtype;
  v_me   uuid := public.my_profile_id('admin');
  v_role user_role;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can review verifications.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected.';
  end if;

  select * into v_row from owner_verifications where id = p_verification_id for update;
  if not found then raise exception 'Verification request not found.'; end if;

  select role into v_role from profiles where id = v_row.profile_id;

  update owner_verifications
     set status = p_decision,
         review_notes = nullif(p_notes,''),
         reviewed_by = v_me,
         reviewed_at = now()
   where id = p_verification_id;

  if p_decision = 'approved' and v_role = 'owner' then
    if not exists (select 1 from farms where owner_id = v_row.profile_id) then
      insert into farms (owner_id, name, address, city)
      values (v_row.profile_id,
              coalesce(nullif(v_row.farm_name,''), 'My Farm'),
              v_row.farm_address, v_row.barangay);
    end if;
  end if;

  insert into notifications (user_id, message, type, link)
  values (v_row.profile_id,
          case when p_decision = 'approved'
               then 'Your account has been verified. You now have full access.'
               else 'Your verification was not approved.' ||
                    coalesce(' Reason: ' || nullif(p_notes,''), '')
          end,
          'verification', '/');
end $$;

-- ---------------------------------------------------------------------------
-- 3. ONE ADMINISTRATOR ONLY
-- ---------------------------------------------------------------------------
-- If this fails with "Key (role)=(admin) is duplicated", you already have more
-- than one administrator. Run supabase/fix-admins.sql to see them, then
-- fix-admins-step2.sql to keep one, and re-run this file.
create unique index if not exists profiles_single_admin
  on public.profiles ((role))
  where role = 'admin';

-- ---------------------------------------------------------------------------
-- 4. AN ORDER MUST BE PAID BEFORE IT CAN BE COMPLETED
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists paid boolean not null default false,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by uuid references public.profiles(id) on delete set null;

create or replace function public.set_order_paid(p_order_id uuid, p_paid boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_order   orders%rowtype;
  v_product products%rowtype;
  v_me      uuid := coalesce(public.my_profile_id('owner'), public.my_profile_id('admin'));
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  select * into v_product from products where id = v_order.product_id;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only settle orders for your own farm.';
  end if;
  if v_order.stage = 'cancelled' then
    raise exception 'A cancelled order cannot be marked paid.';
  end if;

  update orders
     set paid = p_paid,
         paid_at = case when p_paid then now() else null end,
         paid_by = case when p_paid then v_me else null end,
         updated_at = now()
   where id = p_order_id;

  if p_paid then
    insert into notifications (user_id, message, type, link)
    values (v_order.buyer_id,
            'Payment received for your order of ' || v_product.variety || '.',
            'order_status', '/buyer/orders');
  end if;
end $$;

create or replace function public.set_order_stage(
  p_order_id uuid,
  p_stage order_stage,
  p_note text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_order   orders%rowtype;
  v_product products%rowtype;
  v_farm    farms%rowtype;
  v_me      uuid := coalesce(public.my_profile_id('owner'), public.my_profile_id('admin'));
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  select * into v_product from products where id = v_order.product_id;
  select * into v_farm    from farms    where id = v_product.farm_id;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only update orders for your own farm.';
  end if;

  if v_order.stage = p_stage then
    return;
  end if;
  if v_order.stage in ('completed','cancelled') then
    raise exception 'This order is already %, so it cannot be changed.', v_order.stage;
  end if;

  if p_stage = 'completed' and v_order.paid = false then
    raise exception 'Mark this order as paid before completing it.';
  end if;

  if p_stage = 'cancelled' then
    update products
       set quantity = quantity + v_order.quantity,
           status = case when status = 'sold' then 'available'::product_status else status end
     where id = v_order.product_id;

    insert into stock_changes (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_order.product_id, v_product.farm_id, v_me,
            v_product.quantity, v_product.quantity + v_order.quantity,
            'Order cancelled - stock returned', 'order');

    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_product.farm_id, 'expense', 'Refund', v_order.total_price,
            'Refund for cancelled order of ' || v_product.variety, current_date);
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
end $$;

-- ---------------------------------------------------------------------------
-- 5. FARMER TIME IN / TIME OUT
-- The farmer records their own timestamps. Hours are derived from the clock,
-- not typed in, so the work log becomes evidence rather than an estimate.
-- ---------------------------------------------------------------------------
alter table public.attendance
  add column if not exists time_in timestamptz,
  add column if not exists time_out timestamptz,
  add column if not exists source text not null default 'owner';

create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_standard numeric(5,2);
  v_hours    numeric(6,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

  -- When both clock stamps exist, they are the source of truth for hours.
  if new.time_in is not null and new.time_out is not null then
    v_hours := round(extract(epoch from (new.time_out - new.time_in)) / 3600.0, 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage * least(new.hours_worked / v_standard, 1), 2);
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

-- Clock in. Uses the farmer's accepted job to find the farm and daily rate.
create or replace function public.farmer_time_in()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for any job.';
  end if;

  select id into v_id
    from attendance
   where farmer_id = v_me and work_date = v_today and job_id = v_app.job_id;

  if v_id is not null then
    if (select time_out from attendance where id = v_id) is null then
      raise exception 'You are already timed in for today.';
    end if;
    raise exception 'You have already completed your shift today.';
  end if;

  insert into attendance
    (farm_id, job_id, farmer_id, work_date, status, hours_worked,
     daily_wage, time_in, source, recorded_by)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me)
  returning id into v_id;

  return v_id;
end $$;

create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
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

  update attendance set time_out = now() where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage)
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

grant execute on function public.farmer_time_in() to authenticated;
grant execute on function public.farmer_time_out() to authenticated;
grant execute on function public.my_open_shift() to authenticated;

notify pgrst, 'reload schema';
