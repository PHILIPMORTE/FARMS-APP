-- ============================================================================
--  FARMS — MIGRATION 8
--  Reserved stock, buyer-side cancellation, and inventory linked to listings.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- RESERVED STOCK
-- Sacks are no longer taken off the shelf the moment an order is placed. They
-- are reserved instead, and only deducted when the order completes. Without a
-- reservation, two buyers could each order the last 10 sacks and both succeed,
-- so "available" is now quantity minus reserved.
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists reserved int not null default 0 check (reserved >= 0);

create or replace function public.available_stock(p_product products)
returns int language sql immutable as $$
  select greatest(p_product.quantity - p_product.reserved, 0);
$$;

-- ---------------------------------------------------------------------------
-- PURCHASE — reserves rather than deducts
-- ---------------------------------------------------------------------------
create or replace function public.purchase_product(p_product_id uuid, p_quantity int)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_product    products%rowtype;
  v_buyer      uuid := public.my_profile_id('buyer');
  v_qty        int  := floor(p_quantity)::int;
  v_total      numeric(12,2);
  v_order_id   uuid;
  v_farm       farms%rowtype;
  v_buyer_name text;
  v_available  int;
begin
  if v_buyer is null then
    raise exception 'Sign in as a buyer to place an order.';
  end if;
  if v_qty < 1 then
    raise exception 'Order at least 1 sack.';
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
    raise exception 'Only % sack(s) left. Lower your quantity to continue.', v_available;
  end if;

  v_total := v_qty * v_product.price;

  select * into v_farm from farms where id = v_product.farm_id;
  select name into v_buyer_name from profiles where id = v_buyer;

  insert into orders (buyer_id, product_id, quantity, total_price, status, stage)
  values (v_buyer, p_product_id, v_qty, v_total, 'pending', 'placed')
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
     coalesce(v_buyer_name,'A buyer') || ' ordered ' || v_qty || ' sacks of ' || v_product.variety,
     'sale', '/owner/orders'),
    (v_buyer,
     'Order placed: ' || v_qty || ' sacks of ' || v_product.variety || ' from ' || coalesce(v_farm.name,'the farm'),
     'purchase', '/buyer/orders');

  return v_order_id;
end $$;

-- ---------------------------------------------------------------------------
-- STAGE CHANGES — stock leaves on completion, reservation releases on cancel.
-- Income is booked at completion too, so the books follow the goods.
-- ---------------------------------------------------------------------------
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
            'Order completed - ' || v_order.quantity || ' sack(s) released to ' ||
            coalesce(v_buyer,'the buyer'), 'order');

    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_product.farm_id, 'income', 'Crop Sales', v_order.total_price,
            v_order.quantity || ' sacks of ' || v_product.variety || ' sold to ' ||
            coalesce(v_buyer,'a buyer'), current_date);
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
end $$;

-- ---------------------------------------------------------------------------
-- BUYER CANCELLATION
-- A buyer may withdraw their own order until the farm has started preparing it.
-- ---------------------------------------------------------------------------
create or replace function public.buyer_cancel_order(p_order_id uuid, p_reason text default '')
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_order   orders%rowtype;
  v_product products%rowtype;
  v_farm    farms%rowtype;
  v_me      uuid := public.my_profile_id('buyer');
  v_name    text;
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  if v_order.buyer_id <> v_me then
    raise exception 'You can only cancel your own orders.';
  end if;
  if v_order.stage in ('completed','cancelled') then
    raise exception 'This order can no longer be cancelled.';
  end if;
  if v_order.stage not in ('placed','confirmed') then
    raise exception 'The farm has already started preparing this order. Contact them directly to cancel.';
  end if;

  select * into v_product from products where id = v_order.product_id for update;
  select * into v_farm from farms where id = v_product.farm_id;
  select name into v_name from profiles where id = v_me;

  update products
     set reserved = greatest(reserved - v_order.quantity, 0),
         status = case when status = 'reserved' then 'available'::product_status else status end
   where id = v_product.id;

  update orders
     set stage = 'cancelled',
         status = 'cancelled',
         cancel_reason = coalesce(nullif(p_reason,''), 'Cancelled by the buyer'),
         updated_at = now()
   where id = p_order_id;

  insert into order_events (order_id, stage, note, changed_by)
  values (p_order_id, 'cancelled',
          coalesce(nullif(p_reason,''), 'Cancelled by the buyer'), v_me);

  insert into notifications (user_id, message, type, link)
  values (v_farm.owner_id,
          coalesce(v_name,'A buyer') || ' cancelled their order of ' || v_product.variety,
          'order_status', '/owner/orders');
end $$;

grant execute on function public.buyer_cancel_order(uuid, text) to authenticated;

-- Buyers need to update their own order row for the cancellation to stick.
drop policy if exists orders_update_buyer on public.orders;
create policy orders_update_buyer on public.orders for update to authenticated
  using (public.is_mine(buyer_id));

-- ---------------------------------------------------------------------------
-- LISTING A PRODUCT ALSO RECORDS IT IN INVENTORY
-- The dashboard counts sacks from the inventory table, so a new listing has to
-- appear there or the home page shows zero while the market shows stock.
-- ---------------------------------------------------------------------------
create or replace function public.add_or_merge_product(
  p_farm_id uuid,
  p_variety text,
  p_crop crop_type,
  p_quantity int,
  p_price numeric
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
     and lower(trim(variety)) = lower(trim(p_variety))
   order by created_at
   limit 1
   for update;

  if found then
    update products
       set quantity = v_existing.quantity + v_qty,
           price    = p_price,
           status   = case when v_existing.quantity + v_qty > v_existing.reserved
                           then 'available'::product_status
                           else status end
     where id = v_existing.id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_existing.id, p_farm_id, v_me, v_existing.quantity,
            v_existing.quantity + v_qty,
            'Added ' || v_qty || ' sack(s) to the existing listing', 'manual');

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into products (farm_id, variety, crop, quantity, price, status)
    values (p_farm_id, trim(p_variety), p_crop, v_qty, p_price, 'available')
    returning id into v_id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_id, p_farm_id, v_me, 0, v_qty, 'New listing created', 'manual');
  end if;

  insert into inventory (farm_id, crop, quantity)
  values (p_farm_id, p_crop, v_qty);

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

notify pgrst, 'reload schema';
