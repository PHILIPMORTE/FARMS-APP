-- ============================================================================
--  FARMS — MIGRATION 22
--  The farm location is captured during verification, so the map marker
--  exists from the moment the account is approved.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.owner_verifications
  add column if not exists latitude  numeric(10,7),
  add column if not exists longitude numeric(10,7);

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
    if exists (select 1 from farms where owner_id = v_row.profile_id) then
      update farms
         set latitude  = coalesce(v_row.latitude, latitude),
             longitude = coalesce(v_row.longitude, longitude)
       where owner_id = v_row.profile_id;
    else
      insert into farms (owner_id, name, address, city, latitude, longitude)
      values (v_row.profile_id,
              coalesce(nullif(v_row.farm_name,''), 'My Farm'),
              v_row.farm_address, v_row.barangay,
              v_row.latitude, v_row.longitude);
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

create or replace function public.farm_profile(p_farm_id uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'farm', (select json_build_object(
               'id', f.id, 'name', f.name, 'city', f.city,
               'province', f.province, 'address', f.address,
               'latitude', f.latitude, 'longitude', f.longitude)
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

notify pgrst, 'reload schema';
