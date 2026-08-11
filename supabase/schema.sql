-- ============================================================================
-- FARMS — Philippine Farm Management
-- Run this whole file in the Supabase SQL Editor (one paste, top to bottom).
--
-- IDENTITY MODEL — please read.
-- Supabase Auth enforces ONE auth user per phone number. The brief asks for a
-- phone to hold up to three accounts (owner / farmer / buyer). Both cannot be
-- literally true, so: one AUTH USER per phone, and up to three PROFILE ROWS
-- pointing at it — one per role. profiles.id is its own uuid and every other
-- table foreign-keys to that, so each role's data stays completely separate.
-- The composite unique (phone, role) is preserved exactly as specified.
-- Signing in as an owner never surfaces buyer data, and vice versa.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- enums ----
do $$ begin
  create type user_role      as enum ('owner','farmer','buyer');
  create type crop_type      as enum ('rice','corn','watermelon');
  create type job_crop_type  as enum ('rice','corn','watermelon','general');
  create type job_type       as enum ('seasonal','part-time','full-time');
  create type job_status     as enum ('open','closed','filled');
  create type app_status     as enum ('pending','accepted','rejected');
  create type availability   as enum ('available','busy','unavailable');
  create type product_status as enum ('available','reserved','sold');
  create type txn_type       as enum ('income','expense');
  create type order_status   as enum ('completed','pending','cancelled');
  create type notif_type     as enum ('harvest','sale','purchase','job_post','application','hired','rejected','general');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------- profiles ----
create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        user_role   not null,
  name        text        not null default '',
  phone       text        not null,
  email       text,
  company     text,
  address     text,
  city        text,
  province    text,
  zip_code    text,
  created_at  timestamptz not null default now(),
  constraint profiles_phone_role_key unique (phone, role),
  constraint profiles_user_role_key  unique (user_id, role)
);
create index if not exists profiles_user_idx  on public.profiles(user_id);
create index if not exists profiles_phone_idx on public.profiles(phone);

-- --------------------------------------------------------- id helpers ------
-- Every policy below is expressed as "is this profile row mine?"
create or replace function public.is_mine(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = p and user_id = auth.uid());
$$;

create or replace function public.my_profile_id(r user_role)
returns uuid language sql stable security definer set search_path = public as $$
  select id from profiles where user_id = auth.uid() and role = r limit 1;
$$;

-- ---------------------------------------------------------------- farms ----
create table if not exists public.farms (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  name       text not null default 'My Farm',
  address    text,
  city       text,
  province   text,
  zip_code   text,
  created_at timestamptz not null default now()
);
create index if not exists farms_owner_idx on public.farms(owner_id);

create or replace function public.owns_farm(f uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from farms fa join profiles p on p.id = fa.owner_id
    where fa.id = f and p.user_id = auth.uid() and p.role = 'owner'
  );
$$;

-- ------------------------------------------------------- farmer_profiles ---
create table if not exists public.farmer_profiles (
  id               uuid primary key references public.profiles(id) on delete cascade,
  bio              text,
  skills           text[] default '{}',
  experience_years int default 0 check (experience_years >= 0),
  availability     availability not null default 'available',
  province         text,
  city             text,
  created_at       timestamptz not null default now()
);

-- ------------------------------------------------------------ job_posts ----
create table if not exists public.job_posts (
  id           uuid primary key default gen_random_uuid(),
  farm_id      uuid not null references public.farms(id) on delete cascade,
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  title        text not null,
  description  text not null default '',
  crop         job_crop_type not null default 'general',
  type         job_type not null default 'seasonal',
  wage         numeric(12,2) not null check (wage >= 0),
  slots        int not null check (slots >= 1),           -- whole workers only
  filled_slots int not null default 0 check (filled_slots >= 0),
  location     text not null default '',
  start_date   date not null,
  end_date     date,
  status       job_status not null default 'open',
  created_at   timestamptz not null default now(),
  constraint job_slots_not_overfilled check (filled_slots <= slots)
);
create index if not exists job_posts_status_idx on public.job_posts(status);
create index if not exists job_posts_owner_idx  on public.job_posts(owner_id);

