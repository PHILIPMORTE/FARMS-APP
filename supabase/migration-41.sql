-- ============================================================================
--  FARMS — MIGRATION 41
--  How the buyer pays: cash, GCash, or both, chosen by the farm for each listing.
--
--  WHAT THIS DOES AND DOES NOT DO
--  FARMS records the payment method and, for GCash, the reference number the
--  buyer reports. It does not connect to GCash and moves no money. The buyer
--  pays through their own GCash app; the farm checks its own GCash and then
--  marks the order as paid, exactly as it does for cash.
--
--  PRIVACY
--  The farm's GCash number is kept in its own locked table, not on the farm
--  record. A buyer receives it only for an order they placed with that farm.
--
--  Run migration-40.sql first. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. WHAT EACH LISTING ACCEPTS, AND HOW EACH ORDER IS PAID
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists pay_cash  boolean not null default true,
  add column if not exists pay_gcash boolean not null default false;

alter table public.products drop constraint if exists products_pays_somehow;
alter table public.products
  add constraint products_pays_somehow check (pay_cash or pay_gcash);

alter table public.orders
  add column if not exists payment_method text not null default 'cash',
  add column if not exists gcash_reference text,
  add column if not exists gcash_reference_at timestamptz;

alter table public.orders drop constraint if exists orders_payment_method_valid;
alter table public.orders
  add constraint orders_payment_method_valid check (payment_method in ('cash', 'gcash'));

-- ---------------------------------------------------------------------------
-- 2. THE FARM'S GCASH DETAILS, KEPT PRIVATE
-- Row level security is on and there are no policies, so nothing can read or
-- write this table directly. It is reached only through the functions below.
-- ---------------------------------------------------------------------------
create table if not exists public.farm_payment_details (
  farm_id      uuid primary key references public.farms(id) on delete cascade,
  gcash_number text,
  gcash_name   text,
  updated_at   timestamptz not null default now()
);
alter table public.farm_payment_details enable row level security;

-- A Philippine mobile number, written 09XXXXXXXXX. +63 and 63 forms are accepted
-- and converted.
create or replace function public.clean_gcash_number(p_raw text)
returns text language plpgsql immutable
as $$
declare v text := regexp_replace(coalesce(p_raw, ''), '[^0-9]', '', 'g');
begin
  if v like '63%' and length(v) = 12 then v := '0' || substr(v, 3); end if;
  if v !~ '^09[0-9]{9}$' then
    raise exception 'Enter an 11-digit mobile number that starts with 09.';
  end if;
  return v;
end $$;

create or replace function public.save_gcash_details(p_number text, p_name text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid := public.my_profile_id('owner');
  v_farm  uuid;
begin
  if v_owner is null then raise exception 'Sign in as a farm owner.'; end if;
  select id into v_farm from farms where owner_id = v_owner limit 1;
  if v_farm is null then raise exception 'Set up your farm first.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Enter the name on the GCash account.';
  end if;

  insert into farm_payment_details (farm_id, gcash_number, gcash_name, updated_at)
  values (v_farm, public.clean_gcash_number(p_number), trim(p_name), now())
  on conflict (farm_id) do update
     set gcash_number = excluded.gcash_number,
         gcash_name   = excluded.gcash_name,
         updated_at   = now();
end $$;

create or replace function public.my_gcash_details()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object('gcash_number', d.gcash_number, 'gcash_name', d.gcash_name)
       from farm_payment_details d
       join farms f on f.id = d.farm_id
      where f.owner_id = public.my_profile_id('owner')),
    json_build_object('gcash_number', null, 'gcash_name', null));
$$;

