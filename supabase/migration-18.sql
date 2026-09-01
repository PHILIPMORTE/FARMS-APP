-- ============================================================================
--  FARMS — MIGRATION 18
--  A farm may work several fields, so the same crop can be planted more than
--  once on the same day. Migration 17's one-per-day rule is removed.
--  Adds planting cancellation and a public farm profile for buyers.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

drop index if exists public.schedules_one_crop_per_day;
drop index if exists public.schedules_no_duplicates;

-- Plantings closed automatically by migration 17 are restored, since the rule
-- that closed them no longer applies.
update public.schedules
   set status = case when actual_sacks is not null then 'harvested'::schedule_status
                     else 'planted'::schedule_status end,
       note = nullif(
         btrim(replace(coalesce(note, ''),
           'Closed automatically: another planting of this crop exists on the same day', ''),
           ' |'), '')
 where status = 'cancelled'
   and note like '%another planting of this crop exists on the same day%';

-- ---------------------------------------------------------------------------
-- CANCEL A PLANTING
-- Nothing is deleted. The row is marked cancelled so the costs recorded
-- against it stay in the books.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_schedule(p_schedule_id uuid, p_reason text default '')
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_sched schedules%rowtype;
begin
  select * into v_sched from schedules where id = p_schedule_id for update;
  if not found then raise exception 'That planting no longer exists.'; end if;
  if not public.owns_farm(v_sched.farm_id) then
    raise exception 'You can only cancel your own plantings.';
  end if;
  if v_sched.status = 'harvested' then
    raise exception 'This planting was already harvested, so it cannot be cancelled.';
  end if;
  if v_sched.status = 'cancelled' then
    return;
  end if;

  update schedules
     set status = 'cancelled',
         note = coalesce(nullif(note, '') || ' | ', '') ||
                coalesce(nullif(p_reason, ''), 'Cancelled by the farm owner')
   where id = p_schedule_id;
end $$;

grant execute on function public.cancel_schedule(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- FARM PROFILE FOR BUYERS
-- Everything a buyer may see about a farm: its listings and what sells best.
-- ---------------------------------------------------------------------------
create or replace function public.farm_profile(p_farm_id uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'farm', (select json_build_object(
               'id', f.id, 'name', f.name, 'city', f.city,
               'province', f.province, 'address', f.address)
               from farms f where f.id = p_farm_id),
    'products', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'variety', p.variety, 'crop', p.crop, 'price', p.price,
        'quantity', p.quantity, 'reserved', p.reserved,
        'photo_url', p.photo_url, 'status', p.status)
        order by (p.quantity - p.reserved) <= 0, p.variety)
        from products p where p.farm_id = p_farm_id), '[]'::json),
    'best_sellers', coalesce((
      select json_agg(x) from (
        select p.variety, p.crop, p.photo_url,
               sum(o.quantity)::int as sacks_sold,
               count(*)::int as orders
          from orders o
          join products p on p.id = o.product_id
         where p.farm_id = p_farm_id and o.stage = 'completed'
         group by p.variety, p.crop, p.photo_url
         order by sum(o.quantity) desc
         limit 3
      ) x), '[]'::json),
    'total_sold', coalesce((
      select sum(o.quantity)::int from orders o
      join products p on p.id = o.product_id
      where p.farm_id = p_farm_id and o.stage = 'completed'), 0)
  );
$$;

grant execute on function public.farm_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- WHAT A BUYER HAS BOUGHT FROM THIS FARM
-- ---------------------------------------------------------------------------
create or replace function public.buyer_orders_for_my_farm(p_buyer_id uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce((
    select json_agg(json_build_object(
      'id', o.id, 'variety', p.variety, 'crop', p.crop, 'photo_url', p.photo_url,
      'quantity', o.quantity, 'total_price', o.total_price, 'price', p.price,
      'stage', o.stage, 'paid', o.paid, 'created_at', o.created_at)
      order by o.created_at desc)
      from orders o
      join products p on p.id = o.product_id
      join farms f on f.id = p.farm_id
     where o.buyer_id = p_buyer_id
       and f.owner_id = public.my_profile_id('owner')
  ), '[]'::json);
$$;

grant execute on function public.buyer_orders_for_my_farm(uuid) to authenticated;

notify pgrst, 'reload schema';
