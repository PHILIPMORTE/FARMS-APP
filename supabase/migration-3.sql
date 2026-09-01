-- ============================================================================
--  FARMS — MIGRATION 3
--  Top-selling farms leaderboard.
--
--  Run this in the Supabase SQL Editor after migration-2b.sql.
--  Safe to run more than once.
-- ============================================================================

-- ============================================================================
-- TOP SELLING FARMS
-- Ranks farms by sales value over a window of days. Cancelled orders are left
-- out, so a cancelled sale never inflates a farm's position.
--
-- Runs as SECURITY DEFINER and returns only aggregates — farm name, totals and
-- rank — so a buyer can see the board without gaining read access to anyone's
-- order rows.
--
--   p_days: 7 for this week, 30 for the month, 0 for all time
--   p_limit: how many farms to return
-- ============================================================================
create or replace function public.top_selling_farms(
  p_days int default 7,
  p_limit int default 10
)
returns table (
  rank         bigint,
  farm_id      uuid,
  farm_name    text,
  owner_name   text,
  city         text,
  order_count  bigint,
  sacks_sold   bigint,
  total_sales  numeric
)
language sql stable security definer set search_path = public
as $$
  select
    row_number() over (order by sum(o.total_price) desc) as rank,
    f.id,
    f.name,
    p.name,
    f.city,
    count(o.id),
    sum(o.quantity)::bigint,
    sum(o.total_price)
  from orders o
  join products pr on pr.id = o.product_id
  join farms    f  on f.id  = pr.farm_id
  join profiles p  on p.id  = f.owner_id
  where o.stage <> 'cancelled'
    and (p_days <= 0 or o.created_at >= now() - make_interval(days => p_days))
  group by f.id, f.name, p.name, f.city
  order by sum(o.total_price) desc
  limit greatest(p_limit, 1);
$$;

revoke all on function public.top_selling_farms(int, int) from public;
grant execute on function public.top_selling_farms(int, int) to authenticated;

-- ============================================================================
-- BEST SELLING PRODUCTS
-- The same idea one level down: which varieties are actually moving.
-- ============================================================================
create or replace function public.top_selling_products(
  p_days int default 7,
  p_limit int default 5
)
returns table (
  variety     text,
  crop        text,
  farm_name   text,
  sacks_sold  bigint,
  total_sales numeric
)
language sql stable security definer set search_path = public
as $$
  select
    pr.variety,
    pr.crop::text,
    f.name,
    sum(o.quantity)::bigint,
    sum(o.total_price)
  from orders o
  join products pr on pr.id = o.product_id
  join farms    f  on f.id  = pr.farm_id
  where o.stage <> 'cancelled'
    and (p_days <= 0 or o.created_at >= now() - make_interval(days => p_days))
  group by pr.variety, pr.crop, f.name
  order by sum(o.quantity) desc
  limit greatest(p_limit, 1);
$$;

revoke all on function public.top_selling_products(int, int) from public;
grant execute on function public.top_selling_products(int, int) to authenticated;

-- ============================================================================
-- MY FARM'S SALES
-- Lets an owner see their own totals and position without exposing the whole
-- board's underlying rows.
-- ============================================================================
create or replace function public.my_farm_sales(p_days int default 7)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_farm uuid;
  v_res  json;
begin
  select f.id into v_farm
    from farms f
    join profiles p on p.id = f.owner_id
   where p.user_id = auth.uid() and p.role = 'owner'
   limit 1;

  if v_farm is null then
    return json_build_object('rank', null, 'orders', 0, 'sacks', 0, 'sales', 0, 'farms', 0);
  end if;

  with board as (
    select f.id,
           row_number() over (order by sum(o.total_price) desc) as rank,
           count(o.id)                as orders,
           sum(o.quantity)::bigint    as sacks,
           sum(o.total_price)         as sales
      from orders o
      join products pr on pr.id = o.product_id
      join farms    f  on f.id  = pr.farm_id
     where o.stage <> 'cancelled'
       and (p_days <= 0 or o.created_at >= now() - make_interval(days => p_days))
     group by f.id
  )
  select json_build_object(
    'rank',   (select rank   from board where id = v_farm),
    'orders', coalesce((select orders from board where id = v_farm), 0),
    'sacks',  coalesce((select sacks  from board where id = v_farm), 0),
    'sales',  coalesce((select sales  from board where id = v_farm), 0),
    'farms',  (select count(*) from board)
  ) into v_res;

  return v_res;
end $$;

revoke all on function public.my_farm_sales(int) from public;
grant execute on function public.my_farm_sales(int) to authenticated;

notify pgrst, 'reload schema';