-- ---------------------------------------------------------------------------
-- 3. CHANGING WHAT AN EXISTING LISTING ACCEPTS
-- ---------------------------------------------------------------------------
create or replace function public.set_product_payment(
  p_product_id uuid, p_cash boolean, p_gcash boolean
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid := public.my_profile_id('owner');
  v_p     products%rowtype;
begin
  if v_owner is null then raise exception 'Sign in as a farm owner.'; end if;
  if not (coalesce(p_cash, false) or coalesce(p_gcash, false)) then
    raise exception 'Choose at least one way for buyers to pay: cash or GCash.';
  end if;

  select p.* into v_p from products p
    join farms f on f.id = p.farm_id
   where p.id = p_product_id and f.owner_id = v_owner;
  if not found then raise exception 'That listing is not yours.'; end if;

  if p_gcash and not exists (
    select 1 from farm_payment_details d where d.farm_id = v_p.farm_id and d.gcash_number is not null
  ) then
    raise exception 'Add your GCash number before accepting GCash.';
  end if;

  update products set pay_cash = p_cash, pay_gcash = p_gcash where id = p_product_id;
end $$;

-- ---------------------------------------------------------------------------
-- 4. PAYMENT DETAILS OF ONE ORDER
-- Only the buyer who placed it and the farm that received it may ask. The GCash
-- number is returned only when the order is to be paid by GCash.
-- ---------------------------------------------------------------------------
create or replace function public.order_payment_info(p_order_id uuid)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  o record;
  v_buyer uuid := public.my_profile_id('buyer');
  v_owner uuid := public.my_profile_id('owner');
begin
  select ord.id, ord.buyer_id, ord.total_price, ord.paid, ord.payment_method,
         ord.gcash_reference, ord.gcash_reference_at, ord.stage,
         f.id as farm_id, f.owner_id, f.name as farm_name,
         d.gcash_number, d.gcash_name
    into o
    from orders ord
    join products p on p.id = ord.product_id
    join farms f on f.id = p.farm_id
    left join farm_payment_details d on d.farm_id = f.id
   where ord.id = p_order_id;

  if not found then raise exception 'Order not found.'; end if;
  if not ((v_buyer is not null and o.buyer_id = v_buyer)
       or (v_owner is not null and o.owner_id = v_owner)) then
    raise exception 'That order is not yours.';
  end if;

  return json_build_object(
    'method', o.payment_method,
    'paid', o.paid,
    'amount', o.total_price,
    'farm_name', o.farm_name,
    'stage', o.stage,
    'reference', o.gcash_reference,
    'reference_at', o.gcash_reference_at,
    'gcash_number', case when o.payment_method = 'gcash' then o.gcash_number end,
    'gcash_name',   case when o.payment_method = 'gcash' then o.gcash_name end
  );
end $$;

-- ---------------------------------------------------------------------------
-- 5. THE BUYER REPORTS THEIR GCASH REFERENCE
-- ---------------------------------------------------------------------------
create or replace function public.submit_gcash_reference(p_order_id uuid, p_reference text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_buyer uuid := public.my_profile_id('buyer');
  v_ref   text := upper(regexp_replace(coalesce(p_reference, ''), '\s', '', 'g'));
  o       record;
begin
  if v_buyer is null then raise exception 'Sign in as a buyer.'; end if;
  if v_ref !~ '^[A-Z0-9]{8,20}$' then
    raise exception 'Enter the reference number shown in your GCash receipt (letters and numbers only).';
  end if;

  select ord.id, ord.paid, ord.payment_method, ord.stage, f.owner_id,
         pr.variety, pr.crop, ord.quantity
    into o
    from orders ord
    join products pr on pr.id = ord.product_id
    join farms f on f.id = pr.farm_id
   where ord.id = p_order_id and ord.buyer_id = v_buyer;

  if not found then raise exception 'That order is not yours.'; end if;
  if o.payment_method <> 'gcash' then raise exception 'This order is paid in cash.'; end if;
  if o.paid then raise exception 'This order is already marked as paid.'; end if;
  if o.stage = 'cancelled' then raise exception 'This order was cancelled.'; end if;

  update orders set gcash_reference = v_ref, gcash_reference_at = now() where id = p_order_id;

  insert into notifications (user_id, message, type, link)
  values (o.owner_id,
          (select name from profiles where id = v_buyer) || ' sent GCash reference ' || v_ref ||
          ' for ' || public.unit_phrase(o.crop, o.quantity) || ' of ' || o.variety ||
          '. Check your GCash, then mark the order as paid.',
          'general', '/owner/orders');
end $$;

-- ---------------------------------------------------------------------------
-- 6. ORDERING AND LISTING, NOW WITH A PAYMENT METHOD
-- The older versions took fewer arguments. They are dropped so a call can only
-- reach the new ones.
-- ---------------------------------------------------------------------------
drop function if exists public.purchase_product(uuid, integer);
drop function if exists public.add_or_merge_product(uuid, text, crop_type, integer, numeric, product_form);

create or replace function public.purchase_product(
  p_product_id uuid,
  p_quantity int,
  p_payment_method text default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_product    products%rowtype;
  v_buyer      uuid := public.my_profile_id('buyer');
  v_qty        int  := floor(p_quantity)::int;
  v_total      numeric(12,2);
  v_order_id   uuid;
  v_method     text;
  v_farm       farms%rowtype;
  v_buyer_name text;
  v_available  int;
begin
  if v_buyer is null then
    raise exception 'Sign in as a buyer to place an order.';
  end if;
  if v_qty < 1 then
    raise exception 'Enter a quantity of at least 1.';
  end if;

  select * into v_product from products where id = p_product_id for update;
  if not found then
    raise exception 'That listing is no longer available.';
  end if;

  v_available := greatest(v_product.quantity - v_product.reserved, 0);

  if v_available <= 0 or v_product.status = 'sold' then
    raise exception 'This product is out of stock.';
  end if;
  if v_qty > v_available then
    raise exception 'Only % left. Lower your quantity to continue.',
      public.unit_phrase(v_product.crop, v_available);
  end if;

  v_total := v_qty * v_product.price;

  select * into v_farm from farms where id = v_product.farm_id;
  select name into v_buyer_name from profiles where id = v_buyer;

  -- How the buyer will pay. It must be one the farm accepts for this product.
  v_method := lower(coalesce(nullif(trim(p_payment_method), ''),
                             case when v_product.pay_cash then 'cash' else 'gcash' end));
  if v_method not in ('cash', 'gcash') then
    raise exception 'Choose cash or GCash.';
  end if;
  if (v_method = 'cash' and not v_product.pay_cash)
     or (v_method = 'gcash' and not v_product.pay_gcash) then
    raise exception 'This farm does not accept % for this product.',
      case when v_method = 'cash' then 'cash' else 'GCash' end;
  end if;

  insert into orders (buyer_id, product_id, quantity, total_price, status, stage, payment_method)
  values (v_buyer, p_product_id, v_qty, v_total, 'pending', 'placed', v_method)
  returning id into v_order_id;

  insert into order_events (order_id, stage, note, changed_by)
  values (v_order_id, 'placed', 'Order placed by the buyer', v_buyer);

  update products
     set reserved = reserved + v_qty,
         status = case
                    when quantity - (reserved + v_qty) <= 0 then 'reserved'::product_status
                    else status
                  end
   where id = p_product_id;

  insert into notifications (user_id, message, type, link) values
    (v_farm.owner_id,
     coalesce(v_buyer_name,'A buyer') || ' ordered ' || public.unit_phrase(v_product.crop, v_qty) || ' of ' || v_product.variety
       || ' (pays by ' || case when v_method = 'gcash' then 'GCash' else 'cash' end || ')',
     'sale', '/owner/orders'),
    (v_buyer,
     'Order placed: ' || public.unit_phrase(v_product.crop, v_qty) || ' of ' || v_product.variety || ' from ' || coalesce(v_farm.name,'the farm'),
     'purchase', '/buyer/orders');

  return v_order_id;
end $$;

create or replace function public.add_or_merge_product(
  p_farm_id uuid,
  p_variety text,
  p_crop crop_type,
  p_quantity int,
  p_price numeric,
  p_form product_form default 'unmilled',
  p_pay_cash boolean default null,
  p_pay_gcash boolean default null
)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_form     product_form := case when p_crop = 'rice' then p_form else 'unmilled' end;
  v_existing products%rowtype;
  v_qty      int := floor(p_quantity)::int;
  v_me       uuid := public.my_profile_id('owner');
  v_id       uuid;
  v_merged   boolean := false;
begin
  -- Payment methods are only checked, and only changed, when they are passed.
  -- Recording a harvest lists produce without passing them, and must not
  -- disturb what an existing listing already accepts.
  if p_pay_cash is not null and p_pay_gcash is not null
     and not (p_pay_cash or p_pay_gcash) then
    raise exception 'Choose at least one way for buyers to pay: cash or GCash.';
  end if;
  if coalesce(p_pay_gcash, false) and not exists (
    select 1 from farm_payment_details d where d.farm_id = p_farm_id and d.gcash_number is not null
  ) then
    raise exception 'Add your GCash number before accepting GCash.';
  end if;
  if not public.owns_farm(p_farm_id) then
    raise exception 'You can only add products to your own farm.';
  end if;
  if v_qty < 1 then
    raise exception 'Enter a quantity of at least 1.';
  end if;

  select * into v_existing
    from products
   where farm_id = p_farm_id
     and crop = p_crop
     and form = v_form
     and lower(trim(variety)) = lower(trim(p_variety))
   order by created_at
   limit 1
   for update;

  if found then
    update products
       set quantity = v_existing.quantity + v_qty,
           price    = p_price,
           pay_cash = coalesce(p_pay_cash, pay_cash),
           pay_gcash = coalesce(p_pay_gcash, pay_gcash),
           status   = case when v_existing.quantity + v_qty > v_existing.reserved
                           then 'available'::product_status else status end
     where id = v_existing.id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_existing.id, p_farm_id, v_me, v_existing.quantity,
            v_existing.quantity + v_qty,
            'Added ' || public.unit_phrase(p_crop, v_qty) || ' to the existing listing', 'manual');

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into products (farm_id, variety, crop, quantity, price, status, form, pay_cash, pay_gcash)
    values (p_farm_id, trim(p_variety), p_crop, v_qty, p_price, 'available', v_form,
            coalesce(p_pay_cash, true), coalesce(p_pay_gcash, false))
    returning id into v_id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_id, p_farm_id, v_me, 0, v_qty, 'New listing created', 'manual');
  end if;

  insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

grant execute on function public.clean_gcash_number(text) to authenticated;
grant execute on function public.save_gcash_details(text, text) to authenticated;
grant execute on function public.my_gcash_details() to authenticated;
grant execute on function public.set_product_payment(uuid, boolean, boolean) to authenticated;
grant execute on function public.order_payment_info(uuid) to authenticated;
grant execute on function public.submit_gcash_reference(uuid, text) to authenticated;
grant execute on function public.purchase_product(uuid, integer, text) to authenticated;
grant execute on function public.add_or_merge_product(uuid, text, crop_type, integer, numeric, product_form, boolean, boolean) to authenticated;

notify pgrst, 'reload schema';
