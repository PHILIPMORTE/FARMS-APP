-- ============================================================================
--  FARMS — MIGRATION 24
--  Seed-to-land calculator, milled/unmilled products, payroll timing fix,
--  application cancellation, and mandatory rejection reasons.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.crop_yields
  add column if not exists kg_seed_per_hectare numeric(10,2);

update public.crop_yields set kg_seed_per_hectare = 50  where crop = 'rice'       and kg_seed_per_hectare is null;
update public.crop_yields set kg_seed_per_hectare = 20  where crop = 'corn'       and kg_seed_per_hectare is null;
update public.crop_yields set kg_seed_per_hectare = 0.5 where crop = 'watermelon' and kg_seed_per_hectare is null;

create or replace function public.land_needed(p_crop crop_type, p_variety text, p_seed_kg numeric)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_rate numeric;
  v_ha   numeric;
begin
  select kg_seed_per_hectare into v_rate
    from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));

  if v_rate is null then
    select kg_seed_per_hectare into v_rate from crop_yields where crop = p_crop and variety = '';
  end if;

  if coalesce(v_rate, 0) <= 0 then
    return json_build_object('hectares', 0, 'sqm', 0, 'kg_per_hectare', 0);
  end if;

  v_ha := coalesce(p_seed_kg, 0) / v_rate;

  return json_build_object(
    'hectares', round(v_ha, 4),
    'sqm', round(v_ha * 10000, 2),
    'kg_per_hectare', v_rate
  );
end $$;

grant execute on function public.land_needed(crop_type, text, numeric) to authenticated;

do $$ begin
  create type product_form as enum ('unmilled','milled');
exception when duplicate_object then null; end $$;

alter table public.products
  add column if not exists form product_form not null default 'unmilled';

create or replace function public.add_or_merge_product(
  p_farm_id uuid,
  p_variety text,
  p_crop crop_type,
  p_quantity int,
  p_price numeric,
  p_form product_form default 'unmilled'
)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_existing products%rowtype;
  v_qty      int := floor(p_quantity)::int;
  v_me       uuid := public.my_profile_id('owner');
  v_id       uuid;
  v_merged   boolean := false;
begin
  if not public.owns_farm(p_farm_id) then
    raise exception 'You can only add products to your own farm.';
  end if;
  if v_qty < 1 then
    raise exception 'Enter at least 1 sack.';
  end if;

  select * into v_existing
    from products
   where farm_id = p_farm_id
     and crop = p_crop
     and form = p_form
     and lower(trim(variety)) = lower(trim(p_variety))
   order by created_at
   limit 1
   for update;

  if found then
    update products
       set quantity = v_existing.quantity + v_qty,
           price    = p_price,
           status   = case when v_existing.quantity + v_qty > v_existing.reserved
                           then 'available'::product_status else status end
     where id = v_existing.id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_existing.id, p_farm_id, v_me, v_existing.quantity,
            v_existing.quantity + v_qty,
            'Added ' || v_qty || ' sack(s) to the existing listing', 'manual');

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into products (farm_id, variety, crop, quantity, price, status, form)
    values (p_farm_id, trim(p_variety), p_crop, v_qty, p_price, 'available', p_form)
    returning id into v_id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_id, p_farm_id, v_me, 0, v_qty, 'New listing created', 'manual');
  end if;

  insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

grant execute on function public.add_or_merge_product(uuid, text, crop_type, int, numeric, product_form)
  to authenticated;

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
          current_date);

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         coalesce(v_name, 'A worker') || ' confirmed receiving PHP ' || v_row.computed_pay || '.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;
end $$;

create or replace function public.cancel_application(p_application_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app  job_applications%rowtype;
  v_me   uuid := public.my_profile_id('farmer');
  v_job  job_posts%rowtype;
  v_name text;
begin
  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;
  if v_app.farmer_id <> v_me then
    raise exception 'You can only cancel your own application.';
  end if;
  if v_app.status = 'accepted' then
    raise exception 'You were already hired. Talk to the farm owner instead.';
  end if;

  select * into v_job from job_posts where id = v_app.job_id;
  select name into v_name from profiles where id = v_me;

  delete from job_applications where id = p_application_id;

  insert into notifications (user_id, message, type, link)
  values (v_job.owner_id,
          coalesce(v_name, 'An applicant') || ' withdrew their application for ' || v_job.title || '.',
          'application', '/owner/jobs');
end $$;

grant execute on function public.cancel_application(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- A rejected applicant must be told why.
-- The old two-argument version is dropped, or calling it with two arguments
-- would be ambiguous against the new one.
-- ---------------------------------------------------------------------------
drop function if exists public.decide_application(uuid, app_status);

create or replace function public.decide_application(
  p_application_id uuid,
  p_decision app_status,
  p_note text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app job_applications%rowtype;
  v_job job_posts%rowtype;
  v_me  uuid := public.my_profile_id('owner');
begin
  if p_decision not in ('accepted','rejected') then
    raise exception 'Decision must be accepted or rejected.';
  end if;

  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;

  select * into v_job from job_posts where id = v_app.job_id;
  if v_job.owner_id <> v_me then
    raise exception 'That job posting is not yours.';
  end if;

  if p_decision = 'rejected' and coalesce(trim(p_note), '') = '' then
    raise exception 'Give the applicant a reason for the rejection.';
  end if;

  update job_applications
     set status = p_decision,
         message = case
                     when p_decision = 'rejected'
                     then coalesce(nullif(message, '') || ' | ', '') || 'Reason: ' || trim(p_note)
                     else message
                   end,
         updated_at = now()
   where id = p_application_id;

  insert into notifications (user_id, message, type, link)
  values (v_app.farmer_id,
          case when p_decision = 'accepted'
               then 'You were hired for ' || v_job.title || '.'
               else 'Your application for ' || v_job.title ||
                    ' was not accepted. Reason: ' || trim(p_note)
          end,
          'application', '/farmer/applications');
end $$;

notify pgrst, 'reload schema';