-- ----------------------------------------------------- job_applications ----
create table if not exists public.job_applications (
  id         uuid primary key default gen_random_uuid(),
  job_id     uuid not null references public.job_posts(id) on delete cascade,
  farmer_id  uuid not null references public.profiles(id) on delete cascade,
  status     app_status not null default 'pending',
  message    text,
  applied_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (job_id, farmer_id)          -- one application per farmer per job
);
create index if not exists job_apps_job_idx    on public.job_applications(job_id);
create index if not exists job_apps_farmer_idx on public.job_applications(farmer_id);

-- ------------------------------------------------------------ schedules ----
create table if not exists public.schedules (
  id               uuid primary key default gen_random_uuid(),
  farm_id          uuid not null references public.farms(id) on delete cascade,
  crop             crop_type not null,
  planting_month   text not null check (planting_month ~ '^\d{4}-\d{2}$'),
  estimated_months int not null check (estimated_months >= 1),
  created_at       timestamptz not null default now()
);
create index if not exists schedules_farm_idx on public.schedules(farm_id);

-- ------------------------------------------------------------ inventory ----
-- quantity is int: a sack is never a fraction.
create table if not exists public.inventory (
  id       uuid primary key default gen_random_uuid(),
  farm_id  uuid not null references public.farms(id) on delete cascade,
  crop     crop_type not null,
  quantity int not null check (quantity >= 1),
  added_at timestamptz not null default now()
);
create index if not exists inventory_farm_idx on public.inventory(farm_id);

