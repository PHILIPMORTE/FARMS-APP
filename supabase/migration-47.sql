-- ============================================================================
--  FARMS — MIGRATION 47
--  Security: close the ways a signed-in (or signed-out) user could reach past
--  their own role through the public API.
--
--  FOUND BY TESTING THE API DIRECTLY, AS EACH KIND OF USER
--
--   1. Anyone could make themselves an administrator.
--      profiles could be updated by its owner with no limit on which columns, so
--      a user could set role = 'admin', clear their own "restricted" flag, or reset
--      their rating warnings. Fixed with a guard that only an administrator (or
--      one of the system's own functions) may change those columns, and that no
--      one can create an administrator profile for themselves.
--
--   2. A farmer could hire themselves.
--      A farmer could update their own application to "accepted", or insert one
--      already accepted. Decisions are made only through decide_application(), so
--      the direct update is removed and a new application must start as pending.
--
--   3. A buyer could change what an order cost.
--      Orders are created and moved only by functions (purchase_product,
--      set_order_stage, buyer_cancel_order ...), so the direct table writes are
--      removed.
--
--   4. A farm owner could verify themselves.
--      An owner could insert or update their verification with status = 'approved'.
--      Their own writes are now always saved as "pending"; only an administrator,
--      through review_owner_verification(), can approve.
--
--   5. Anyone, even signed out, could send an email to any user, and read any
--      user's activity summary.
--      queue_message(), send_queued_emails() and notify_growth_stages() are for the
--      system only and are no longer callable from the app. admin_user_impact() now
--      refuses anyone who is not an administrator.
--
--   6. A farm owner could not open an applicant's ID photo.
--      The storage rule compared the applicant's folder with the applicant's NAME
--      instead of the file path, so it never matched. It now compares the path.
--
--   7. Removing a listing silently erased its orders.
--      Orders were set to be deleted together with their product, so tapping Remove on
--      a listing that had been sold wiped those orders, the buyers' history and the
--      sales ranking, and the app still said "Listing removed". A listing that has
--      orders can no longer be removed by its owner; setting its stock to 0 hides it
--      from buyers. (An administrator removing a whole account is not affected.)
--
--  Run migration-46.sql first. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. profiles: role, standing and ownership cannot be changed by the user
-- ---------------------------------------------------------------------------
create or replace function public.guard_profile_columns()
returns trigger
language plpgsql
as $$
begin
  -- Applies to a request that arrives straight from the app. The system's own
  -- functions run as their owner and are not affected, and neither is an
  -- administrator.
  if current_user in ('authenticated', 'anon') and not public.is_admin() then
    if tg_op = 'INSERT' then
      if new.role = 'admin' then
        raise exception 'That kind of account cannot be created here.';
      end if;
      new.restricted := false;
      new.rating_warnings := 0;
    else
      if new.role is distinct from old.role
         or new.user_id is distinct from old.user_id
         or new.restricted is distinct from old.restricted
         or new.rating_warnings is distinct from old.rating_warnings then
        raise exception 'You cannot change that part of your account.';
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_profile_columns on public.profiles;
create trigger trg_guard_profile_columns
  before insert or update on public.profiles
  for each row execute function public.guard_profile_columns();

-- ---------------------------------------------------------------------------
-- 2. job applications: a farmer applies, the owner decides
-- ---------------------------------------------------------------------------
drop policy if exists apps_update on public.job_applications;

drop policy if exists apps_insert on public.job_applications;
create policy apps_insert on public.job_applications for insert to authenticated
  with check (
    farmer_id = public.my_profile_id('farmer')
    and status = 'pending'
    and coalesce(employment_status, 'active') = 'active'
  );

-- ---------------------------------------------------------------------------
-- 3. orders: only the system's functions create or change them
-- ---------------------------------------------------------------------------
drop policy if exists orders_insert on public.orders;
drop policy if exists orders_update_buyer on public.orders;
drop policy if exists orders_update_seller on public.orders;

-- ---------------------------------------------------------------------------
-- 4. owner verification: an owner submits, only an administrator approves
-- ---------------------------------------------------------------------------
create or replace function public.guard_verification_columns()
returns trigger
language plpgsql
as $$
begin
  if current_user in ('authenticated', 'anon') and not public.is_admin() then
    new.status := 'pending';
    new.review_notes := null;
    if tg_op = 'INSERT' then
      new.reviewed_by := null;
      new.reviewed_at := null;
      new.id_checked := false;
      new.selfie_matches := false;
    else
      new.profile_id := old.profile_id;
      new.reviewed_by := old.reviewed_by;
      new.reviewed_at := old.reviewed_at;
      new.id_checked := old.id_checked;
      new.selfie_matches := old.selfie_matches;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_verification_columns on public.owner_verifications;
create trigger trg_guard_verification_columns
  before insert or update on public.owner_verifications
  for each row execute function public.guard_verification_columns();

-- ---------------------------------------------------------------------------
-- 5. functions that are for the system only
-- ---------------------------------------------------------------------------
revoke execute on function public.queue_message(uuid, text, text)   from public, anon, authenticated;
revoke execute on function public.send_queued_emails()              from public, anon, authenticated;
revoke execute on function public.notify_growth_stages(uuid)        from public, anon, authenticated;

create or replace function public.admin_user_impact(p_profile_id uuid)
returns json
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Administrators only.';
  end if;

  return json_build_object(
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
end $$;

revoke execute on function public.admin_user_impact(uuid) from public, anon;
grant  execute on function public.admin_user_impact(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. an owner can open the ID photo of someone who applied to their job
-- ---------------------------------------------------------------------------
drop policy if exists app_read on storage.objects;
create policy app_read on storage.objects for select to authenticated
  using (
    bucket_id = 'applications'
    and (
      (storage.foldername(objects.name))[1] = auth.uid()::text
      or public.is_admin()
      or exists (
        select 1
          from public.job_applications a
          join public.job_posts j on j.id = a.job_id
          join public.profiles p on p.id = a.farmer_id
         where p.user_id::text = (storage.foldername(objects.name))[1]
           and j.owner_id = public.my_profile_id('owner')
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 7. a listing that has orders cannot be removed by its owner
-- ---------------------------------------------------------------------------
create or replace function public.guard_product_delete()
returns trigger
language plpgsql
as $$
begin
  if current_user in ('authenticated', 'anon') and not public.is_admin() then
    if exists (select 1 from orders where product_id = old.id) then
      raise exception
        'This listing has orders, so it cannot be removed. Set its stock to 0 to stop buyers from ordering it.';
    end if;
  end if;
  return old;
end $$;

drop trigger if exists trg_guard_product_delete on public.products;
create trigger trg_guard_product_delete
  before delete on public.products
  for each row execute function public.guard_product_delete();

notify pgrst, 'reload schema';
