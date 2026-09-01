-- ============================================================================
--  FARMS — MIGRATION 2, STEP 2 of 2
--
--  Run STEP 1 (migration-2a.sql) FIRST and let it finish, then run this.
--  Postgres will not let a new enum value be used in the same transaction
--  that created it, which is why these are two files.
--
--  Safe to run more than once.
-- ============================================================================


-- ============================================================================
-- 3. FARM OWNER VERIFICATION
-- A farm owner registers, then waits for an administrator to approve them.
-- Until approved, the guard in the app blocks every /owner/* route.
-- ============================================================================
create table if not exists public.owner_verifications (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null unique references public.profiles(id) on delete cascade,
  status         verification_status not null default 'pending',
  full_name      text not null default '',
  id_type        text not null default '',   -- e.g. National ID, Driver's Licence
  id_number      text not null default '',
  farm_name      text not null default '',
  farm_address   text not null default '',
  barangay       text not null default '',
  farm_size_ha   numeric(10,2),
  document_url   text,                       -- optional uploaded proof
  notes          text,                       -- applicant's own notes
  review_notes   text,                       -- administrator's reason
  reviewed_by    uuid references public.profiles(id) on delete set null,
  reviewed_at    timestamptz,
  submitted_at   timestamptz not null default now()
);
create index if not exists owner_verif_status_idx on public.owner_verifications(status);

-- ============================================================================
-- 1. ATTENDANCE / DAILY WORK LOG
-- One row per hired farmer per day. Absent days record zero hours, and pay is
-- computed from hours actually worked against the farm's standard day.
-- ============================================================================
create table if not exists public.attendance (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references public.farms(id) on delete cascade,
  job_id        uuid references public.job_posts(id) on delete set null,
  farmer_id     uuid not null references public.profiles(id) on delete cascade,
  work_date     date not null default current_date,
  status        attendance_status not null default 'present',
  hours_worked  numeric(5,2) not null default 0 check (hours_worked >= 0 and hours_worked <= 24),
  daily_wage    numeric(12,2) not null default 0 check (daily_wage >= 0),
  -- Pay earned for the day after any deduction for missed hours.
  computed_pay  numeric(12,2) not null default 0 check (computed_pay >= 0),
  note          text,
  recorded_by   uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  unique (farmer_id, work_date, job_id)
);
create index if not exists attendance_farm_date_idx on public.attendance(farm_id, work_date);

-- Standard working day per farm, used to pro-rate pay.
alter table public.farms
  add column if not exists standard_hours numeric(4,2) not null default 8;

-- Pay is deducted in proportion to hours missed:
-- present  → hours worked / standard hours × daily wage
-- half_day → half the daily wage
-- absent   → nothing, and no hours
-- leave    → nothing, but recorded separately from absence
create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare v_standard numeric(5,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    -- Never pay more than a full day, however many hours are entered.
    new.computed_pay := round(
      new.daily_wage * least(new.hours_worked / v_standard, 1), 2
    );
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

-- ============================================================================
-- 7. ORDER STATUS TRACKING + 8. STOCK AUDIT TRAIL
-- ============================================================================
alter table public.orders
  add column if not exists stage order_stage not null default 'placed',
  add column if not exists cancel_reason text,
  add column if not exists updated_at timestamptz not null default now();

-- Every stage change, so the buyer sees a real timeline rather than one label.
create table if not exists public.order_events (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders(id) on delete cascade,
  stage      order_stage not null,
  note       text,
  changed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_idx on public.order_events(order_id, created_at);

-- Who changed which stock, from what to what, and when.
create table if not exists public.stock_changes (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid references public.products(id) on delete set null,
  farm_id     uuid not null references public.farms(id) on delete cascade,
  changed_by  uuid references public.profiles(id) on delete set null,
  old_quantity int not null,
  new_quantity int not null,
  reason      text not null default '',
  source      text not null default 'manual',   -- manual | order | admin
  created_at  timestamptz not null default now()
);
create index if not exists stock_changes_farm_idx on public.stock_changes(farm_id, created_at);

-- ============================================================================
-- HELPERS
-- ============================================================================
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles where user_id = auth.uid() and role = 'admin'
  );
$$;

-- True only when this owner has been approved by an administrator.
create or replace function public.is_verified_owner(p_profile uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from owner_verifications
     where profile_id = p_profile and status = 'approved'
  );
$$;

-- Used by the app's route guard on every /owner/* page.
create or replace function public.my_verification_status()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select status::text from owner_verifications
      where profile_id = public.my_profile_id('owner')),
    'none'
  );
$$;

-- ============================================================================
-- 5 + 8. FARM OWNER STOCK UPDATE
-- Locks the row, writes an audit entry, flips availability, and tells the
-- owner. Doing it in one function means the audit trail can never be skipped.
-- ============================================================================
create or replace function public.update_product_stock(
  p_product_id uuid,
  p_new_quantity int,
  p_reason text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_product products%rowtype;
  v_me      uuid := public.my_profile_id('owner');
  v_qty     int  := floor(p_new_quantity)::int;   -- sacks are whole numbers
begin
  if v_qty < 0 then
    raise exception 'Stock cannot be negative.';
  end if;

  select * into v_product from products where id = p_product_id for update;
  if not found then
    raise exception 'That product no longer exists.';
  end if;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only change stock on your own products.';
  end if;

  if v_qty = v_product.quantity then
    return;   -- nothing changed, nothing to record
  end if;

  update products
     set quantity = v_qty,
         -- Availability follows the number: zero sells out, restocking revives.
         status = case
                    when v_qty = 0 then 'sold'::product_status
                    when v_product.status = 'sold' and v_qty > 0 then 'available'::product_status
                    else v_product.status
                  end
   where id = p_product_id;

  insert into stock_changes (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
  values (p_product_id, v_product.farm_id, coalesce(v_me, public.my_profile_id('admin')),
          v_product.quantity, v_qty, coalesce(nullif(p_reason,''), 'Stock updated'),
          case when public.is_admin() then 'admin' else 'manual' end);

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         v_product.variety || ' stock changed from ' || v_product.quantity ||
         ' to ' || v_qty || ' sacks',
         'stock', '/owner/market'
    from farms f where f.id = v_product.farm_id;
end $$;

-- ============================================================================
-- 4. PURCHASE — now stage-aware and stock-safe
-- Replaces the earlier version: same guarantees, plus an opening timeline entry.
-- ============================================================================
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
  v_remaining  int;
begin
  if v_buyer is null then
    raise exception 'Sign in as a buyer to place an order.';
  end if;
  if v_qty < 1 then
    raise exception 'Order at least 1 sack.';
  end if;

  -- The lock is what stops two buyers taking the last sack at the same time.
  select * into v_product from products where id = p_product_id for update;
  if not found then
    raise exception 'That listing is no longer available.';
  end if;
  if v_product.quantity <= 0 or v_product.status = 'sold' then
    raise exception 'This product is out of stock.';
  end if;
  if v_product.status <> 'available' then
    raise exception 'That listing is not currently for sale.';
  end if;
  if v_qty > v_product.quantity then
    raise exception 'Only % sack(s) left. Lower your quantity to continue.', v_product.quantity;
  end if;

  v_total     := v_qty * v_product.price;
  v_remaining := v_product.quantity - v_qty;

  select * into v_farm from farms where id = v_product.farm_id;
  select name into v_buyer_name from profiles where id = v_buyer;

  insert into orders (buyer_id, product_id, quantity, total_price, status, stage)
  values (v_buyer, p_product_id, v_qty, v_total, 'pending', 'placed')
  returning id into v_order_id;

  insert into order_events (order_id, stage, note, changed_by)
  values (v_order_id, 'placed', 'Order placed by the buyer', v_buyer);

  update products
     set quantity = v_remaining,
         status   = case when v_remaining = 0 then 'sold'::product_status else status end,
         buyer_id = case when v_remaining = 0 then v_buyer else buyer_id end
   where id = p_product_id;

  insert into stock_changes (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
  values (p_product_id, v_product.farm_id, v_buyer, v_product.quantity, v_remaining,
          'Sold ' || v_qty || ' sack(s) to ' || coalesce(v_buyer_name,'a buyer'), 'order');

  insert into transactions (farm_id, type, category, amount, description, date)
  values (v_product.farm_id, 'income', 'Crop Sales', v_total,
          v_qty || ' sacks of ' || v_product.variety || ' sold to ' || coalesce(v_buyer_name,'a buyer'),
          current_date);

  insert into notifications (user_id, message, type, link) values
    (v_farm.owner_id,
     coalesce(v_buyer_name,'A buyer') || ' ordered ' || v_qty || ' sacks of ' || v_product.variety,
     'sale', '/owner/orders'),
    (v_buyer,
     'Order placed: ' || v_qty || ' sacks of ' || v_product.variety || ' from ' || coalesce(v_farm.name,'the farm'),
     'purchase', '/buyer/orders');

  return v_order_id;
end $$;

-- ============================================================================
-- 7. ADVANCE AN ORDER'S STAGE
-- Only the selling farm owner (or an admin) may move an order forward.
-- Cancelling restores the stock, so a cancelled order never loses inventory.
-- ============================================================================
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
  v_me      uuid := coalesce(public.my_profile_id('owner'), public.my_profile_id('admin'));
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  select * into v_product from products where id = v_order.product_id;
  select * into v_farm    from farms    where id = v_product.farm_id;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only update orders for your own farm.';
  end if;

  if v_order.stage = p_stage then
    return;
  end if;
  if v_order.stage in ('completed','cancelled') then
    raise exception 'This order is already %, so it cannot be changed.', v_order.stage;
  end if;

  -- A cancelled order puts its sacks back on the shelf.
  if p_stage = 'cancelled' then
    update products
       set quantity = quantity + v_order.quantity,
           status = case when status = 'sold' then 'available'::product_status else status end
     where id = v_order.product_id;

    insert into stock_changes (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_order.product_id, v_product.farm_id, v_me,
            v_product.quantity, v_product.quantity + v_order.quantity,
            'Order cancelled — stock returned', 'order');

    -- Reverse the income so the books stay honest.
    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_product.farm_id, 'expense', 'Refund', v_order.total_price,
            'Refund for cancelled order of ' || v_product.variety, current_date);
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

-- ============================================================================
-- 3. VERIFICATION REVIEW (administrator only)
-- ============================================================================
create or replace function public.review_owner_verification(
  p_verification_id uuid,
  p_decision verification_status,
  p_notes text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row owner_verifications%rowtype;
  v_me  uuid := public.my_profile_id('admin');
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can review verifications.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected.';
  end if;

  select * into v_row from owner_verifications where id = p_verification_id for update;
  if not found then raise exception 'Verification request not found.'; end if;

  update owner_verifications
     set status = p_decision,
         review_notes = nullif(p_notes,''),
         reviewed_by = v_me,
         reviewed_at = now()
   where id = p_verification_id;

  -- Approving creates the farm, so an approved owner lands on a working dashboard.
  if p_decision = 'approved' then
    if not exists (select 1 from farms where owner_id = v_row.profile_id) then
      insert into farms (owner_id, name, address, city)
      values (v_row.profile_id,
              coalesce(nullif(v_row.farm_name,''), 'My Farm'),
              v_row.farm_address, v_row.barangay);
    end if;
  end if;

  insert into notifications (user_id, message, type, link)
  values (v_row.profile_id,
          case when p_decision = 'approved'
               then 'Your Farm Owner account has been verified. You now have full access.'
               else 'Your Farm Owner verification was not approved.' ||
                    coalesce(' Reason: ' || nullif(p_notes,''), '')
          end,
          'verification', '/owner/dashboard');
end $$;

-- ============================================================================
-- 2. ADMIN OVERVIEW
-- One call for the dashboard counters, so the admin page is a single request.
-- ============================================================================
create or replace function public.admin_stats()
returns json language plpgsql security definer set search_path = public as $$
declare v json;
begin
  if not public.is_admin() then
    raise exception 'Administrators only.';
  end if;

  select json_build_object(
    'owners',          (select count(*) from profiles where role = 'owner'),
    'farmers',         (select count(*) from profiles where role = 'farmer'),
    'buyers',          (select count(*) from profiles where role = 'buyer'),
    'pending_reviews', (select count(*) from owner_verifications where status = 'pending'),
    'products',        (select count(*) from products),
    'out_of_stock',    (select count(*) from products where quantity = 0),
    'orders',          (select count(*) from orders),
    'open_orders',     (select count(*) from orders where stage not in ('completed','cancelled')),
    'revenue',         (select coalesce(sum(total_price),0) from orders where status <> 'cancelled')
  ) into v;
  return v;
end $$;

-- ============================================================================
-- 9. ROW LEVEL SECURITY FOR THE NEW TABLES
-- Permissions live in the database, not only in the interface, so hiding a
-- button is never the only thing protecting data.
-- ============================================================================
alter table public.owner_verifications enable row level security;
alter table public.attendance          enable row level security;
alter table public.order_events        enable row level security;
alter table public.stock_changes       enable row level security;

-- owner_verifications: applicants see their own, administrators see all.
drop policy if exists ov_select on public.owner_verifications;
create policy ov_select on public.owner_verifications for select to authenticated
  using (public.is_mine(profile_id) or public.is_admin());

drop policy if exists ov_insert on public.owner_verifications;
create policy ov_insert on public.owner_verifications for insert to authenticated
  with check (public.is_mine(profile_id));

drop policy if exists ov_update on public.owner_verifications;
create policy ov_update on public.owner_verifications for update to authenticated
  using (
    -- Applicants may correct a rejected submission; admins decide via the RPC.
    (public.is_mine(profile_id) and status <> 'approved') or public.is_admin()
  );

-- attendance: the farm that recorded it, the farmer it concerns, or an admin.
drop policy if exists att_select on public.attendance;
create policy att_select on public.attendance for select to authenticated
  using (public.owns_farm(farm_id) or public.is_mine(farmer_id) or public.is_admin());

drop policy if exists att_write on public.attendance;
create policy att_write on public.attendance for all to authenticated
  using (public.owns_farm(farm_id) or public.is_admin())
  with check (public.owns_farm(farm_id) or public.is_admin());

-- order_events: the buyer on the order, the selling farm, or an admin.
drop policy if exists oe_select on public.order_events;
create policy oe_select on public.order_events for select to authenticated
  using (
    exists (
      select 1 from orders o
       where o.id = order_id
         and (
           public.is_mine(o.buyer_id)
           or exists (select 1 from products p where p.id = o.product_id and public.owns_farm(p.farm_id))
         )
    )
    or public.is_admin()
  );

-- stock_changes: read-only audit for the farm owner and administrators.
-- Rows are written by SECURITY DEFINER functions, never directly by a client.
drop policy if exists sc_select on public.stock_changes;
create policy sc_select on public.stock_changes for select to authenticated
  using (public.owns_farm(farm_id) or public.is_admin());

-- ---- administrators can see and manage everything --------------------------
drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists products_admin_all on public.products;
create policy products_admin_all on public.products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists orders_admin_all on public.orders;
create policy orders_admin_all on public.orders for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists farms_admin_all on public.farms;
create policy farms_admin_all on public.farms for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists inventory_admin_all on public.inventory;
create policy inventory_admin_all on public.inventory for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- The selling farm owner must be able to read orders placed with them.
drop policy if exists orders_update_seller on public.orders;
create policy orders_update_seller on public.orders for update to authenticated
  using (
    exists (select 1 from products p where p.id = product_id and public.owns_farm(p.farm_id))
    or public.is_admin()
  );

-- ============================================================================
-- REALTIME — stock and order stages must sync between interfaces
-- ============================================================================
do $$ begin alter publication supabase_realtime add table public.orders;       exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.order_events; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.attendance;   exception when duplicate_object then null; end $$;

alter table public.orders       replica identity full;
alter table public.order_events replica identity full;
alter table public.attendance   replica identity full;

-- ============================================================================
-- MAKING THE FIRST ADMINISTRATOR
-- Register normally through any role's page, then find your user id in
-- Authentication → Users and run:
--
--   insert into public.profiles (user_id, role, name, phone)
--   values ('PASTE-USER-ID', 'admin', 'System Administrator', '+639000000000');
--
-- Sign out and back in, then open /admin/login.
-- ============================================================================

notify pgrst, 'reload schema';