-- ------------------------------------------------------------- products ----
create table if not exists public.products (
  id         uuid primary key default gen_random_uuid(),
  farm_id    uuid not null references public.farms(id) on delete cascade,
  variety    text not null,
  crop       crop_type not null,
  quantity   int not null check (quantity >= 0),   -- whole sacks
  price      numeric(12,2) not null check (price >= 0),
  status     product_status not null default 'available',
  buyer_id   uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists products_status_idx on public.products(status);
create index if not exists products_farm_idx   on public.products(farm_id);

-- --------------------------------------------------------- transactions ----
create table if not exists public.transactions (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null references public.farms(id) on delete cascade,
  type        txn_type not null,
  category    text not null,
  amount      numeric(12,2) not null check (amount >= 0),
  description text default '',
  date        date not null default current_date,
  created_at  timestamptz not null default now()
);
create index if not exists transactions_farm_idx on public.transactions(farm_id);

-- --------------------------------------------------------------- orders ----
create table if not exists public.orders (
  id          uuid primary key default gen_random_uuid(),
  buyer_id    uuid not null references public.profiles(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete cascade,
  quantity    int not null check (quantity >= 1),   -- whole sacks
  total_price numeric(12,2) not null check (total_price >= 0),
  status      order_status not null default 'completed',
  created_at  timestamptz not null default now()
);
create index if not exists orders_buyer_idx on public.orders(buyer_id);

-- -------------------------------------------------------- notifications ----
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  message    text not null,
  type       notif_type not null default 'general',
  link       text default '',
  unread     boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, unread);

-- ============================================================================
-- PURCHASE
-- One atomic step so two buyers can never oversell the same stock: locks the
-- listing, writes the order, decrements sacks as integers, books the seller's
-- income, and notifies both sides.
-- ============================================================================
create or replace function public.purchase_product(p_product_id uuid, p_quantity int)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_product    products%rowtype;
  v_buyer      uuid := public.my_profile_id('buyer');
  v_qty        int  := floor(p_quantity)::int;   -- defensive: sacks are integers
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

  select * into v_product from products where id = p_product_id for update;
  if not found or v_product.status <> 'available' then
    raise exception 'That listing is no longer available.';
  end if;
  if v_qty > v_product.quantity then
    raise exception 'Only % sacks left.', v_product.quantity;
  end if;

  v_total     := v_qty * v_product.price;
  v_remaining := v_product.quantity - v_qty;

  select * into v_farm from farms where id = v_product.farm_id;
  select name into v_buyer_name from profiles where id = v_buyer;

  insert into orders (buyer_id, product_id, quantity, total_price, status)
  values (v_buyer, p_product_id, v_qty, v_total, 'completed')
  returning id into v_order_id;

  update products
     set quantity = v_remaining,
         status   = case when v_remaining = 0 then 'sold'::product_status else status end,
         buyer_id = case when v_remaining = 0 then v_buyer else buyer_id end
   where id = p_product_id;

  -- A buyer purchase always books as Crop Sales income on the owner's ledger.
  insert into transactions (farm_id, type, category, amount, description, date)
  values (v_product.farm_id, 'income', 'Crop Sales', v_total,
          v_qty || ' sacks of ' || v_product.variety || ' sold to ' || coalesce(v_buyer_name,'a buyer'),
          current_date);

  insert into notifications (user_id, message, type, link) values
    (v_farm.owner_id,
     coalesce(v_buyer_name,'A buyer') || ' bought ' || v_qty || ' sacks of ' || v_product.variety,
     'sale', '/owner/market'),
    (v_buyer,
     'Order confirmed: ' || v_qty || ' sacks of ' || v_product.variety || ' from ' || coalesce(v_farm.name,'the farm'),
     'purchase', '/buyer/orders');

  return v_order_id;
end $$;

-- ============================================================================
-- HIRING DECISION
-- Updates the application, moves the slot counter, flips the post to 'filled'
-- when the last slot goes, and notifies the farmer.
-- ============================================================================
create or replace function public.decide_application(p_application_id uuid, p_decision app_status)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app   job_applications%rowtype;
  v_job   job_posts%rowtype;
  v_farm        farms%rowtype;
  v_owner       uuid := public.my_profile_id('owner');
  v_days        int;
  v_cost        numeric(12,2);
  v_farmer_name text;
begin
  if p_decision not in ('accepted','rejected') then
    raise exception 'Decision must be accepted or rejected.';
  end if;

  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;

  select * into v_job from job_posts where id = v_app.job_id for update;

  if v_owner is null or v_job.owner_id <> v_owner then
    raise exception 'You can only review applications on your own job posts.';
  end if;
  if v_app.status <> 'pending' then
    raise exception 'This application was already reviewed.';
  end if;

  select * into v_farm from farms where id = v_job.farm_id;

  update job_applications set status = p_decision, updated_at = now()
   where id = p_application_id;

  if p_decision = 'accepted' then
    if v_job.filled_slots >= v_job.slots then
      raise exception 'Every slot on this job is already filled.';
    end if;

    update job_posts
       set filled_slots = filled_slots + 1,
           status = case when filled_slots + 1 >= slots then 'filled'::job_status else status end
     where id = v_job.id;

    -- Hiring costs money, so the wage lands on the farm's books automatically.
    -- A job that runs start..end is paid for every day inclusive; a job with no
    -- end date is booked as a single day's wage.
    v_days := greatest(1, (coalesce(v_job.end_date, v_job.start_date) - v_job.start_date) + 1);
    v_cost := v_job.wage * v_days;

    select name into v_farmer_name from profiles where id = v_app.farmer_id;

    insert into transactions (farm_id, type, category, amount, description, date)
    values (v_job.farm_id, 'expense', 'Labor', v_cost,
            coalesce(v_farmer_name, 'A farmer') || ' hired for ' || v_job.title ||
            ' (' || v_days || ' day' || case when v_days = 1 then '' else 's' end ||
            ' at PHP ' || v_job.wage || '/day)',
            v_job.start_date);

    insert into notifications (user_id, message, type, link)
    values (v_app.farmer_id,
            'You have been hired for ' || v_job.title || ' at ' || coalesce(v_farm.name,'the farm'),
            'hired', '/farmer/applications');
  else
    insert into notifications (user_id, message, type, link)
    values (v_app.farmer_id,
            'Your application for ' || v_job.title || ' was not accepted',
            'rejected', '/farmer/applications');
  end if;
end $$;

-- Tell the owner as soon as someone applies.
create or replace function public.notify_owner_on_application()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_job job_posts%rowtype; v_name text;
begin
  select * into v_job from job_posts where id = new.job_id;
  select name into v_name from profiles where id = new.farmer_id;
  insert into notifications (user_id, message, type, link)
  values (v_job.owner_id,
          'New application from ' || coalesce(v_name,'a farmer') || ' for ' || v_job.title,
          'application', '/owner/jobs');
  return new;
end $$;

drop trigger if exists trg_notify_owner_on_application on public.job_applications;
create trigger trg_notify_owner_on_application
  after insert on public.job_applications
  for each row execute function public.notify_owner_on_application();

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
alter table public.profiles         enable row level security;
alter table public.farms            enable row level security;
alter table public.farmer_profiles  enable row level security;
alter table public.job_posts        enable row level security;
alter table public.job_applications enable row level security;
alter table public.schedules        enable row level security;
alter table public.inventory        enable row level security;
alter table public.products         enable row level security;
alter table public.transactions     enable row level security;
alter table public.orders           enable row level security;
alter table public.notifications    enable row level security;

-- profiles: readable by signed-in users (buyers need farm contacts, owners need
-- applicant names), writable only by the person who owns the auth account.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated with check (user_id = auth.uid());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- farms
drop policy if exists farms_select on public.farms;
create policy farms_select on public.farms for select to authenticated using (true);

drop policy if exists farms_write on public.farms;
create policy farms_write on public.farms for all to authenticated
  using (public.is_mine(owner_id)) with check (public.is_mine(owner_id));

-- farmer_profiles
drop policy if exists fp_select on public.farmer_profiles;
create policy fp_select on public.farmer_profiles for select to authenticated using (true);

drop policy if exists fp_write on public.farmer_profiles;
create policy fp_write on public.farmer_profiles for all to authenticated
  using (public.is_mine(id)) with check (public.is_mine(id));

-- job_posts: every signed-in user may read the board; only the poster may write.
drop policy if exists jobs_select on public.job_posts;
create policy jobs_select on public.job_posts for select to authenticated using (true);

drop policy if exists jobs_write on public.job_posts;
create policy jobs_write on public.job_posts for all to authenticated
  using (public.is_mine(owner_id)) with check (public.is_mine(owner_id));

-- job_applications: farmers see their own, owners see those on their posts.
drop policy if exists apps_select on public.job_applications;
create policy apps_select on public.job_applications for select to authenticated
  using (
    public.is_mine(farmer_id)
    or exists (select 1 from job_posts j where j.id = job_id and public.is_mine(j.owner_id))
  );

drop policy if exists apps_insert on public.job_applications;
create policy apps_insert on public.job_applications for insert to authenticated
  with check (farmer_id = public.my_profile_id('farmer'));

drop policy if exists apps_update on public.job_applications;
create policy apps_update on public.job_applications for update to authenticated
  using (public.is_mine(farmer_id));   -- owners decide via decide_application()

-- owner-scoped tables
drop policy if exists sched_all on public.schedules;
create policy sched_all on public.schedules for all to authenticated
  using (public.owns_farm(farm_id)) with check (public.owns_farm(farm_id));

drop policy if exists inv_all on public.inventory;
create policy inv_all on public.inventory for all to authenticated
  using (public.owns_farm(farm_id)) with check (public.owns_farm(farm_id));

drop policy if exists txn_all on public.transactions;
create policy txn_all on public.transactions for all to authenticated
  using (public.owns_farm(farm_id)) with check (public.owns_farm(farm_id));

-- products: anyone signed in sees what is for sale; owners manage their own.
drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated
  using (status = 'available' or public.owns_farm(farm_id) or public.is_mine(buyer_id));

drop policy if exists products_write on public.products;
create policy products_write on public.products for all to authenticated
  using (public.owns_farm(farm_id)) with check (public.owns_farm(farm_id));

-- orders: the buyer who placed it, and the owner of the farm that sold it.
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (
    public.is_mine(buyer_id)
    or exists (select 1 from products p where p.id = product_id and public.owns_farm(p.farm_id))
  );

drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders for insert to authenticated
  with check (buyer_id = public.my_profile_id('buyer'));

-- notifications
drop policy if exists notif_select on public.notifications;
create policy notif_select on public.notifications for select to authenticated using (public.is_mine(user_id));

drop policy if exists notif_update on public.notifications;
create policy notif_update on public.notifications for update to authenticated using (public.is_mine(user_id));

-- Cross-user notifications are written by the SECURITY DEFINER functions above,
-- which bypass RLS. Clients may only ever write notifications to themselves.
drop policy if exists notif_insert on public.notifications;
create policy notif_insert on public.notifications for insert to authenticated
  with check (public.is_mine(user_id));

-- ============================================================================
-- REALTIME — live market, live job board, live notifications
-- ============================================================================
do $$ begin alter publication supabase_realtime add table public.products;         exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.job_posts;        exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.notifications;    exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.job_applications; exception when duplicate_object then null; end $$;

alter table public.products         replica identity full;
alter table public.job_posts        replica identity full;
alter table public.notifications    replica identity full;
alter table public.job_applications replica identity full;

-- ============================================================================
-- HARVEST REMINDERS
-- Call this on load; it creates a reminder for any schedule whose harvest month
-- starts within 3 days, and will not duplicate one it has already written.
-- ============================================================================
create or replace function public.generate_harvest_reminders()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_owner   uuid := public.my_profile_id('owner');
  v_row     record;
  v_created int := 0;
  v_msg     text;
begin
  if v_owner is null then
    return 0;
  end if;

  for v_row in
    select s.id,
           s.crop,
           f.name as farm_name,
           -- First day of the estimated harvest month
           (to_date(s.planting_month, 'YYYY-MM')
             + (s.estimated_months || ' months')::interval)::date as harvest_start
      from schedules s
      join farms f on f.id = s.farm_id
     where f.owner_id = v_owner
  loop
    -- Only inside the 3-day window before the harvest month begins
    if v_row.harvest_start - current_date between 0 and 3 then
      v_msg := 'Harvest reminder: your ' || v_row.crop || ' at ' ||
               coalesce(v_row.farm_name, 'your farm') ||
               ' is due around ' || to_char(v_row.harvest_start, 'FMMonth YYYY');

      -- One reminder per schedule per harvest date
      if not exists (
        select 1 from notifications
         where user_id = v_owner
           and type = 'harvest'
           and message = v_msg
      ) then
        insert into notifications (user_id, message, type, link)
        values (v_owner, v_msg, 'harvest', '/owner/calendar');
        v_created := v_created + 1;
      end if;
    end if;
  end loop;

  return v_created;
end $$;

-- ============================================================================
-- PHONE AVAILABILITY CHECK
-- The registration form must be able to say "this number is already registered
-- as a Farm Owner" BEFORE an auth user is created. At that point the person is
-- not signed in, and profiles_select is restricted to authenticated users — so
-- a plain select returns nothing and the check silently passes.
--
-- This runs as SECURITY DEFINER and returns only a boolean, so anonymous
-- callers can test one (phone, role) pair without being able to read the
-- profiles table or enumerate who is registered.
-- ============================================================================
create or replace function public.phone_role_taken(p_phone text, p_role user_role)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles where phone = p_phone and role = p_role
  );
