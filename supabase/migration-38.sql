-- ============================================================================
--  FARMS — MIGRATION 38
--  Watermelon is counted in pieces and estimated from how the crop actually
--  grows; milling is offered for rice only.
--
--  WHY THE WATERMELON MODEL CHANGED
--  The earlier model treated watermelon like a grain: so many kilograms of fruit
--  for every kilogram of seed. A watermelon is a spreading vine. A farmer sows
--  several seeds per hill, thins to one plant, and each plant sets more than
--  one fruit. So the estimate now runs through the real chain:
--
--      seed weight  ->  number of seeds  ->  hills sown  ->  plants
--                   ->  fruits per plant ->  marketable fruits (pieces)
--                   ->  weight, from the average fruit weight of the variety
--
--  Land needed follows from the hills sown and the spacing, not from a seed
--  weight per hectare.
--
--  The figures used (22 seeds per gram, 4 seeds per hill, 2 m2 per hill,
--  1 plant per hill, 1.5 to 2 fruits per plant, 4 to 5 kg per fruit) come from
--  published growing guides. They are stored in crop_yields so they can be
--  corrected against local practice without changing any code.
--
--  Run migration-37.sql first. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. THE GROWING MODEL, PER VARIETY
-- ---------------------------------------------------------------------------
alter table public.crop_yields
  add column if not exists seeds_per_gram     numeric(8,2),
  add column if not exists seeds_per_hill     numeric(4,1),
  add column if not exists hill_area_m2       numeric(6,2),
  add column if not exists plants_per_hill    numeric(4,1),
  add column if not exists fruits_per_plant   numeric(5,2),
  add column if not exists marketable_fraction numeric(4,2),
  add column if not exists avg_fruit_kg       numeric(6,2);

-- General watermelon profile, used when a variety is not listed.
update public.crop_yields set
  seeds_per_gram = 22, seeds_per_hill = 4, hill_area_m2 = 2.0, plants_per_hill = 1,
  fruits_per_plant = 1.5, marketable_fraction = 0.80, avg_fruit_kg = 5.0,
  kg_per_kg_seed = 33000
 where crop = 'watermelon' and variety = '';

-- Sugar Baby: a small-fruited variety, so more fruit per vine, each lighter.
update public.crop_yields set
  seeds_per_gram = 22, seeds_per_hill = 4, hill_area_m2 = 2.0, plants_per_hill = 1,
  fruits_per_plant = 2.0, marketable_fraction = 0.80, avg_fruit_kg = 4.0,
  kg_per_kg_seed = 35200
 where crop = 'watermelon' and variety = 'Sugar Baby';

-- Sweet Beauty has no published profile of its own, so it uses the general one.
update public.crop_yields set
  seeds_per_gram = 22, seeds_per_hill = 4, hill_area_m2 = 2.0, plants_per_hill = 1,
  fruits_per_plant = 1.5, marketable_fraction = 0.80, avg_fruit_kg = 5.0,
  kg_per_kg_seed = 33000
 where crop = 'watermelon' and variety = 'Sweet Beauty';

-- Seed per hectare for watermelon follows from the model: 4 seeds x 5,000 hills
-- per hectare / 22 seeds per gram = about 0.91 kg.
update public.crop_yields set kg_seed_per_hectare = 0.91 where crop = 'watermelon';

-- ---------------------------------------------------------------------------
-- 2. WORDS FOR THE UNIT
-- A watermelon is counted in pieces; rice and corn in sacks.
-- ---------------------------------------------------------------------------
create or replace function public.unit_word(p_crop crop_type, p_n numeric default 2)
returns text language sql immutable
as $$
  select case
           when p_crop = 'watermelon' then case when p_n = 1 then 'piece' else 'pieces' end
           else case when p_n = 1 then 'sack' else 'sacks' end
         end;
$$;

create or replace function public.unit_phrase(p_crop crop_type, p_n numeric)
returns text language sql immutable
as $$
  select trim_scale(p_n)::text || ' ' || public.unit_word(p_crop, p_n);
$$;

grant execute on function public.unit_word(crop_type, numeric) to authenticated;
grant execute on function public.unit_phrase(crop_type, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. LAND NEEDED
-- ---------------------------------------------------------------------------
create or replace function public.land_needed(p_crop crop_type, p_variety text, p_seed_kg numeric)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  r      crop_yields%rowtype;
  v_ha   numeric;
  v_seeds numeric;
  v_hills numeric;
begin
  select * into r from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));
  if not found then
    select * into r from crop_yields where crop = p_crop and variety = '';
  end if;

  if p_crop = 'watermelon' and r.seeds_per_gram is not null then
    v_seeds := coalesce(p_seed_kg, 0) * 1000 * r.seeds_per_gram;
    v_hills := floor(v_seeds / r.seeds_per_hill);
    return json_build_object(
      'hectares', round(v_hills * r.hill_area_m2 / 10000, 4),
      'sqm',      round(v_hills * r.hill_area_m2, 2),
      'kg_per_hectare', r.kg_seed_per_hectare,
      'seeds',    floor(v_seeds),
      'hills',    v_hills,
      'plants',   floor(v_hills * r.plants_per_hill)
    );
  end if;

  if coalesce(r.kg_seed_per_hectare, 0) <= 0 then
    return json_build_object('hectares', 0, 'sqm', 0, 'kg_per_hectare', 0);
  end if;

  v_ha := coalesce(p_seed_kg, 0) / r.kg_seed_per_hectare;
  return json_build_object(
    'hectares', round(v_ha, 4),
    'sqm', round(v_ha * 10000, 2),
    'kg_per_hectare', r.kg_seed_per_hectare
  );
