-- ============================================================================
--  FARMS — MIGRATION 28
--  An administrator can remove an account. Deleting a profile cascades to
--  everything that hangs off it, so the impact is reported first and there
--  are guards against removing the wrong thing.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- WHAT WOULD BE LOST
-- Called before deleting so the administrator sees the consequence.
-- ---------------------------------------------------------------------------
create or replace function public.admin_user_impact(p_profile_id uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'name', (select name from profiles where id = p_profile_id),
    'phone', (select phone from profiles where id = p_profile_id),
    'role', (select role::text from profiles where id = p_profile_id),
    'farms', (select count(*) from farms where owner_id = p_profile_id),
    'products', (select count(*) from products p
                   join farms f on f.id = p.farm_id
                  where f.owner_id = p_profile_id),
    'orders_placed', (select count(*) from orders where buyer_id = p_profile_id),
    'orders_received', (select count(*) from orders o
                          join products p on p.id = o.product_id
                          join farms f on f.id = p.farm_id
                         where f.owner_id = p_profile_id),
    'job_posts', (select count(*) from job_posts where owner_id = p_profile_id),
    'applications', (select count(*) from job_applications where farmer_id = p_profile_id),
    'work_days', (select count(*) from attendance where farmer_id = p_profile_id),
    'unpaid_wages', (select coalesce(sum(computed_pay), 0) from attendance
                      where farmer_id = p_profile_id and payment_status <> 'paid'),
    'open_orders', (
      select count(*) from orders o
       where o.stage not in ('completed','cancelled')
         and (o.buyer_id = p_profile_id
              or o.product_id in (select p.id from products p
                                    join farms f on f.id = p.farm_id
                                   where f.owner_id = p_profile_id))
    )
  );
$$;

grant execute on function public.admin_user_impact(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- REMOVE AN ACCOUNT
-- Refuses when it would break something a person is relying on: an open order,
-- an unpaid wage, the last administrator, or the administrator's own account.
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_profile(
  p_profile_id uuid,
  p_reason text default '',
  p_force boolean default false
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row    profiles%rowtype;
  v_me     uuid := public.my_profile_id('admin');
  v_open   int;
  v_owed   numeric;
  v_admins int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can remove an account.';
  end if;

  select * into v_row from profiles where id = p_profile_id for update;
  if not found then
    raise exception 'That account no longer exists.';
  end if;

  if p_profile_id = v_me then
    raise exception 'You cannot remove your own administrator account.';
  end if;

  if v_row.role = 'admin' then
    select count(*) into v_admins from profiles where role = 'admin';
    if v_admins <= 1 then
      raise exception 'There must always be at least one administrator.';
    end if;
  end if;

  select count(*) into v_open
    from orders o
   where o.stage not in ('completed','cancelled')
     and (o.buyer_id = p_profile_id
          or o.product_id in (select p.id from products p
                                join farms f on f.id = p.farm_id
                               where f.owner_id = p_profile_id));

  select coalesce(sum(computed_pay), 0) into v_owed
    from attendance
   where farmer_id = p_profile_id and payment_status <> 'paid';

  if not p_force then
    if v_open > 0 then
      raise exception 'This account has % order(s) still in progress. Settle or cancel them first.', v_open;
    end if;
    if v_owed > 0 then
      raise exception 'This worker is still owed PHP %. Settle the wages first.', v_owed;
    end if;
  end if;

  insert into notifications (user_id, message, type, link)
  select p.id,
         'An administrator removed the account of ' || coalesce(v_row.name, 'a user') ||
         coalesce(' (' || nullif(p_reason, '') || ')', '') || '.',
         'general', '/admin/users'
    from profiles p
   where p.role = 'admin' and p.id <> v_me;

  delete from profiles where id = p_profile_id;
end $$;

grant execute on function public.admin_delete_profile(uuid, text, boolean) to authenticated;

-- Administrators need permission to delete rows, not only read them.
drop policy if exists profiles_delete_admin on public.profiles;
create policy profiles_delete_admin on public.profiles for delete to authenticated
  using (public.is_admin());

notify pgrst, 'reload schema';