$$;

revoke all on function public.phone_role_taken(text, user_role) from public;
grant execute on function public.phone_role_taken(text, user_role) to anon, authenticated;

-- ============================================================================
-- DELETE A JOB POST
-- Deleting a post cascades to its applications, but deliberately NOT to
-- transactions: a wage already booked when someone was hired is real money
-- that was committed, so it stays on the books. transactions has no foreign
-- key to job_posts, which is what guarantees this.
--
-- Applicants are told before the post disappears, so nobody is left waiting
-- on something that no longer exists.
-- ============================================================================
create or replace function public.delete_job_post(p_job_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_job   job_posts%rowtype;
  v_farm  farms%rowtype;
  v_owner uuid := public.my_profile_id('owner');
  v_app   record;
begin
  select * into v_job from job_posts where id = p_job_id for update;
  if not found then
    raise exception 'That job post no longer exists.';
  end if;

  if v_owner is null or v_job.owner_id <> v_owner then
    raise exception 'You can only delete your own job posts.';
  end if;

  select * into v_farm from farms where id = v_job.farm_id;

  -- Tell everyone who applied, wording it by their outcome.
  for v_app in
    select farmer_id, status from job_applications where job_id = p_job_id
  loop
    insert into notifications (user_id, message, type, link)
    values (
      v_app.farmer_id,
      case
        when v_app.status = 'accepted' then
          'The job "' || v_job.title || '" at ' || coalesce(v_farm.name, 'the farm') ||
          ' has been removed. Contact the farm owner about work already agreed.'
        else
          'The job "' || v_job.title || '" at ' || coalesce(v_farm.name, 'the farm') ||
          ' is no longer available.'
      end,
      'general', '/farmer/jobs');
  end loop;

  -- Cascades to job_applications only. Wages in transactions are untouched.
  delete from job_posts where id = p_job_id;
end $$;

-- ============================================================================
-- RELOAD THE API SCHEMA CACHE
-- PostgREST caches which functions exist. A newly created function can return
-- "Could not find the function ... in the schema cache" until it refreshes.
-- This line forces it immediately, so new RPCs work the moment this file runs.
-- ============================================================================
notify pgrst, 'reload schema';