end $$;

grant execute on function public.land_needed(crop_type, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. HARVEST ESTIMATE
-- expected_sacks keeps its name so older code keeps working; it holds the count
-- in the crop's own unit (pieces for watermelon). 'unit' says which.
-- ---------------------------------------------------------------------------
create or replace function public.estimate_harvest(
  p_crop crop_type,
  p_variety text,
  p_seed_kg numeric
)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  r        crop_yields%rowtype;
  v_kg     numeric;
  v_seeds  numeric;
  v_hills  numeric;
  v_plants numeric;
  v_pieces numeric;
begin
  select * into r from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));
  if not found then
    select * into r from crop_yields where crop = p_crop and variety = '';
  end if;

  if p_crop = 'watermelon' and r.seeds_per_gram is not null then
    v_seeds  := coalesce(p_seed_kg, 0) * 1000 * r.seeds_per_gram;
    v_hills  := floor(v_seeds / r.seeds_per_hill);
    v_plants := floor(v_hills * r.plants_per_hill);
    v_pieces := floor(v_plants * r.fruits_per_plant * r.marketable_fraction);
    v_kg     := v_pieces * r.avg_fruit_kg;

    return json_build_object(
      'unit', 'piece',
      'days_to_harvest', coalesce(r.days_to_harvest, 80),
      'expected_kg', round(v_kg, 2),
      'expected_sacks', v_pieces::int,
      'expected_units', v_pieces::int,
      'expected_pieces', v_pieces::int,
      'seeds', floor(v_seeds),
      'hills', v_hills,
      'plants', v_plants,
      'fruits_per_plant', r.fruits_per_plant,
      'avg_fruit_kg', r.avg_fruit_kg,
      'kg_per_kg_seed', r.kg_per_kg_seed
    );
  end if;

  v_kg := coalesce(p_seed_kg, 0) * coalesce(r.kg_per_kg_seed, 0);
  return json_build_object(
    'unit', 'sack',
    'kg_per_kg_seed', coalesce(r.kg_per_kg_seed, 0),
    'days_to_harvest', coalesce(r.days_to_harvest, 100),
    'expected_kg', round(v_kg, 2),
    'expected_sacks', floor(v_kg / 25)::int,
    'expected_units', floor(v_kg / 25)::int
  );
end $$;

grant execute on function public.estimate_harvest(crop_type, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. MILLING APPLIES TO RICE ONLY
-- ---------------------------------------------------------------------------
update public.products set form = 'unmilled' where crop <> 'rice' and form = 'milled';

alter table public.products drop constraint if exists products_milled_rice_only;
alter table public.products
  add constraint products_milled_rice_only check (form = 'unmilled' or crop = 'rice');

-- ---------------------------------------------------------------------------
-- 6. MESSAGES THAT NAME THE RIGHT UNIT
-- Same logic as before; only the wording follows the crop.
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
     coalesce(v_buyer_name,'A buyer') || ' ordered ' || public.unit_phrase(v_product.crop, v_qty) || ' of ' || v_product.variety,
     'sale', '/owner/orders'),
    (v_buyer,
     'Order placed: ' || public.unit_phrase(v_product.crop, v_qty) || ' of ' || v_product.variety || ' from ' || coalesce(v_farm.name,'the farm'),
     'purchase', '/buyer/orders');

  return v_order_id;
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
            'Order completed - ' || public.unit_phrase(v_product.crop, v_order.quantity) || ' released to ' ||
            coalesce(v_buyer,'the buyer'), 'order');

    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_product.farm_id, 'income', 'Crop Sales', v_order.total_price,
            public.unit_phrase(v_product.crop, v_order.quantity) || ' of ' || v_product.variety || ' sold to ' ||
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

create or replace function public.harvest_schedule(
  p_schedule_id uuid,
  p_actual_sacks int,
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
  v_form     product_form := case when p_crop = 'rice' then p_form else 'unmilled' end;
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
    insert into products (farm_id, variety, crop, quantity, price, status, form)
    values (p_farm_id, trim(p_variety), p_crop, v_qty, p_price, 'available', v_form)
    returning id into v_id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_id, p_farm_id, v_me, 0, v_qty, 'New listing created', 'manual');
  end if;

  insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

-- ---------------------------------------------------------------------------
-- 7. EXISTING WATERMELON PLANTINGS
-- Plantings that are still growing were estimated with the old grain-style
-- figure. They are re-estimated with the new model so the calendar agrees with
-- what a new entry would show. Harvested and cancelled plantings are left
-- exactly as recorded.
--
-- A planting entered earlier as "2" (kilograms) is now read as 2 kg = 2,000 g.
-- If any of your test plantings look far too large, cancel and re-enter them in
-- grams.
-- ---------------------------------------------------------------------------
update public.schedules s
   set expected_sacks = (public.estimate_harvest(s.crop, s.variety, s.seed_kg) ->> 'expected_sacks')::int
 where s.crop = 'watermelon'
   and s.status not in ('harvested', 'cancelled');


notify pgrst, 'reload schema';
