-- ============================================================================
--  FARMS — MIGRATION 16
--  Record when a harvest was actually entered, and let the owner change a
--  listing's price as well as its stock.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.schedules
  add column if not exists harvested_at timestamptz;

update public.schedules
   set harvested_at = coalesce(harvested_at, harvest_date::timestamptz)
 where status = 'harvested' and harvested_at is null;

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
  if v_sacks < 0 then raise exception 'Sacks cannot be negative.'; end if;

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
         'Harvest recorded: ' || v_sacks || ' sacks of ' || v_variety || '.',
         'harvest', '/owner/calendar'
    from farms f where f.id = v_sched.farm_id;

  select json_build_object('sacks', v_sacks, 'product_id', v_pid) into v_result;
  return v_result;
end $$;

-- ---------------------------------------------------------------------------
-- Price changes are audited alongside stock changes, so a listing's history
-- shows both what was adjusted and by whom.
-- ---------------------------------------------------------------------------
create or replace function public.update_product_listing(
  p_product_id uuid,
  p_new_quantity int,
  p_new_price numeric,
  p_reason text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_product products%rowtype;
  v_me      uuid := public.my_profile_id('owner');
  v_qty     int  := floor(p_new_quantity)::int;
begin
  if v_qty < 0 then
    raise exception 'Stock cannot be negative.';
  end if;
  if p_new_price is null or p_new_price < 0 then
    raise exception 'Enter a valid price.';
  end if;

  select * into v_product from products where id = p_product_id for update;
  if not found then
    raise exception 'That product no longer exists.';
  end if;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only change your own products.';
  end if;

  if v_qty < v_product.reserved then
    raise exception 'You have % sack(s) reserved by open orders, so stock cannot go below that.',
      v_product.reserved;
  end if;

  update products
     set quantity = v_qty,
         price    = p_new_price,
         status = case
                    when v_qty - v_product.reserved <= 0 then 'sold'::product_status
                    else 'available'::product_status
                  end
   where id = p_product_id;

  if v_qty <> v_product.quantity then
    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (p_product_id, v_product.farm_id, v_me, v_product.quantity, v_qty,
            coalesce(nullif(p_reason, ''), 'Stock updated'),
            case when public.is_admin() then 'admin' else 'manual' end);
  end if;

  if p_new_price <> v_product.price then
    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (p_product_id, v_product.farm_id, v_me, v_qty, v_qty,
            'Price changed from PHP ' || v_product.price || ' to PHP ' || p_new_price,
            case when public.is_admin() then 'admin' else 'manual' end);
  end if;
end $$;

grant execute on function public.update_product_listing(uuid, int, numeric, text) to authenticated;

notify pgrst, 'reload schema';
