# ============================================================================
#  FARMS - writes every source file into the current folder.
#
#  HOW TO RUN
#    powershell -ExecutionPolicy Bypass -File .\setup-farms.ps1
#    then:  npm install    and    npm run dev
# ============================================================================

$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host 'FARMS - writing project files...' -ForegroundColor Green
Write-Host ''

function Write-ProjectFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $PWD $Path), $Content, $enc)
    Write-Host ("  created  " + $Path) -ForegroundColor DarkGray
}

foreach ($stale in @('src\App.css', 'public\vite.svg', 'src\assets',
                     'tsconfig.app.json', 'tsconfig.node.json',
                     'src\hooks\useNotifications.ts', 'src\components\ProfileDialogs.tsx',
                     'src\pages\owner\Payroll.tsx')) {
    if (Test-Path $stale) {
        Remove-Item -Recurse -Force $stale
        Write-Host ("  removed  " + $stale) -ForegroundColor DarkYellow
    }
}
Write-Host ''
$script:count = 0

Write-ProjectFile 'supabase\schema.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\update-patch.sql' @'
-- ============================================================================
--  FARMS — UPDATE PATCH
--  Run this in the Supabase SQL Editor.
--  Adds the functions the app now calls, and updates hiring so wages are
--  recorded automatically. Safe to run more than once.
-- ============================================================================

-- Hiring now books the wage as a Labor expense on the farm's ledger.
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

-- Refresh PostgREST so the new functions are visible to the app immediately.
notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-2a.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 2, STEP 1 of 2  (enums only)
--  Adds: administrator role, farm owner verification, attendance log,
--  order status tracking, stock editing with an audit trail.
--
--  Run this FIRST, on its own, then run migration-2b.sql.
--  Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------- enums ----
-- Postgres cannot add enum values inside a transaction block that also uses
-- them, so these run first and separately.
alter type user_role   add value if not exists 'admin';
alter type notif_type  add value if not exists 'verification';
alter type notif_type  add value if not exists 'order_status';
alter type notif_type  add value if not exists 'stock';

do $$ begin
  create type verification_status as enum ('pending','approved','rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type attendance_status as enum ('present','absent','half_day','leave');
exception when duplicate_object then null; end $$;

-- Shopee-style order lifecycle.
do $$ begin
  create type order_stage as enum (
    'placed','confirmed','preparing','ready','shipped','delivered','completed','cancelled'
  );
exception when duplicate_object then null; end $$;

-- Step 1 finished. Now run migration-2b.sql.

'@
$script:count++

Write-ProjectFile 'supabase\migration-2b.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\migration-3.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\migration-4.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 4
--  Aligns the order stage with the older status column.
--
--  Orders created before the stage column existed kept status = 'completed'
--  or 'cancelled' but received the default stage of 'placed'. That made the
--  same order appear as both incoming and finished. This backfills them.
--
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

update public.orders
   set stage = 'completed'
 where status = 'completed'
   and stage in ('placed', 'confirmed');

update public.orders
   set stage = 'cancelled'
 where status = 'cancelled'
   and stage <> 'cancelled';

-- Give every order at least one timeline entry so the buyer's tracker is
-- never empty for older purchases.
insert into public.order_events (order_id, stage, note, created_at)
select o.id, o.stage, 'Recorded from earlier order history', o.created_at
  from public.orders o
 where not exists (
   select 1 from public.order_events e where e.order_id = o.id
 );

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-5.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 5
--  ID photo storage, product merging, HR fields and payroll.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-ids', 'verification-ids', false, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists vid_insert on storage.objects;
create policy vid_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-ids'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists vid_update on storage.objects;
create policy vid_update on storage.objects for update to authenticated
  using (bucket_id = 'verification-ids'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists vid_select on storage.objects;
create policy vid_select on storage.objects for select to authenticated
  using (bucket_id = 'verification-ids'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

drop policy if exists vid_delete on storage.objects;
create policy vid_delete on storage.objects for delete to authenticated
  using (bucket_id = 'verification-ids'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.owner_verifications
  alter column id_number drop not null;

alter table public.owner_verifications
  add column if not exists id_photo_path text;

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
           status   = 'available'
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

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

alter table public.job_applications
  add column if not exists employment_status text not null default 'active',
  add column if not exists ended_at timestamptz,
  add column if not exists end_reason text;

create or replace function public.payroll_summary(p_month text)
returns table (
  farmer_id    uuid,
  worker_name  text,
  phone        text,
  days_present int,
  days_absent  int,
  days_half    int,
  days_leave   int,
  total_hours  numeric,
  total_pay    numeric
)
language sql stable security definer set search_path = public
as $$
  select
    a.farmer_id,
    p.name,
    p.phone,
    count(*) filter (where a.status = 'present')::int,
    count(*) filter (where a.status = 'absent')::int,
    count(*) filter (where a.status = 'half_day')::int,
    count(*) filter (where a.status = 'leave')::int,
    coalesce(sum(a.hours_worked), 0),
    coalesce(sum(a.computed_pay), 0)
  from attendance a
  join profiles p on p.id = a.farmer_id
  join farms f on f.id = a.farm_id
  where f.owner_id = public.my_profile_id('owner')
    and to_char(a.work_date, 'YYYY-MM') = p_month
  group by a.farmer_id, p.name, p.phone
  order by coalesce(sum(a.computed_pay), 0) desc;
$$;

revoke all on function public.payroll_summary(text) from public;
grant execute on function public.payroll_summary(text) to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-6.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 6
--  Wage payment tracking on the daily work log.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.attendance
  add column if not exists paid boolean not null default false,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by uuid references public.profiles(id) on delete set null;

create index if not exists attendance_paid_idx on public.attendance(farm_id, paid);

-- ---------------------------------------------------------------------------
-- Mark a day's wage as paid, or undo it. Recording the payment on the ledger
-- keeps Finance honest: the wage was already booked as a Labor expense when
-- the worker was hired, so marking it paid only stamps who settled it and when.
-- ---------------------------------------------------------------------------
create or replace function public.set_attendance_paid(
  p_attendance_id uuid,
  p_paid boolean
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row attendance%rowtype;
  v_me  uuid := public.my_profile_id('owner');
begin
  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That work day no longer exists.';
  end if;

  if not public.owns_farm(v_row.farm_id) and not public.is_admin() then
    raise exception 'You can only settle wages for your own farm.';
  end if;

  if p_paid and v_row.computed_pay <= 0 then
    raise exception 'There is no wage to pay for this day.';
  end if;

  update attendance
     set paid    = p_paid,
         paid_at = case when p_paid then now() else null end,
         paid_by = case when p_paid then v_me else null end
   where id = p_attendance_id;

  if p_paid then
    insert into notifications (user_id, message, type, link)
    values (v_row.farmer_id,
            'Your wage of PHP ' || v_row.computed_pay || ' for ' ||
            to_char(v_row.work_date, 'FMMon DD, YYYY') || ' has been paid.',
            'general', '/farmer/applications');
  end if;
end $$;

-- Settle every unpaid day for one worker in a month, in a single step.
create or replace function public.pay_worker_month(
  p_farmer_id uuid,
  p_month text
)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_farm  uuid;
  v_me    uuid := public.my_profile_id('owner');
  v_count int;
  v_total numeric;
begin
  select id into v_farm from farms where owner_id = v_me limit 1;
  if v_farm is null then
    raise exception 'No farm found for this account.';
  end if;

  select count(*), coalesce(sum(computed_pay), 0)
    into v_count, v_total
    from attendance
   where farm_id = v_farm
     and farmer_id = p_farmer_id
     and to_char(work_date, 'YYYY-MM') = p_month
     and paid = false
     and computed_pay > 0;

  if v_count = 0 then
    return 0;
  end if;

  update attendance
     set paid = true, paid_at = now(), paid_by = v_me
   where farm_id = v_farm
     and farmer_id = p_farmer_id
     and to_char(work_date, 'YYYY-MM') = p_month
     and paid = false
     and computed_pay > 0;

  insert into notifications (user_id, message, type, link)
  values (p_farmer_id,
          'You have been paid PHP ' || v_total || ' for ' || v_count ||
          ' work day(s).',
          'general', '/farmer/applications');

  return v_count;
end $$;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-7.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 7
--  Product photos, verification for every role, order payment gate,
--  single administrator, and farmer self-service time in / time out.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. PRODUCT PHOTOS
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists pp_read on storage.objects;
create policy pp_read on storage.objects for select
  using (bucket_id = 'product-photos');

drop policy if exists pp_write on storage.objects;
create policy pp_write on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists pp_update on storage.objects;
create policy pp_update on storage.objects for update to authenticated
  using (bucket_id = 'product-photos'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists pp_delete on storage.objects;
create policy pp_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.products
  add column if not exists photo_url text;

-- ---------------------------------------------------------------------------
-- 2. VERIFICATION FOR EVERY ROLE
-- The table was owner-only. Farmers and buyers now go through the same review.
-- ---------------------------------------------------------------------------
alter table public.owner_verifications
  add column if not exists role user_role not null default 'owner';

update public.owner_verifications v
   set role = p.role
  from public.profiles p
 where p.id = v.profile_id
   and v.role is distinct from p.role;

alter table public.owner_verifications
  alter column farm_name drop not null,
  alter column farm_address drop not null;

create or replace function public.my_verification_status()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select v.status::text
       from owner_verifications v
       join profiles p on p.id = v.profile_id
      where p.user_id = auth.uid()
      order by v.submitted_at desc
      limit 1),
    'none'
  );
$$;

create or replace function public.verification_status_for(p_profile uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select status::text from owner_verifications where profile_id = p_profile),
    'none'
  );
$$;

grant execute on function public.verification_status_for(uuid) to authenticated;

-- Approving now works for any role: a farm is only created for owners.
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
               then 'Your account has been verified. You now have full access.'
               else 'Your verification was not approved.' ||
                    coalesce(' Reason: ' || nullif(p_notes,''), '')
          end,
          'verification', '/');
end $$;

-- ---------------------------------------------------------------------------
-- 3. ONE ADMINISTRATOR ONLY
-- ---------------------------------------------------------------------------
-- If this fails with "Key (role)=(admin) is duplicated", you already have more
-- than one administrator. Run supabase/fix-admins.sql to see them, then
-- fix-admins-step2.sql to keep one, and re-run this file.
create unique index if not exists profiles_single_admin
  on public.profiles ((role))
  where role = 'admin';

-- ---------------------------------------------------------------------------
-- 4. AN ORDER MUST BE PAID BEFORE IT CAN BE COMPLETED
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists paid boolean not null default false,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_by uuid references public.profiles(id) on delete set null;

create or replace function public.set_order_paid(p_order_id uuid, p_paid boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_order   orders%rowtype;
  v_product products%rowtype;
  v_me      uuid := coalesce(public.my_profile_id('owner'), public.my_profile_id('admin'));
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  select * into v_product from products where id = v_order.product_id;

  if not public.owns_farm(v_product.farm_id) and not public.is_admin() then
    raise exception 'You can only settle orders for your own farm.';
  end if;
  if v_order.stage = 'cancelled' then
    raise exception 'A cancelled order cannot be marked paid.';
  end if;

  update orders
     set paid = p_paid,
         paid_at = case when p_paid then now() else null end,
         paid_by = case when p_paid then v_me else null end,
         updated_at = now()
   where id = p_order_id;

  if p_paid then
    insert into notifications (user_id, message, type, link)
    values (v_order.buyer_id,
            'Payment received for your order of ' || v_product.variety || '.',
            'order_status', '/buyer/orders');
  end if;
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

  if p_stage = 'completed' and v_order.paid = false then
    raise exception 'Mark this order as paid before completing it.';
  end if;

  if p_stage = 'cancelled' then
    update products
       set quantity = quantity + v_order.quantity,
           status = case when status = 'sold' then 'available'::product_status else status end
     where id = v_order.product_id;

    insert into stock_changes (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_order.product_id, v_product.farm_id, v_me,
            v_product.quantity, v_product.quantity + v_order.quantity,
            'Order cancelled - stock returned', 'order');

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

-- ---------------------------------------------------------------------------
-- 5. FARMER TIME IN / TIME OUT
-- The farmer records their own timestamps. Hours are derived from the clock,
-- not typed in, so the work log becomes evidence rather than an estimate.
-- ---------------------------------------------------------------------------
alter table public.attendance
  add column if not exists time_in timestamptz,
  add column if not exists time_out timestamptz,
  add column if not exists source text not null default 'owner';

create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_standard numeric(5,2);
  v_hours    numeric(6,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

  -- When both clock stamps exist, they are the source of truth for hours.
  if new.time_in is not null and new.time_out is not null then
    v_hours := round(extract(epoch from (new.time_out - new.time_in)) / 3600.0, 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage * least(new.hours_worked / v_standard, 1), 2);
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

-- Clock in. Uses the farmer's accepted job to find the farm and daily rate.
create or replace function public.farmer_time_in()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for any job.';
  end if;

  select id into v_id
    from attendance
   where farmer_id = v_me and work_date = v_today and job_id = v_app.job_id;

  if v_id is not null then
    if (select time_out from attendance where id = v_id) is null then
      raise exception 'You are already timed in for today.';
    end if;
    raise exception 'You have already completed your shift today.';
  end if;

  insert into attendance
    (farm_id, job_id, farmer_id, work_date, status, hours_worked,
     daily_wage, time_in, source, recorded_by)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me)
  returning id into v_id;

  return v_id;
end $$;

create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You have not timed in today.';
  end if;

  update attendance set time_out = now() where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage)
       from attendance a
       join farms f on f.id = a.farm_id
       left join job_posts j on j.id = a.job_id
      where a.farmer_id = public.my_profile_id('farmer')
        and a.work_date = current_date
        and a.time_out is null
      limit 1),
    'null'::json
  );
$$;

grant execute on function public.farmer_time_in() to authenticated;
grant execute on function public.farmer_time_out() to authenticated;
grant execute on function public.my_open_shift() to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-8.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\migration-9.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 9
--  Let a farmer choose which job they are clocking in for.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- Every job this farmer is currently hired for, so the time clock can offer a
-- choice when they work for more than one farm.
create or replace function public.my_active_jobs()
returns table (
  job_id    uuid,
  job_title text,
  farm_id   uuid,
  farm_name text,
  wage      numeric,
  clocked   boolean
)
language sql stable security definer set search_path = public
as $$
  select j.id,
         j.title,
         f.id,
         f.name,
         j.wage,
         exists (
           select 1 from attendance a
            where a.farmer_id = public.my_profile_id('farmer')
              and a.job_id = j.id
              and a.work_date = current_date
         )
    from job_applications ap
    join job_posts j on j.id = ap.job_id
    join farms f on f.id = j.farm_id
   where ap.farmer_id = public.my_profile_id('farmer')
     and ap.status = 'accepted'
     and coalesce(ap.employment_status, 'active') = 'active'
   order by f.name, j.title;
$$;

grant execute on function public.my_active_jobs() to authenticated;

-- Clock in against a specific job.
create or replace function public.farmer_time_in(p_job_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
     and (p_job_id is null or a.job_id = p_job_id)
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for that job.';
  end if;

  if exists (
    select 1 from attendance
     where farmer_id = v_me and work_date = v_today and time_out is null
  ) then
    raise exception 'You are already timed in. Time out first.';
  end if;

  select id into v_id
    from attendance
   where farmer_id = v_me and work_date = v_today and job_id = v_app.job_id;

  if v_id is not null then
    raise exception 'You have already completed a shift for this job today.';
  end if;

  insert into attendance
    (farm_id, job_id, farmer_id, work_date, status, hours_worked,
     daily_wage, time_in, source, recorded_by)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.farmer_time_in(uuid) to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-10.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 10
--  Overtime pay and profile pictures.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- OVERTIME
-- Pay was capped at one standard day however many hours were worked. A farm
-- owner may legitimately want longer shifts paid in full, so the cap is gone:
-- pay is now strictly proportional to hours.
-- ---------------------------------------------------------------------------
create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_standard numeric(5,2);
  v_hours    numeric(6,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

  if new.time_in is not null and new.time_out is not null then
    v_hours := round(extract(epoch from (new.time_out - new.time_in)) / 3600.0, 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage * (new.hours_worked / v_standard), 2);
  end if;

  return new;
end $$;

-- ---------------------------------------------------------------------------
-- PROFILE PICTURES
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 3145728,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists av_read on storage.objects;
create policy av_read on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists av_write on storage.objects;
create policy av_write on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists av_update on storage.objects;
create policy av_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists av_delete on storage.objects;
create policy av_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.profiles
  add column if not exists avatar_url text;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-11.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 11
--  Administrator invitations.
--
--  A second administrator can only exist if an existing administrator approves
--  the request. Nobody can make themselves an admin, and the single-admin
--  index is replaced by an approval workflow rather than removed outright.
--
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- The one-admin index is replaced by a controlled process, so it goes.
drop index if exists public.profiles_single_admin;

create table if not exists public.admin_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  requester_id  uuid not null references public.profiles(id) on delete cascade,
  full_name     text not null default '',
  phone         text not null default '',
  reason        text not null default '',
  status        verification_status not null default 'pending',
  review_notes  text,
  reviewed_by   uuid references public.profiles(id) on delete set null,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists admin_requests_status_idx on public.admin_requests(status);

-- Only one open request per person at a time.
create unique index if not exists admin_requests_one_pending
  on public.admin_requests (user_id)
  where status = 'pending';

alter table public.admin_requests enable row level security;

drop policy if exists ar_select on public.admin_requests;
create policy ar_select on public.admin_requests for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists ar_insert on public.admin_requests;
create policy ar_insert on public.admin_requests for insert to authenticated
  with check (user_id = auth.uid() and public.is_mine(requester_id));

-- ---------------------------------------------------------------------------
-- REQUEST ADMIN ACCESS
-- Anyone with an existing verified account may ask. It creates nothing but a
-- request; the admin role is only granted on approval.
-- ---------------------------------------------------------------------------
create or replace function public.request_admin_access(p_reason text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_profile profiles%rowtype;
  v_id      uuid;
begin
  select * into v_profile
    from profiles
   where user_id = auth.uid()
   order by created_at
   limit 1;

  if not found then
    raise exception 'Create an account first, then request administrator access.';
  end if;

  if exists (select 1 from profiles where user_id = auth.uid() and role = 'admin') then
    raise exception 'You are already an administrator.';
  end if;

  if exists (
    select 1 from admin_requests where user_id = auth.uid() and status = 'pending'
  ) then
    raise exception 'You already have a request waiting for review.';
  end if;

  insert into admin_requests (user_id, requester_id, full_name, phone, reason)
  values (auth.uid(), v_profile.id, v_profile.name, v_profile.phone, trim(p_reason))
  returning id into v_id;

  -- Tell every current administrator.
  insert into notifications (user_id, message, type, link)
  select p.id,
         coalesce(nullif(v_profile.name, ''), 'Someone') ||
         ' has requested administrator access.',
         'verification', '/admin/requests'
    from profiles p
   where p.role = 'admin';

  return v_id;
end $$;

grant execute on function public.request_admin_access(text) to authenticated;

-- ---------------------------------------------------------------------------
-- REVIEW AN ADMIN REQUEST
-- Approving creates the admin profile. Only an existing administrator can do
-- this, and nobody can approve their own request.
-- ---------------------------------------------------------------------------
create or replace function public.review_admin_request(
  p_request_id uuid,
  p_decision verification_status,
  p_notes text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_req admin_requests%rowtype;
  v_me  uuid := public.my_profile_id('admin');
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can review these requests.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected.';
  end if;

  select * into v_req from admin_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found.'; end if;

  if v_req.user_id = auth.uid() then
    raise exception 'You cannot approve your own request.';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already reviewed.';
  end if;

  update admin_requests
     set status = p_decision,
         review_notes = nullif(p_notes,''),
         reviewed_by = v_me,
         reviewed_at = now()
   where id = p_request_id;

  if p_decision = 'approved' then
    if not exists (select 1 from profiles where user_id = v_req.user_id and role = 'admin') then
      insert into profiles (user_id, role, name, phone)
      values (v_req.user_id, 'admin',
              coalesce(nullif(v_req.full_name,''), 'Administrator'),
              v_req.phone);
    end if;
  end if;

  insert into notifications (user_id, message, type, link)
  values (v_req.requester_id,
          case when p_decision = 'approved'
               then 'Your administrator access has been approved. Sign in at the admin panel.'
               else 'Your request for administrator access was declined.' ||
                    coalesce(' Reason: ' || nullif(p_notes,''), '')
          end,
          'verification', '/');
end $$;

grant execute on function public.review_admin_request(uuid, verification_status, text) to authenticated;

-- ---------------------------------------------------------------------------
-- REMOVE AN ADMINISTRATOR
-- The last administrator cannot be removed, or the system would be locked out
-- of its own management functions.
-- ---------------------------------------------------------------------------
create or replace function public.revoke_admin(p_profile_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_count int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can do this.';
  end if;
  if p_profile_id = public.my_profile_id('admin') then
    raise exception 'You cannot remove your own administrator access.';
  end if;

  select count(*) into v_count from profiles where role = 'admin';
  if v_count <= 1 then
    raise exception 'There must always be at least one administrator.';
  end if;

  delete from profiles where id = p_profile_id and role = 'admin';
end $$;

grant execute on function public.revoke_admin(uuid) to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-12.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 12
--  Connects Calendar -> Worklog -> Finance -> Market.
--  A planting schedule becomes the record everything else hangs off.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

do $$ begin
  create type schedule_status as enum ('planned','planted','growing','harvested','cancelled');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- SCHEDULES become full planting records
-- ---------------------------------------------------------------------------
alter table public.schedules
  add column if not exists variety           text not null default '',
  add column if not exists planting_date     date,
  add column if not exists harvest_date      date,
  add column if not exists seed_kg           numeric(10,2) not null default 0,
  add column if not exists area_ha           numeric(10,2),
  add column if not exists field_name        text,
  add column if not exists expected_sacks    int not null default 0,
  add column if not exists actual_sacks      int,
  add column if not exists status            schedule_status not null default 'planned',
  add column if not exists note              text,
  add column if not exists listed_product_id uuid references public.products(id) on delete set null;

-- Fill planting_date on older rows from the YYYY-MM they were created with.
update public.schedules
   set planting_date = to_date(planting_month || '-01', 'YYYY-MM-DD')
 where planting_date is null;

update public.schedules
   set harvest_date = (planting_date + (estimated_months || ' months')::interval)::date
 where harvest_date is null and planting_date is not null;

-- The rule preventing duplicate plantings is created by fix-schedules.sql,
-- which runs AFTER this file. It is kept separate because the Supabase SQL
-- Editor runs each script in one transaction: if the index failed here on
-- existing duplicate rows, every column added above would roll back with it.

-- ---------------------------------------------------------------------------
-- YIELD REFERENCE
-- Expected harvest is worked out from the seed weight, using a yield ratio per
-- crop. Stored in a table rather than the code so the numbers can be corrected
-- against real local results without a redeploy.
-- ---------------------------------------------------------------------------
create table if not exists public.crop_yields (
  crop            crop_type not null,
  variety         text not null default '',
  kg_per_kg_seed  numeric(10,2) not null,
  days_to_harvest int not null,
  primary key (crop, variety)
);

insert into public.crop_yields (crop, variety, kg_per_kg_seed, days_to_harvest) values
  ('rice',       '', 80,  115),
  ('rice',       'Dinorado', 70, 120),
  ('rice',       'Sinandomeng', 78, 115),
  ('rice',       'IR64', 90, 110),
  ('rice',       'NSIC Rc222 (Tubigan 18)', 95, 112),
  ('corn',       '', 200, 100),
  ('corn',       'Sweet Corn', 170, 75),
  ('corn',       'White Corn', 200, 105),
  ('corn',       'Yellow Corn', 220, 100),
  ('watermelon', '', 300, 80),
  ('watermelon', 'Sweet Beauty', 320, 75),
  ('watermelon', 'Sugar Baby', 280, 80)
on conflict (crop, variety) do update
  set kg_per_kg_seed = excluded.kg_per_kg_seed,
      days_to_harvest = excluded.days_to_harvest;

alter table public.crop_yields enable row level security;

drop policy if exists cy_read on public.crop_yields;
create policy cy_read on public.crop_yields for select to authenticated using (true);

-- Expected sacks from a seed weight. Falls back to the crop's default row when
-- the variety has no specific figure.
create or replace function public.estimate_harvest(
  p_crop crop_type,
  p_variety text,
  p_seed_kg numeric
)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ratio numeric;
  v_days  int;
  v_kg    numeric;
begin
  select kg_per_kg_seed, days_to_harvest into v_ratio, v_days
    from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));

  if v_ratio is null then
    select kg_per_kg_seed, days_to_harvest into v_ratio, v_days
      from crop_yields where crop = p_crop and variety = '';
  end if;

  v_kg := coalesce(p_seed_kg, 0) * coalesce(v_ratio, 0);

  return json_build_object(
    'kg_per_kg_seed', coalesce(v_ratio, 0),
    'days_to_harvest', coalesce(v_days, 100),
    'expected_kg', round(v_kg, 2),
    'expected_sacks', floor(v_kg / 25)::int
  );
end $$;

grant execute on function public.estimate_harvest(crop_type, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- FINANCE LINKED TO A CROP
-- Every cost now belongs to a planting, so profit can be worked out per crop
-- instead of only across the whole farm.
-- ---------------------------------------------------------------------------
alter table public.transactions
  add column if not exists schedule_id uuid references public.schedules(id) on delete set null,
  add column if not exists crop crop_type;

create index if not exists transactions_schedule_idx on public.transactions(schedule_id);

-- ---------------------------------------------------------------------------
-- WORKLOG LINKED TO A CROP
-- ---------------------------------------------------------------------------
alter table public.attendance
  add column if not exists schedule_id uuid references public.schedules(id) on delete set null,
  add column if not exists task text not null default 'General farm work';

create index if not exists attendance_schedule_idx on public.attendance(schedule_id);

-- ---------------------------------------------------------------------------
-- RECORD A COST AGAINST A PLANTING
-- Expenses are entered where the work happens, not on a separate Finance form,
-- which is what stops the same cost being typed in twice.
-- ---------------------------------------------------------------------------
create or replace function public.add_crop_expense(
  p_schedule_id uuid,
  p_category text,
  p_amount numeric,
  p_description text default '',
  p_date date default current_date
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_sched schedules%rowtype;
  v_id    uuid;
begin
  select * into v_sched from schedules where id = p_schedule_id;
  if not found then raise exception 'That planting no longer exists.'; end if;
  if not public.owns_farm(v_sched.farm_id) then
    raise exception 'You can only record costs on your own farm.';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'Enter a valid amount.';
  end if;

  insert into transactions
    (farm_id, type, category, amount, description, date, schedule_id, crop)
  values (v_sched.farm_id, 'expense', p_category, p_amount,
          coalesce(nullif(p_description,''),
                   p_category || ' for ' || v_sched.crop ||
                   coalesce(' (' || nullif(v_sched.variety,'') || ')', '')),
          p_date, p_schedule_id, v_sched.crop)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.add_crop_expense(uuid, text, numeric, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- HARVEST A PLANTING AND LIST IT
-- Records the real sack count, adds it to inventory, and puts it on the market
-- in one step, so the harvest does not have to be typed in three places.
-- ---------------------------------------------------------------------------
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
         status = 'harvested'
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
         'Harvest recorded: ' || v_sacks || ' sacks of ' || v_variety ||
         case when v_pid is not null then ' - now listed on the market.' else '.' end,
         'harvest', '/owner/calendar'
    from farms f where f.id = v_sched.farm_id;

  select json_build_object('sacks', v_sacks, 'product_id', v_pid) into v_result;
  return v_result;
end $$;

grant execute on function public.harvest_schedule(uuid, int, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- PROFIT PER PLANTING
-- Costs recorded against the crop, against income from what it sold for.
-- ---------------------------------------------------------------------------
create or replace function public.crop_profit(p_farm_id uuid)
returns table (
  schedule_id    uuid,
  crop           crop_type,
  variety        text,
  status         schedule_status,
  planting_date  date,
  harvest_date   date,
  expected_sacks int,
  actual_sacks   int,
  expenses       numeric,
  income         numeric,
  estimated_value numeric
)
language sql stable security definer set search_path = public
as $$
  select s.id,
         s.crop,
         s.variety,
         s.status,
         s.planting_date,
         s.harvest_date,
         s.expected_sacks,
         s.actual_sacks,
         coalesce((select sum(t.amount) from transactions t
                    where t.schedule_id = s.id and t.type = 'expense'), 0),
         coalesce((select sum(o.total_price) from orders o
                    where o.product_id = s.listed_product_id
                      and o.stage = 'completed'), 0),
         coalesce(s.expected_sacks, 0) *
           coalesce((select p.price from products p where p.id = s.listed_product_id),
                    (select avg(p2.price) from products p2
                      where p2.farm_id = s.farm_id and p2.crop = s.crop), 0)
    from schedules s
   where s.farm_id = p_farm_id
     and public.owns_farm(s.farm_id)
   order by s.planting_date desc;
$$;

grant execute on function public.crop_profit(uuid) to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-13.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 13
--  Work hours on a job post, and a clock-in window tied to them.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.job_posts
  add column if not exists start_time time not null default '06:00',
  add column if not exists end_time   time not null default '15:00';

-- ---------------------------------------------------------------------------
-- A farmer may clock in or out only within one hour either side of the times
-- the farm owner set. Enforced here as well as in the interface, so the window
-- cannot be bypassed by calling the API directly.
-- ---------------------------------------------------------------------------
drop function if exists public.my_active_jobs();

drop function if exists public.farmer_time_in();

create function public.my_active_jobs()
returns table (
  job_id     uuid,
  job_title  text,
  farm_id    uuid,
  farm_name  text,
  wage       numeric,
  start_time time,
  end_time   time,
  clocked    boolean
)
language sql stable security definer set search_path = public
as $$
  select j.id,
         j.title,
         f.id,
         f.name,
         j.wage,
         j.start_time,
         j.end_time,
         exists (
           select 1 from attendance a
            where a.farmer_id = public.my_profile_id('farmer')
              and a.job_id = j.id
              and a.work_date = current_date
         )
    from job_applications ap
    join job_posts j on j.id = ap.job_id
    join farms f on f.id = j.farm_id
   where ap.farmer_id = public.my_profile_id('farmer')
     and ap.status = 'accepted'
     and coalesce(ap.employment_status, 'active') = 'active'
   order by f.name, j.title;
$$;

grant execute on function public.my_active_jobs() to authenticated;

create or replace function public.farmer_time_in(p_job_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
  v_now   time := (now() at time zone 'Asia/Manila')::time;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage, j.start_time, j.end_time, j.title
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
     and (p_job_id is null or a.job_id = p_job_id)
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for that job.';
  end if;

  if v_now < (v_app.start_time - interval '1 hour')
     or v_now > (v_app.start_time + interval '1 hour') then
    raise exception 'You can only time in between % and % for this job.',
      to_char(v_app.start_time - interval '1 hour', 'FMHH12:MI AM'),
      to_char(v_app.start_time + interval '1 hour', 'FMHH12:MI AM');
  end if;

  if exists (
    select 1 from attendance
     where farmer_id = v_me and work_date = v_today and time_out is null
  ) then
    raise exception 'You are already timed in. Time out first.';
  end if;

  select id into v_id
    from attendance
   where farmer_id = v_me and work_date = v_today and job_id = v_app.job_id;

  if v_id is not null then
    raise exception 'You have already completed a shift for this job today.';
  end if;

  insert into attendance
    (farm_id, job_id, farmer_id, work_date, status, hours_worked,
     daily_wage, time_in, source, recorded_by, task)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me, coalesce(v_app.title, 'Farm work'))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.farmer_time_in(uuid) to authenticated;

create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
  v_end time;
  v_now time := (now() at time zone 'Asia/Manila')::time;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You have not timed in today.';
  end if;

  select end_time into v_end from job_posts where id = v_row.job_id;

  if v_end is not null then
    if v_now < (v_end - interval '1 hour') or v_now > (v_end + interval '1 hour') then
      raise exception 'You can only time out between % and % for this job.',
        to_char(v_end - interval '1 hour', 'FMHH12:MI AM'),
        to_char(v_end + interval '1 hour', 'FMHH12:MI AM');
    end if;
  end if;

  update attendance set time_out = now() where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

grant execute on function public.farmer_time_out() to authenticated;

create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage,
       'start_time', j.start_time, 'end_time', j.end_time)
       from attendance a
       join farms f on f.id = a.farm_id
       left join job_posts j on j.id = a.job_id
      where a.farmer_id = public.my_profile_id('farmer')
        and a.work_date = current_date
        and a.time_out is null
      limit 1),
    'null'::json
  );
$$;

grant execute on function public.my_open_shift() to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-14.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 14
--  Farmers can pause and resume a shift. Break time is subtracted from the
--  hours worked, so pay reflects time actually on the job.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.attendance
  add column if not exists break_started_at timestamptz,
  add column if not exists break_minutes numeric(8,2) not null default 0;

create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_standard numeric(5,2);
  v_hours    numeric(6,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

  if new.time_in is not null and new.time_out is not null then
    v_hours := round(
      (extract(epoch from (new.time_out - new.time_in)) / 3600.0)
      - (coalesce(new.break_minutes, 0) / 60.0), 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage * (new.hours_worked / v_standard), 2);
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

create or replace function public.farmer_pause_shift()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You are not timed in right now.';
  end if;
  if v_row.break_started_at is not null then
    raise exception 'Your break has already started.';
  end if;

  update attendance set break_started_at = now() where id = v_row.id;
end $$;

create or replace function public.farmer_resume_shift()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_row   attendance%rowtype;
  v_added numeric(8,2);
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You are not timed in right now.';
  end if;
  if v_row.break_started_at is null then
    raise exception 'You are not on a break.';
  end if;

  v_added := round(extract(epoch from (now() - v_row.break_started_at)) / 60.0, 2);

  update attendance
     set break_minutes = coalesce(break_minutes, 0) + greatest(v_added, 0),
         break_started_at = null
   where id = v_row.id;
end $$;

grant execute on function public.farmer_pause_shift() to authenticated;
grant execute on function public.farmer_resume_shift() to authenticated;

-- A shift that is paused when the farmer times out closes the break first.
create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
  v_end time;
  v_now time := (now() at time zone 'Asia/Manila')::time;
  v_add numeric(8,2) := 0;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You have not timed in today.';
  end if;

  select end_time into v_end from job_posts where id = v_row.job_id;

  if v_end is not null then
    if v_now < (v_end - interval '1 hour') or v_now > (v_end + interval '1 hour') then
      raise exception 'You can only time out between % and % for this job.',
        to_char(v_end - interval '1 hour', 'FMHH12:MI AM'),
        to_char(v_end + interval '1 hour', 'FMHH12:MI AM');
    end if;
  end if;

  if v_row.break_started_at is not null then
    v_add := round(extract(epoch from (now() - v_row.break_started_at)) / 60.0, 2);
  end if;

  update attendance
     set time_out = now(),
         break_minutes = coalesce(break_minutes, 0) + greatest(v_add, 0),
         break_started_at = null
   where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

create or replace function public.my_open_shift()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select json_build_object(
       'id', a.id, 'time_in', a.time_in, 'work_date', a.work_date,
       'farm', f.name, 'job', j.title, 'wage', a.daily_wage,
       'start_time', j.start_time, 'end_time', j.end_time,
       'break_started_at', a.break_started_at,
       'break_minutes', a.break_minutes)
       from attendance a
       join farms f on f.id = a.farm_id
       left join job_posts j on j.id = a.job_id
      where a.farmer_id = public.my_profile_id('farmer')
        and a.work_date = current_date
        and a.time_out is null
      limit 1),
    'null'::json
  );
$$;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-15.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 15
--  Wage payment now needs both sides. The farm owner marks a day as sent, and
--  it stays pending until the farmer confirms they received it. Once confirmed
--  it cannot be undone, so the record stands as proof for both parties.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

do $$ begin
  create type payment_state as enum ('unpaid','pending','paid');
exception when duplicate_object then null; end $$;

alter table public.attendance
  add column if not exists payment_status payment_state not null default 'unpaid',
  add column if not exists payment_sent_at timestamptz,
  add column if not exists payment_confirmed_at timestamptz;

update public.attendance
   set payment_status = 'paid',
       payment_confirmed_at = coalesce(payment_confirmed_at, paid_at, now())
 where paid = true and payment_status = 'unpaid';

-- ---------------------------------------------------------------------------
-- OWNER: mark a day's wage as sent. It becomes pending, not paid.
-- ---------------------------------------------------------------------------
create or replace function public.set_attendance_paid(
  p_attendance_id uuid,
  p_paid boolean
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row attendance%rowtype;
  v_me  uuid := public.my_profile_id('owner');
begin
  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That work day no longer exists.';
  end if;

  if not public.owns_farm(v_row.farm_id) and not public.is_admin() then
    raise exception 'You can only settle wages for your own farm.';
  end if;

  if v_row.payment_status = 'paid' then
    raise exception 'The farmer already confirmed this payment, so it cannot be changed.';
  end if;

  if p_paid then
    if v_row.computed_pay <= 0 then
      raise exception 'There is no wage to pay for this day.';
    end if;

    update attendance
       set payment_status = 'pending',
           payment_sent_at = now(),
           paid_by = v_me,
           paid = false
     where id = p_attendance_id;

    insert into notifications (user_id, message, type, link)
    values (v_row.farmer_id,
            'Your wage of PHP ' || v_row.computed_pay || ' for ' ||
            to_char(v_row.work_date, 'FMMon DD, YYYY') ||
            ' has been sent. Confirm once you receive it.',
            'general', '/farmer/history');
  else
    update attendance
       set payment_status = 'unpaid',
           payment_sent_at = null,
           paid_by = null,
           paid = false
     where id = p_attendance_id;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- FARMER: confirm the wage was received. This is final.
-- ---------------------------------------------------------------------------
create or replace function public.farmer_confirm_payment(p_attendance_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row  attendance%rowtype;
  v_me   uuid := public.my_profile_id('farmer');
  v_name text;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to confirm a payment.';
  end if;

  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That work day no longer exists.';
  end if;
  if v_row.farmer_id <> v_me then
    raise exception 'You can only confirm your own wages.';
  end if;
  if v_row.payment_status = 'paid' then
    raise exception 'You have already confirmed this payment.';
  end if;
  if v_row.payment_status <> 'pending' then
    raise exception 'The farm owner has not sent this wage yet.';
  end if;

  update attendance
     set payment_status = 'paid',
         payment_confirmed_at = now(),
         paid = true,
         paid_at = now()
   where id = p_attendance_id;

  select name into v_name from profiles where id = v_me;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         coalesce(v_name, 'A worker') || ' confirmed receiving PHP ' || v_row.computed_pay ||
         ' for ' || to_char(v_row.work_date, 'FMMon DD, YYYY') || '.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;
end $$;

grant execute on function public.farmer_confirm_payment(uuid) to authenticated;

-- Farmers need to read their own attendance to confirm it; the existing
-- att_select policy already allows this.
notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-16.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\migration-17.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 17
--  One planting per crop per day. Rice planted today blocks another rice
--  planting that same day, but corn and watermelon stay available.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

drop index if exists public.schedules_no_duplicates;

-- Close any same-crop, same-day duplicates before the new rule is applied.
with ranked as (
  select id,
         row_number() over (
           partition by farm_id, crop, planting_date
           order by created_at
         ) as rn
    from public.schedules
   where status <> 'cancelled'
     and planting_date is not null
)
update public.schedules s
   set status = 'cancelled',
       note = coalesce(nullif(s.note, '') || ' | ', '') ||
              'Closed automatically: another planting of this crop exists on the same day'
  from ranked r
 where r.id = s.id
   and r.rn > 1;

create unique index if not exists schedules_one_crop_per_day
  on public.schedules (farm_id, crop, planting_date)
  where status <> 'cancelled';

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-18.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\migration-19.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 19
--  Planting the same variety twice on one day adds to the first entry instead
--  of stacking a second one. Different varieties on the same day stay separate.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

create or replace function public.add_or_merge_planting(
  p_farm_id       uuid,
  p_crop          crop_type,
  p_variety       text,
  p_planting_date date,
  p_seed_kg       numeric,
  p_note          text default ''
)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_existing schedules%rowtype;
  v_est      json;
  v_seed     numeric;
  v_days     int;
  v_id       uuid;
  v_merged   boolean := false;
begin
  if not public.owns_farm(p_farm_id) then
    raise exception 'You can only plan plantings on your own farm.';
  end if;
  if coalesce(p_seed_kg, 0) <= 0 then
    raise exception 'Enter the seed weight in kilograms.';
  end if;
  if coalesce(trim(p_variety), '') = '' then
    raise exception 'Choose or name the variety.';
  end if;

  select * into v_existing
    from schedules
   where farm_id = p_farm_id
     and crop = p_crop
     and lower(trim(variety)) = lower(trim(p_variety))
     and planting_date = p_planting_date
     and status <> 'cancelled'
   order by created_at
   limit 1
   for update;

  if found then
    if v_existing.status = 'harvested' then
      raise exception 'That planting was already harvested, so seed cannot be added to it.';
    end if;
    v_seed := coalesce(v_existing.seed_kg, 0) + p_seed_kg;
  else
    v_seed := p_seed_kg;
  end if;

  v_est := public.estimate_harvest(p_crop, p_variety, v_seed);
  v_days := (v_est ->> 'days_to_harvest')::int;

  if found then
    update schedules
       set seed_kg = v_seed,
           expected_sacks = (v_est ->> 'expected_sacks')::int,
           harvest_date = (p_planting_date + (v_days || ' days')::interval)::date,
           note = case
                    when coalesce(trim(p_note), '') = '' then note
                    else coalesce(nullif(note, '') || ' | ', '') || trim(p_note)
                  end
     where id = v_existing.id;

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into schedules
      (farm_id, crop, variety, planting_month, planting_date, harvest_date,
       estimated_months, seed_kg, expected_sacks, status, note)
    values (p_farm_id, p_crop, trim(p_variety),
            to_char(p_planting_date, 'YYYY-MM'),
            p_planting_date,
            (p_planting_date + (v_days || ' days')::interval)::date,
            greatest(1, round(v_days / 30.0)::int),
            v_seed,
            (v_est ->> 'expected_sacks')::int,
            case when p_planting_date > current_date then 'planned'::schedule_status
                 else 'planted'::schedule_status end,
            nullif(trim(p_note), ''))
    returning id into v_id;
  end if;

  return json_build_object(
    'id', v_id,
    'merged', v_merged,
    'seed_kg', v_seed,
    'expected_sacks', (v_est ->> 'expected_sacks')::int
  );
end $$;

grant execute on function public.add_or_merge_planting(uuid, crop_type, text, date, numeric, text)
  to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-20.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 20
--  Farmers may clock in at any time. The window tied to the job's work hours
--  is removed, so a shift is recorded whenever the work actually happens.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

create or replace function public.farmer_time_in(p_job_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('farmer');
  v_app   record;
  v_id    uuid;
  v_today date := current_date;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select a.job_id, j.farm_id, j.wage, j.title
    into v_app
    from job_applications a
    join job_posts j on j.id = a.job_id
   where a.farmer_id = v_me
     and a.status = 'accepted'
     and coalesce(a.employment_status, 'active') = 'active'
     and (p_job_id is null or a.job_id = p_job_id)
   order by a.updated_at desc
   limit 1;

  if v_app.job_id is null then
    raise exception 'You are not currently hired for that job.';
  end if;

  if exists (
    select 1 from attendance
     where farmer_id = v_me and work_date = v_today and time_out is null
  ) then
    raise exception 'You are already timed in. Time out first.';
  end if;

  select id into v_id
    from attendance
   where farmer_id = v_me and work_date = v_today and job_id = v_app.job_id;

  if v_id is not null then
    raise exception 'You have already completed a shift for this job today.';
  end if;

  insert into attendance
    (farm_id, job_id, farmer_id, work_date, status, hours_worked,
     daily_wage, time_in, source, recorded_by, task)
  values (v_app.farm_id, v_app.job_id, v_me, v_today, 'present', 0,
          v_app.wage, now(), 'farmer', v_me, coalesce(v_app.title, 'Farm work'))
  returning id into v_id;

  return v_id;
end $$;

create or replace function public.farmer_time_out()
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_me  uuid := public.my_profile_id('farmer');
  v_row attendance%rowtype;
  v_add numeric(8,2) := 0;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to record your time.';
  end if;

  select * into v_row
    from attendance
   where farmer_id = v_me and work_date = current_date and time_out is null
   order by time_in desc
   limit 1
   for update;

  if not found then
    raise exception 'You have not timed in today.';
  end if;

  if v_row.break_started_at is not null then
    v_add := round(extract(epoch from (now() - v_row.break_started_at)) / 60.0, 2);
  end if;

  update attendance
     set time_out = now(),
         break_minutes = coalesce(break_minutes, 0) + greatest(v_add, 0),
         break_started_at = null
   where id = v_row.id;

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         (select name from profiles where id = v_me) || ' timed out for today.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;

  return v_row.id;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- PAY PER JOB
-- A completed day earns the full agreed wage whatever the hours. Hours and
-- breaks are still recorded, so the log remains a truthful account of the day,
-- but they no longer scale the pay up or down.
-- ---------------------------------------------------------------------------
create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_hours numeric(6,2);
begin
  if new.time_in is not null and new.time_out is not null then
    v_hours := round(
      (extract(epoch from (new.time_out - new.time_in)) / 3600.0)
      - (coalesce(new.break_minutes, 0) / 60.0), 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage, 2);
  end if;

  return new;
end $$;

drop trigger if exists trg_compute_attendance_pay on public.attendance;
create trigger trg_compute_attendance_pay
  before insert or update on public.attendance
  for each row execute function public.compute_attendance_pay();

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-21.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 21
--  Farm location, two-way ratings with abuse protection, privacy consent,
--  and a selfie for identity verification.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. FARM LOCATION
-- ---------------------------------------------------------------------------
alter table public.farms
  add column if not exists latitude  numeric(10,7),
  add column if not exists longitude numeric(10,7),
  add column if not exists location_note text;

-- ---------------------------------------------------------------------------
-- 2. PRIVACY CONSENT
-- Recorded per account so it can be shown that consent was given, and when.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists privacy_accepted_at timestamptz,
  add column if not exists selfie_photo_path text;

alter table public.owner_verifications
  add column if not exists selfie_path text,
  add column if not exists id_checked boolean not null default false,
  add column if not exists selfie_matches boolean not null default false;

-- ---------------------------------------------------------------------------
-- 3. RATINGS
-- A rating must point at a real completed dealing: an order for buyer/owner
-- ratings, or an accepted job for worker ratings. One rating per dealing, so
-- nobody can inflate a score by rating the same person repeatedly.
-- ---------------------------------------------------------------------------
do $$ begin
  create type rating_context as enum ('order','work');
exception when duplicate_object then null; end $$;

create table if not exists public.ratings (
  id           uuid primary key default gen_random_uuid(),
  context      rating_context not null,
  order_id     uuid references public.orders(id) on delete cascade,
  job_id       uuid references public.job_posts(id) on delete cascade,
  rater_id     uuid not null references public.profiles(id) on delete cascade,
  ratee_id     uuid not null references public.profiles(id) on delete cascade,
  stars        int not null check (stars between 1 and 5),
  comment      text,
  hidden       boolean not null default false,
  created_at   timestamptz not null default now(),
  check (rater_id <> ratee_id),
  check ((context = 'order' and order_id is not null)
      or (context = 'work'  and job_id is not null))
);

create unique index if not exists ratings_one_per_order
  on public.ratings (order_id, rater_id) where order_id is not null;

create unique index if not exists ratings_one_per_job
  on public.ratings (job_id, rater_id, ratee_id) where job_id is not null;

create index if not exists ratings_ratee_idx on public.ratings(ratee_id) where hidden = false;

alter table public.ratings enable row level security;

drop policy if exists ratings_select on public.ratings;
create policy ratings_select on public.ratings for select to authenticated
  using (hidden = false or public.is_admin() or public.is_mine(rater_id));

-- ---------------------------------------------------------------------------
-- 4. LEAVE A RATING
-- Checks the dealing really happened and really finished before accepting.
-- ---------------------------------------------------------------------------
create or replace function public.rate_order(
  p_order_id uuid,
  p_stars int,
  p_comment text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_order   orders%rowtype;
  v_product products%rowtype;
  v_farm    farms%rowtype;
  v_me      uuid;
  v_ratee   uuid;
  v_recent  int;
begin
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'Give a rating between 1 and 5 stars.';
  end if;

  select * into v_order from orders where id = p_order_id;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.stage <> 'completed' then
    raise exception 'You can only rate once the order is completed.';
  end if;

  select * into v_product from products where id = v_order.product_id;
  select * into v_farm from farms where id = v_product.farm_id;

  v_me := public.my_profile_id('buyer');
  if v_me is not null and v_order.buyer_id = v_me then
    v_ratee := v_farm.owner_id;
  else
    v_me := public.my_profile_id('owner');
    if v_me is null or v_farm.owner_id <> v_me then
      raise exception 'You were not part of this order.';
    end if;
    v_ratee := v_order.buyer_id;
  end if;

  if exists (select 1 from profiles where id = v_me and restricted) then
    raise exception 'Your account is restricted from leaving ratings.';
  end if;

  select count(*) into v_recent
    from ratings
   where rater_id = v_me
     and created_at > now() - interval '1 hour';

  if v_recent >= 10 then
    raise exception 'You have left a lot of ratings in a short time. Try again later.';
  end if;

  insert into ratings (context, order_id, rater_id, ratee_id, stars, comment)
  values ('order', p_order_id, v_me, v_ratee, p_stars, nullif(trim(p_comment), ''));

  insert into notifications (user_id, message, type, link)
  values (v_ratee, 'You received a ' || p_stars || '-star rating.', 'general', '/');
exception
  when unique_violation then
    raise exception 'You have already rated this order.';
end $$;

grant execute on function public.rate_order(uuid, int, text) to authenticated;

create or replace function public.rate_worker(
  p_job_id uuid,
  p_farmer_id uuid,
  p_stars int,
  p_comment text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_me    uuid := public.my_profile_id('owner');
  v_job   job_posts%rowtype;
  v_days  int;
begin
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'Give a rating between 1 and 5 stars.';
  end if;
  if v_me is null then
    raise exception 'Only a farm owner can rate a worker.';
  end if;

  select * into v_job from job_posts where id = p_job_id;
  if not found or v_job.owner_id <> v_me then
    raise exception 'That job is not yours.';
  end if;

  if not exists (
    select 1 from job_applications
     where job_id = p_job_id and farmer_id = p_farmer_id and status = 'accepted'
  ) then
    raise exception 'You can only rate a worker you hired.';
  end if;

  if exists (select 1 from profiles where id = v_me and restricted) then
    raise exception 'Your account is restricted from leaving ratings.';
  end if;

  select count(*) into v_days
    from attendance
   where job_id = p_job_id and farmer_id = p_farmer_id and time_out is not null;

  if v_days = 0 then
    raise exception 'This worker has not completed a logged day yet.';
  end if;

  insert into ratings (context, job_id, rater_id, ratee_id, stars, comment)
  values ('work', p_job_id, v_me, p_farmer_id, p_stars, nullif(trim(p_comment), ''));

  insert into notifications (user_id, message, type, link)
  values (p_farmer_id, 'You received a ' || p_stars || '-star rating for your work.',
          'general', '/farmer/history');
exception
  when unique_violation then
    raise exception 'You have already rated this worker for this job.';
end $$;

grant execute on function public.rate_worker(uuid, uuid, int, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. RATING SUMMARY
-- ---------------------------------------------------------------------------
create or replace function public.rating_summary(p_profile_id uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'average', coalesce(round(avg(stars)::numeric, 2), 0),
    'total', count(*),
    'five', count(*) filter (where stars = 5),
    'four', count(*) filter (where stars = 4),
    'three', count(*) filter (where stars = 3),
    'two', count(*) filter (where stars = 2),
    'one', count(*) filter (where stars = 1)
  )
  from ratings
  where ratee_id = p_profile_id and hidden = false;
$$;

grant execute on function public.rating_summary(uuid) to authenticated;

create or replace function public.my_pending_ratings()
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce((
    select json_agg(json_build_object(
      'order_id', o.id, 'variety', p.variety, 'farm', f.name,
      'owner_id', f.owner_id, 'created_at', o.created_at))
      from orders o
      join products p on p.id = o.product_id
      join farms f on f.id = p.farm_id
     where o.buyer_id = public.my_profile_id('buyer')
       and o.stage = 'completed'
       and not exists (
         select 1 from ratings r
          where r.order_id = o.id and r.rater_id = public.my_profile_id('buyer'))
  ), '[]'::json);
$$;

grant execute on function public.my_pending_ratings() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. ABUSE PROTECTION
-- An administrator can hide a rating and warn the author. Repeated warnings
-- are counted on the profile so a pattern is visible rather than anecdotal.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists rating_warnings int not null default 0,
  add column if not exists restricted boolean not null default false;

create or replace function public.moderate_rating(p_rating_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_r ratings%rowtype;
  v_w int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can moderate ratings.';
  end if;

  select * into v_r from ratings where id = p_rating_id for update;
  if not found then raise exception 'Rating not found.'; end if;

  update ratings set hidden = true where id = p_rating_id;

  update profiles
     set rating_warnings = rating_warnings + 1
   where id = v_r.rater_id
   returning rating_warnings into v_w;

  insert into notifications (user_id, message, type, link)
  values (v_r.rater_id,
          'A rating you left was removed: ' || coalesce(nullif(p_reason,''), 'unfair or inappropriate') ||
          '. Warning ' || v_w || ' of 3. At 3 warnings your account is restricted from rating.',
          'general', '/');

  if v_w >= 3 then
    update profiles set restricted = true where id = v_r.rater_id;
    insert into notifications (user_id, message, type, link)
    values (v_r.rater_id,
            'Your account is now restricted from leaving ratings.', 'general', '/');
  end if;
end $$;

grant execute on function public.moderate_rating(uuid, text) to authenticated;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-22.sql' @'
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

'@
$script:count++

Write-ProjectFile 'supabase\migration-23.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 23
--  Consent to the Data Privacy Notice is recorded on the account itself, so
--  every route in, including Google sign-in, has to pass through it.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

create or replace function public.accept_privacy_notice()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update profiles
     set privacy_accepted_at = now()
   where user_id = auth.uid()
     and privacy_accepted_at is null;
end $$;

grant execute on function public.accept_privacy_notice() to authenticated;

create or replace function public.my_privacy_accepted()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select privacy_accepted_at is not null
       from profiles where user_id = auth.uid()
      order by created_at limit 1),
    false
  );
$$;

grant execute on function public.my_privacy_accepted() to authenticated;

-- Accounts created before this notice existed are treated as not yet consented,
-- so they are asked the next time they sign in.
notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\migration-24.sql' @'
-- ============================================================================
--  FARMS — MIGRATION 24
--  Seed-to-land calculator, milled/unmilled products, payroll timing fix,
--  application cancellation, and mandatory rejection reasons.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

alter table public.crop_yields
  add column if not exists kg_seed_per_hectare numeric(10,2);

update public.crop_yields set kg_seed_per_hectare = 50  where crop = 'rice'       and kg_seed_per_hectare is null;
update public.crop_yields set kg_seed_per_hectare = 20  where crop = 'corn'       and kg_seed_per_hectare is null;
update public.crop_yields set kg_seed_per_hectare = 0.5 where crop = 'watermelon' and kg_seed_per_hectare is null;

create or replace function public.land_needed(p_crop crop_type, p_variety text, p_seed_kg numeric)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_rate numeric;
  v_ha   numeric;
begin
  select kg_seed_per_hectare into v_rate
    from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));

  if v_rate is null then
    select kg_seed_per_hectare into v_rate from crop_yields where crop = p_crop and variety = '';
  end if;

  if coalesce(v_rate, 0) <= 0 then
    return json_build_object('hectares', 0, 'sqm', 0, 'kg_per_hectare', 0);
  end if;

  v_ha := coalesce(p_seed_kg, 0) / v_rate;

  return json_build_object(
    'hectares', round(v_ha, 4),
    'sqm', round(v_ha * 10000, 2),
    'kg_per_hectare', v_rate
  );
end $$;

grant execute on function public.land_needed(crop_type, text, numeric) to authenticated;

do $$ begin
  create type product_form as enum ('unmilled','milled');
exception when duplicate_object then null; end $$;

alter table public.products
  add column if not exists form product_form not null default 'unmilled';

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
     and form = p_form
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
            'Added ' || v_qty || ' sack(s) to the existing listing', 'manual');

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into products (farm_id, variety, crop, quantity, price, status, form)
    values (p_farm_id, trim(p_variety), p_crop, v_qty, p_price, 'available', p_form)
    returning id into v_id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_id, p_farm_id, v_me, 0, v_qty, 'New listing created', 'manual');
  end if;

  insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

grant execute on function public.add_or_merge_product(uuid, text, crop_type, int, numeric, product_form)
  to authenticated;

create or replace function public.farmer_confirm_payment(p_attendance_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row  attendance%rowtype;
  v_me   uuid := public.my_profile_id('farmer');
  v_name text;
begin
  if v_me is null then
    raise exception 'Sign in as a farmer to confirm a payment.';
  end if;

  select * into v_row from attendance where id = p_attendance_id for update;
  if not found then raise exception 'That work day no longer exists.'; end if;
  if v_row.farmer_id <> v_me then
    raise exception 'You can only confirm your own wages.';
  end if;
  if v_row.payment_status = 'paid' then
    raise exception 'You have already confirmed this payment.';
  end if;
  if v_row.payment_status <> 'pending' then
    raise exception 'The farm owner has not sent this wage yet.';
  end if;

  update attendance
     set payment_status = 'paid',
         payment_confirmed_at = now(),
         paid = true,
         paid_at = now()
   where id = p_attendance_id;

  select name into v_name from profiles where id = v_me;

  insert into transactions (farm_id, type, category, amount, description, date)
  values (v_row.farm_id, 'expense', 'Labor', v_row.computed_pay,
          'Wage paid to ' || coalesce(v_name, 'a worker') || ' for ' ||
          to_char(v_row.work_date, 'FMMon DD, YYYY'),
          current_date);

  insert into notifications (user_id, message, type, link)
  select f.owner_id,
         coalesce(v_name, 'A worker') || ' confirmed receiving PHP ' || v_row.computed_pay || '.',
         'general', '/owner/attendance'
    from farms f where f.id = v_row.farm_id;
end $$;

create or replace function public.cancel_application(p_application_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app  job_applications%rowtype;
  v_me   uuid := public.my_profile_id('farmer');
  v_job  job_posts%rowtype;
  v_name text;
begin
  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;
  if v_app.farmer_id <> v_me then
    raise exception 'You can only cancel your own application.';
  end if;
  if v_app.status = 'accepted' then
    raise exception 'You were already hired. Talk to the farm owner instead.';
  end if;

  select * into v_job from job_posts where id = v_app.job_id;
  select name into v_name from profiles where id = v_me;

  delete from job_applications where id = p_application_id;

  insert into notifications (user_id, message, type, link)
  values (v_job.owner_id,
          coalesce(v_name, 'An applicant') || ' withdrew their application for ' || v_job.title || '.',
          'application', '/owner/jobs');
end $$;

grant execute on function public.cancel_application(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- A rejected applicant must be told why.
-- The old two-argument version is dropped, or calling it with two arguments
-- would be ambiguous against the new one.
-- ---------------------------------------------------------------------------
drop function if exists public.decide_application(uuid, app_status);

create or replace function public.decide_application(
  p_application_id uuid,
  p_decision app_status,
  p_note text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app job_applications%rowtype;
  v_job job_posts%rowtype;
  v_me  uuid := public.my_profile_id('owner');
begin
  if p_decision not in ('accepted','rejected') then
    raise exception 'Decision must be accepted or rejected.';
  end if;

  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;

  select * into v_job from job_posts where id = v_app.job_id;
  if v_job.owner_id <> v_me then
    raise exception 'That job posting is not yours.';
  end if;

  if p_decision = 'rejected' and coalesce(trim(p_note), '') = '' then
    raise exception 'Give the applicant a reason for the rejection.';
  end if;

  update job_applications
     set status = p_decision,
         message = case
                     when p_decision = 'rejected'
                     then coalesce(nullif(message, '') || ' | ', '') || 'Reason: ' || trim(p_note)
                     else message
                   end,
         updated_at = now()
   where id = p_application_id;

  insert into notifications (user_id, message, type, link)
  values (v_app.farmer_id,
          case when p_decision = 'accepted'
               then 'You were hired for ' || v_job.title || '.'
               else 'Your application for ' || v_job.title ||
                    ' was not accepted. Reason: ' || trim(p_note)
          end,
          'application', '/farmer/applications');
end $$;

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\fix-schedules.sql' @'
-- ============================================================================
--  FARMS — DUPLICATE PLANTINGS, THEN THE RULE THAT PREVENTS THEM
--
--  Run this AFTER migration-12.sql has completed successfully.
--  Run STEP 1 on its own first and read the result, then run STEP 2.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 — See which plantings look identical.
-- Older rows were created before varieties existed, so several can match.
-- The oldest of each group is kept.
-- ---------------------------------------------------------------------------
select s.id,
       s.crop,
       coalesce(nullif(s.variety, ''), '(no variety)') as variety,
       s.planting_month,
       s.created_at,
       case
         when row_number() over (
                partition by s.farm_id, s.crop, lower(trim(s.variety)), s.planting_month
                order by s.created_at
              ) = 1
         then 'KEEP (oldest)'
         else 'will be closed as a duplicate'
       end as outcome
  from public.schedules s
 where s.status <> 'cancelled'
 order by s.crop, s.planting_month, s.created_at;


-- ---------------------------------------------------------------------------
-- STEP 2 — Close the duplicates and create the rule.
-- Nothing is deleted: the extra rows are marked cancelled, so they drop off
-- the calendar but the history stays in the database.
-- ---------------------------------------------------------------------------
with ranked as (
  select id,
         row_number() over (
           partition by farm_id, crop, lower(trim(variety)), planting_month
           order by created_at
         ) as rn
    from public.schedules
   where status <> 'cancelled'
)
update public.schedules s
   set status = 'cancelled',
       note = coalesce(nullif(s.note, '') || ' | ', '') ||
              'Closed automatically: duplicate of an earlier planting'
  from ranked r
 where r.id = s.id
   and r.rn > 1;

create unique index if not exists schedules_no_duplicates
  on public.schedules (farm_id, crop, lower(trim(variety)), planting_month)
  where status <> 'cancelled';

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\admin-tools.sql' @'
-- ============================================================================
--  FARMS — ADMINISTRATOR TOOLS
--  Pick ONE option below and run only that block.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0 — Find the user id you want to work with.
-- Register the person normally through any login page first, then run this.
-- ---------------------------------------------------------------------------
select u.id as user_id,
       u.email,
       u.phone,
       p.role,
       p.name
  from auth.users u
  left join public.profiles p on p.user_id = u.id
 order by u.created_at desc;


-- ---------------------------------------------------------------------------
-- OPTION A — REPLACE the administrator (still only one).
-- Removes the current admin profile and makes someone else the admin.
-- The old admin keeps any other roles they hold.
-- ---------------------------------------------------------------------------
-- delete from public.profiles where role = 'admin';
--
-- insert into public.profiles (user_id, role, name, phone)
-- values ('PASTE-USER-ID-HERE', 'admin', 'System Administrator', '+639000000001');


-- ---------------------------------------------------------------------------
-- OPTION B — ALLOW MORE THAN ONE administrator.
-- Drops the single-admin rule, then adds the new one. Every admin has full
-- access to users, verifications, products and orders, so only do this for
-- people who genuinely need it.
-- ---------------------------------------------------------------------------
-- drop index if exists public.profiles_single_admin;
--
-- insert into public.profiles (user_id, role, name, phone)
-- values ('PASTE-USER-ID-HERE', 'admin', 'Second Administrator', '+639000000002');


-- ---------------------------------------------------------------------------
-- OPTION C — GO BACK to one administrator after using Option B.
-- Keeps the oldest admin and removes the rest, then restores the rule.
-- ---------------------------------------------------------------------------
-- delete from public.profiles
--  where role = 'admin'
--    and id <> (select id from public.profiles where role = 'admin' order by created_at limit 1);
--
-- create unique index if not exists profiles_single_admin
--   on public.profiles ((role))
--   where role = 'admin';


notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'supabase\fix-admins.sql' @'
-- ============================================================================
--  FARMS — RESOLVE DUPLICATE ADMINISTRATORS
--
--  Run STEP 1 first and read the result. Then run STEP 2.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- STEP 1 — See every administrator account you currently have.
-- The oldest one is the one STEP 2 keeps.
-- ---------------------------------------------------------------------------
select p.id,
       p.name,
       p.phone,
       p.created_at,
       u.email,
       case when p.created_at = min(p.created_at) over () then 'KEEP (oldest)' else 'will be removed' end as outcome
  from public.profiles p
  left join auth.users u on u.id = p.user_id
 where p.role = 'admin'
 order by p.created_at;

'@
$script:count++

Write-ProjectFile 'supabase\fix-admins-step2.sql' @'
-- ============================================================================
--  FARMS — STEP 2: keep one administrator, then apply the constraint.
--
--  This removes the extra admin PROFILES only. The underlying login accounts
--  in auth.users are untouched, so those people can still sign in under their
--  other roles. Only the duplicated admin role is removed.
--
--  Run STEP 1 first if you have not: you may prefer to keep a different one.
-- ============================================================================

delete from public.profiles
 where role = 'admin'
   and id <> (
     select id from public.profiles
      where role = 'admin'
      order by created_at
      limit 1
   );

create unique index if not exists profiles_single_admin
  on public.profiles ((role))
  where role = 'admin';

notify pgrst, 'reload schema';

'@
$script:count++

Write-ProjectFile 'package.json' @'
{
  "name": "farms",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "@supabase/supabase-js": "^2.45.4",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.26.2",
    "sonner": "^1.5.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.11",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.2",
    "autoprefixer": "^10.4.20",
    "postcss": "^8.4.47",
    "postcss-import": "^16.1.1",
    "tailwindcss": "^3.4.13",
    "typescript": "^5.6.2",
    "vite": "^5.4.8"
  }
}

'@
$script:count++

Write-ProjectFile 'index.html' @'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
    <meta name="theme-color" content="#15803d" />
    <title>FARMS — Barangay Pagatban, Bayawan City</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap"
      rel="stylesheet"
    />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>

'@
$script:count++

Write-ProjectFile 'vite.config.ts' @'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { '@': path.resolve(__dirname, './src') } },
})

'@
$script:count++

Write-ProjectFile 'tsconfig.json' @'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": false,
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src"]
}

'@
$script:count++

Write-ProjectFile 'tailwind.config.js' @'
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        mono: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
      },
      colors: {
        // Role theme is driven by CSS custom properties set on <body data-role>.
        brand: {
          50: 'rgb(var(--brand-50) / <alpha-value>)',
          100: 'rgb(var(--brand-100) / <alpha-value>)',
          200: 'rgb(var(--brand-200) / <alpha-value>)',
          500: 'rgb(var(--brand-500) / <alpha-value>)',
          600: 'rgb(var(--brand-600) / <alpha-value>)',
          700: 'rgb(var(--brand-700) / <alpha-value>)',
          900: 'rgb(var(--brand-900) / <alpha-value>)',
        },
        soil: {
          50: '#f6f7f9',
          100: '#eef0f3',
          200: '#e3e6ea',
          400: '#98a1ae',
          600: '#5b6675',
          800: '#2a3038',
          900: '#141922',
        },
      },
      borderRadius: { xl: '0.75rem', '2xl': '1rem' },
      keyframes: {
        'fade-up': { '0%': { opacity: '0', transform: 'translateY(8px)' }, '100%': { opacity: '1', transform: 'none' } },
        'scale-in': { '0%': { opacity: '0', transform: 'scale(.97)' }, '100%': { opacity: '1', transform: 'none' } },
        'slide-in': { '0%': { opacity: '0', transform: 'translateX(-10px)' }, '100%': { opacity: '1', transform: 'none' } },
        shimmer: { '100%': { transform: 'translateX(100%)' } },
        pop: {
          '0%': { transform: 'scale(.8)', opacity: '0' },
          '60%': { transform: 'scale(1.06)' },
          '100%': { transform: 'scale(1)', opacity: '1' },
        },
        'count-up': { '0%': { opacity: '0', transform: 'translateY(4px)' }, '100%': { opacity: '1', transform: 'none' } },
      },
      animation: {
        'fade-up': 'fade-up .32s cubic-bezier(.16,1,.3,1) both',
        'scale-in': 'scale-in .18s cubic-bezier(.16,1,.3,1) both',
        'slide-in': 'slide-in .3s cubic-bezier(.16,1,.3,1) both',
        shimmer: 'shimmer 1.4s infinite',
        pop: 'pop .35s cubic-bezier(.34,1.56,.64,1) both',
        'count-up': 'count-up .4s cubic-bezier(.16,1,.3,1) both',
      },
    },
  },
  plugins: [],
}

'@
$script:count++

Write-ProjectFile 'postcss.config.js' @'
export default {
  plugins: {
    // Must run first so the split stylesheets are inlined before Tailwind.
    'postcss-import': {},
    tailwindcss: {},
    autoprefixer: {},
  },
}

'@
$script:count++

Write-ProjectFile '.env.example' @'
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key

'@
$script:count++

Write-ProjectFile '.gitignore' @'
# Dependencies
node_modules

# Build output
dist
dist-ssr

# Secrets — never commit these. Set them in your host's dashboard instead.
.env
.env.local
.env.*.local

# Editor / OS
.vscode/*
!.vscode/settings.json
.idea
.DS_Store
*.local

# Logs
*.log
npm-debug.log*

'@
$script:count++

Write-ProjectFile 'vercel.json' @'
{
  "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }]
}

'@
$script:count++

Write-ProjectFile 'netlify.toml' @'
[build]
  command = "npm run build"
  publish = "dist"

# FARMS is a single-page app: the browser handles routing, not the server.
# Without this, loading /owner/dashboard directly returns 404 because no such
# file exists on disk. This hands every path to index.html so React Router
# can resolve it.
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200

'@
$script:count++

Write-ProjectFile 'public\_redirects' @'
/*  /index.html  200

'@
$script:count++

Write-ProjectFile 'DEPLOY.md' @'
# Deploying FARMS

Four things your teacher asked for, in order. Budget about an hour, mostly waiting
for DNS.

---

## Step 1 — Push the code to GitHub

Your repository already exists at `github.com/PHILIPMORTE/FARMS-APP`.

```powershell
cd "C:\path\to\FARMS APP"

git add .
git commit -m "Final build for deployment"
git push origin main
```

If this is a fresh folder and git has not been set up yet:

```powershell
git init
git branch -M main
git remote add origin https://github.com/PHILIPMORTE/FARMS-APP.git
git add .
git commit -m "FARMS system"
git push -u origin main
```

**Before you push, confirm `.env` is NOT going up.** It holds your Supabase keys.

```powershell
git check-ignore .env
```

If that prints `.env`, you are safe. If it prints nothing, stop and add `.env`
to `.gitignore` first.

---

## Step 2 — Claim the Name.com domain

1. Go to `education.github.com/pack` and sign in with your GitHub account.
2. Find **Name.com** in the list of offers and click **Get access**.
3. It sends you to Name.com with a coupon applied. Create an account there.
4. Search for a domain and register it. The free offer covers one year on
   selected endings, usually `.com.co`, `.me`, or similar. Pick whatever the
   coupon actually covers.

Suggested names: `farms-pagatban.me`, `farmspagatban.com.co`.

Keep the Name.com login details. Step 3 needs them.

---

## Step 3 — Host the site and point the domain at it

GitHub Pages cannot run this app well because it is a single-page app that also
needs environment variables at build time. Use **Vercel** instead. It is free,
connects straight to your GitHub repo, and rebuilds every time you push.

### 3a. Deploy on Vercel

1. Go to `vercel.com` and sign in **with GitHub**.
2. **Add New → Project**, then import `FARMS-APP`.
3. Vercel detects Vite on its own. Leave the build settings alone:
   - Build command: `npm run build`
   - Output directory: `dist`
4. Open **Environment Variables** and add both of these, copying the values
   from your local `.env`:

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | `https://xxxx.supabase.co` |
   | `VITE_SUPABASE_ANON_KEY` | `eyJhbGci...` |

   Miss this and the site loads but nothing connects.
5. Click **Deploy**. You get a working URL such as `farms-app.vercel.app`.

Test that URL before going any further.

### 3b. Attach your Name.com domain

1. In Vercel: **Project → Settings → Domains → Add**, and enter your domain.
2. Vercel shows you the DNS records it wants. Usually:

   | Type | Host | Value |
   |---|---|---|
   | A | `@` | `76.76.21.21` |
   | CNAME | `www` | `cname.vercel-dns.com` |

   Use the values Vercel actually shows you, not these, in case they change.
3. In Name.com: **My Domains → your domain → DNS Records**. Delete the parking
   records Name.com added, then add the two records from Vercel.
4. Wait. DNS usually takes 10–30 minutes, occasionally a few hours. Vercel
   issues the HTTPS certificate on its own once the records resolve.

---

## Step 4 — Configure the database for the internet

Supabase is already cloud-hosted, so the database is on the internet the moment
you deploy. What it does not yet know is your new address, and sign-in will fail
until you tell it.

### 4a. Supabase redirect URLs

**Authentication → URL Configuration**

- **Site URL**: `https://yourdomain.com`
- **Redirect URLs**: add each of these on its own line

  ```
  https://yourdomain.com/auth/callback
  https://www.yourdomain.com/auth/callback
  https://farms-app.vercel.app/auth/callback
  http://localhost:5173/auth/callback
  ```

Keep the localhost one so you can still develop.

### 4b. Google sign-in

In **Google Cloud Console → Credentials → your OAuth client**:

- **Authorized JavaScript origins**: `https://yourdomain.com`
- **Authorized redirect URIs**: `https://xxxx.supabase.co/auth/v1/callback`

The redirect URI stays pointed at Supabase, not at your domain. That trips
people up.

### 4c. Confirm the migrations are all applied

In the Supabase SQL Editor, run every file in `supabase/` in order, if you have
not already:

```
schema.sql
update-patch.sql
migration-2a.sql
migration-2b.sql
migration-3.sql  ...  migration-20.sql
```

Then check nothing is missing:

```sql
select routine_name
  from information_schema.routines
 where routine_schema = 'public'
 order by routine_name;
```

You should see around 30 functions, including `purchase_product`,
`harvest_schedule`, `add_or_merge_planting` and `farmer_confirm_payment`.

### 4d. Check Row Level Security is on

```sql
select tablename, rowsecurity
  from pg_tables
 where schemaname = 'public'
 order by tablename;
```

Every row should show `rowsecurity = true`. This is what stops one farm reading
another farm's data once the site is public. Do not skip it.

---

## After it is live

Walk through this on the real domain, not localhost:

- [ ] Register a new Farm Owner and get the verification screen
- [ ] Approve them from the admin panel
- [ ] Add a planting, then harvest it
- [ ] List the harvest on the market
- [ ] Buy it from a Buyer account
- [ ] Sign in with Google
- [ ] Open it on a phone

---

## If something breaks

**Blank white page** — environment variables missing in Vercel. Add them and
redeploy.

**404 when refreshing a page like `/owner/market`** — `vercel.json` was not
picked up. It is in the repo root; confirm it was pushed.

**Google sign-in returns to a "redirect not allowed" error** — the callback URL
is not in the Supabase redirect list. Check 4a.

**Site loads but sign-in fails** — check the Supabase URL and anon key in
Vercel, and confirm the Site URL in 4a matches your domain exactly, including
whether you use `www`.

'@
$script:count++

Write-ProjectFile 'src\vite-env.d.ts' @'
interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string
  readonly VITE_SUPABASE_ANON_KEY: string
}
interface ImportMeta {
  readonly env: ImportMetaEnv
}

'@
$script:count++

Write-ProjectFile 'src\main.tsx' @'
import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
)

'@
$script:count++

Write-ProjectFile 'src\App.tsx' @'
import { Navigate, Route, Routes } from 'react-router-dom'
import { Toaster } from 'sonner'
import { AuthProvider } from '@/context/AuthContext'
import { NotificationsProvider } from '@/context/NotificationsContext'
import { AppShell } from '@/components/AppShell'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { ErrorBoundary } from '@/components/ErrorBoundary'

import Landing from '@/pages/Landing'
import LoginPage from '@/pages/auth/LoginPage'
import AuthCallback from '@/pages/auth/AuthCallback'
import AdminLoginPage from '@/pages/auth/AdminLoginPage'
import NotificationsPage from '@/pages/NotificationsPage'

import OwnerDashboard from '@/pages/owner/Dashboard'
import OwnerCalendar from '@/pages/owner/Calendar'
import OwnerMarket from '@/pages/owner/Market'
import OwnerFinance from '@/pages/owner/Finance'
import OwnerJobs from '@/pages/owner/Jobs'
import OwnerAccount from '@/pages/owner/Account'

import FarmerJobs from '@/pages/farmer/Jobs'
import FarmerApplications from '@/pages/farmer/Applications'
import FarmerAccount from '@/pages/farmer/Account'
import FarmerLogs from '@/pages/farmer/Logs'
import FarmerHistory from '@/pages/farmer/History'

import OwnerOrders from '@/pages/owner/Orders'
import OwnerAttendance from '@/pages/owner/Attendance'
import { VerificationGate } from '@/components/VerificationGate'
import { PrivacyGate } from '@/components/PrivacyGate'
import { AdminDashboard, AdminVerifications } from '@/pages/admin/Dashboard'
import { AdminUsers, AdminCatalog, AdminOrders } from '@/pages/admin/Manage'
import { AdminRequests, RequestAdminAccess } from '@/pages/admin/Requests'

import BuyerMarket from '@/pages/buyer/Market'
import BuyerOrders from '@/pages/buyer/Orders'
import BuyerAccount from '@/pages/buyer/Account'

export default function App() {
  return (
    <ErrorBoundary>
    <AuthProvider>
      <NotificationsProvider>
      <Routes>
        <Route path="/" element={<Landing />} />

        <Route path="/owner/login" element={<LoginPage role="owner" />} />
        <Route path="/farmer/login" element={<LoginPage role="farmer" />} />
        <Route path="/buyer/login" element={<LoginPage role="buyer" />} />
        <Route path="/admin/login" element={<AdminLoginPage />} />
        <Route path="/admin/request" element={<RequestAdminAccess />} />
        <Route path="/auth/callback" element={<AuthCallback />} />

        <Route
          path="/owner"
          element={
            <ProtectedRoute role="owner">
              <PrivacyGate>
                <VerificationGate role="owner">
                  <AppShell role="owner" />
                </VerificationGate>
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/owner/dashboard" replace />} />
          <Route path="dashboard" element={<OwnerDashboard />} />
          <Route path="calendar" element={<OwnerCalendar />} />
          <Route path="market" element={<OwnerMarket />} />
          <Route path="finance" element={<OwnerFinance />} />
          <Route path="jobs" element={<OwnerJobs />} />
          <Route path="attendance" element={<OwnerAttendance />} />
          <Route path="orders" element={<OwnerOrders />} />
          <Route path="account" element={<OwnerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route
          path="/farmer"
          element={
            <ProtectedRoute role="farmer">
              <PrivacyGate>
                <VerificationGate role="farmer">
                  <AppShell role="farmer" />
                </VerificationGate>
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/farmer/jobs" replace />} />
          <Route path="jobs" element={<FarmerJobs />} />
          <Route path="applications" element={<FarmerApplications />} />
          <Route path="logs" element={<FarmerLogs />} />
          <Route path="history" element={<FarmerHistory />} />
          <Route path="account" element={<FarmerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route
          path="/buyer"
          element={
            <ProtectedRoute role="buyer">
              <PrivacyGate>
                <VerificationGate role="buyer">
                  <AppShell role="buyer" />
                </VerificationGate>
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/buyer/market" replace />} />
          <Route path="market" element={<BuyerMarket />} />
          <Route path="orders" element={<BuyerOrders />} />
          <Route path="account" element={<BuyerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route
          path="/admin"
          element={
            <ProtectedRoute role="admin">
              <PrivacyGate>
                <AppShell role="admin" />
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/admin/dashboard" replace />} />
          <Route path="dashboard" element={<AdminDashboard />} />
          <Route path="verifications" element={<AdminVerifications />} />
          <Route path="users" element={<AdminUsers />} />
          <Route path="requests" element={<AdminRequests />} />
          <Route path="catalog" element={<AdminCatalog />} />
          <Route path="orders" element={<AdminOrders />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>

      <Toaster position="top-center" richColors closeButton />
      </NotificationsProvider>
    </AuthProvider>
    </ErrorBoundary>
  )
}

'@
$script:count++

Write-ProjectFile 'src\index.css' @'
@import './styles/theme.css';
@import './styles/components.css';

@tailwind base;
@tailwind components;
@tailwind utilities;

'@
$script:count++

Write-ProjectFile 'src\styles\theme.css' @'
@layer base {
  :root {

    --brand-50: 240 253 244;
    --brand-100: 220 252 231;
    --brand-200: 187 247 208;
    --brand-500: 34 197 94;
    --brand-600: 22 163 74;
    --brand-700: 21 128 61;
    --brand-900: 20 83 45;

    --brand-wash: 222 247 230;
  }

  [data-role='owner'] {
    --brand-50: 240 253 244;
    --brand-100: 220 252 231;
    --brand-200: 187 247 208;
    --brand-500: 34 197 94;
    --brand-600: 22 163 74;
    --brand-700: 21 128 61;
    --brand-900: 20 83 45;
    --brand-wash: 222 247 230;
  }

  [data-role='farmer'] {
    --brand-50: 255 251 235;
    --brand-100: 254 243 199;
    --brand-200: 253 230 138;
    --brand-500: 245 158 11;
    --brand-600: 217 119 6;
    --brand-700: 180 83 9;
    --brand-900: 120 53 15;
    --brand-wash: 254 243 214;
  }

  [data-role='admin'] {
    --brand-50: 248 250 252;
    --brand-100: 241 245 249;
    --brand-200: 226 232 240;
    --brand-500: 100 116 139;
    --brand-600: 51 65 85;
    --brand-700: 30 41 59;
    --brand-900: 15 23 42;
    --brand-wash: 226 232 240;
  }

  [data-role='buyer'] {
    --brand-50: 239 246 255;
    --brand-100: 219 234 254;
    --brand-200: 191 219 254;
    --brand-500: 59 130 246;
    --brand-600: 37 99 235;
    --brand-700: 29 78 216;
    --brand-900: 30 58 138;
    --brand-wash: 219 234 254;
  }

  html {
    -webkit-text-size-adjust: 100%;
  }

  body {
    @apply bg-soil-50 text-soil-900 font-sans antialiased;
  }

  h1, h2, h3 {
    @apply font-semibold tracking-[-0.01em];
  }

  .num {
    @apply tabular-nums;
  }

  :focus-visible {
    @apply outline-none ring-2 ring-brand-600 ring-offset-2 rounded-lg;
  }

  input[type='number']::-webkit-outer-spin-button,
  input[type='number']::-webkit-inner-spin-button {
    -webkit-appearance: none;
    margin: 0;
  }
  input[type='number'] {
    -moz-appearance: textfield;
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: 0.01ms !important;
      transition-duration: 0.01ms !important;
    }
  }
}

'@
$script:count++

Write-ProjectFile 'src\styles\components.css' @'
@layer components {

  .card {
    @apply bg-white rounded-xl border border-soil-200/80 shadow-[0_1px_3px_rgba(16,24,40,.06)];
  }

  .app-bar {
    @apply bg-brand-600 text-white;
  }

  .hero-photo {
    background-color: rgb(var(--brand-700));
    background-image: linear-gradient(160deg, rgb(var(--brand-700)), rgb(var(--brand-900)));
  }

  .hero-photo-img {
    background-image: url('/farm-background.jpg');
    background-size: cover;
    background-position: center;
  }

  .hero-scrim {
    background:
      linear-gradient(105deg, rgba(6, 20, 12, 0.86) 0%, rgba(6, 20, 12, 0.55) 45%, rgba(6, 20, 12, 0.35) 100%),
      linear-gradient(180deg, rgba(6, 20, 12, 0.5) 0%, transparent 30%, rgba(6, 20, 12, 0.55) 100%);
  }

  .label {
    @apply block text-[13px] font-medium text-soil-800 mb-1.5;
  }

  .field {
    @apply w-full rounded-lg border border-soil-200 bg-white px-3.5 py-2.5 text-[15px]
           placeholder:text-soil-400 transition
           focus:border-brand-600 focus:ring-2 focus:ring-brand-600/15 focus:outline-none
           disabled:bg-soil-100 disabled:text-soil-400;
  }

  .field-soft {
    @apply w-full rounded-lg border border-transparent bg-soil-100 px-4 py-3 text-[15px]
           placeholder:text-soil-400 transition
           focus:border-brand-600 focus:bg-white focus:ring-2 focus:ring-brand-600/15 focus:outline-none;
  }

  .field-error {
    @apply border-red-400 focus:border-red-500 focus:ring-red-500/15;
  }

  .err {
    @apply mt-1.5 text-[13px] font-medium text-red-600;
  }

  .btn {
    @apply inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-[15px]
           font-semibold transition active:scale-[.99]
           disabled:opacity-50 disabled:pointer-events-none;
  }

  .btn-primary {
    @apply btn bg-brand-600 text-white hover:bg-brand-700;
  }

  .btn-ghost {
    @apply btn bg-white border border-soil-200 text-soil-800 hover:bg-soil-100;
  }

  .btn-danger {
    @apply btn bg-red-500 text-white hover:bg-red-600;
  }

  .btn-sm {
    @apply inline-flex items-center justify-center gap-1.5 rounded-lg px-3 py-1.5
           text-[13px] font-semibold transition active:scale-[.99]
           disabled:opacity-50 disabled:pointer-events-none;
  }

  .chip {
    @apply inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-[11px] font-semibold;
  }

  .auth-wash {
    position: relative;
    background-color: #14200f;
    background-image: url('/farm-background.jpg');
    background-size: cover;
    background-position: center;
  }

  .auth-wash::before {
    content: '';
    position: absolute;
    inset: 0;
    pointer-events: none;
    background:
      linear-gradient(105deg, rgba(6, 20, 12, 0.82) 0%, rgba(6, 20, 12, 0.5) 45%, rgba(6, 20, 12, 0.35) 100%),
      linear-gradient(180deg, rgba(6, 20, 12, 0.5) 0%, transparent 30%, rgba(6, 20, 12, 0.55) 100%);
  }

  .auth-card {
    background-image: linear-gradient(
      170deg,
      rgb(var(--brand-100) / 0.9) 0%,
      #ffffff 42%,
      #ffffff 100%
    );
    box-shadow:
      0 24px 60px -18px rgba(4, 14, 8, 0.65),
      0 0 0 1px rgba(255, 255, 255, 0.5) inset;
  }

  .field-icon {
    @apply w-full rounded-xl border border-transparent bg-soil-100/80 py-3.5 pl-11 pr-4 text-[15px]
           text-soil-900 placeholder:text-soil-400 transition
           focus:border-brand-600/40 focus:bg-white focus:outline-none focus:ring-4 focus:ring-brand-600/10;
  }

  .btn-dark {
    @apply btn w-full rounded-xl bg-soil-900 py-3.5 text-white
           shadow-[0_4px_14px_-4px_rgba(20,25,34,.5)] hover:bg-soil-800;
  }

  .dotted-rule {
    background-image: radial-gradient(circle, rgb(var(--brand-200)) 1.2px, transparent 1.2px);
    background-size: 7px 1px;
    background-repeat: repeat-x;
    background-position: center;
  }
}

@layer components {
  .admin-login {
    background-color: #10151b;
    background-image:
      linear-gradient(105deg, rgba(10, 14, 20, 0.94) 0%, rgba(10, 14, 20, 0.86) 50%, rgba(10, 14, 20, 0.9) 100%),
      url('/farm-background.jpg');
    background-size: cover;
    background-position: center;
  }

  .admin-card {
    background: #22262d;
    box-shadow:
      0 24px 60px -18px rgba(0, 0, 0, 0.7),
      0 0 0 1px rgba(255, 255, 255, 0.06) inset;
  }
}

@layer utilities {
  .scrollbar-none {
    scrollbar-width: none;
    -ms-overflow-style: none;
  }
  .scrollbar-none::-webkit-scrollbar {
    display: none;
  }
}

@layer components {
  .stagger > * {
    animation: fade-up 0.35s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .stagger > *:nth-child(1) { animation-delay: 0ms; }
  .stagger > *:nth-child(2) { animation-delay: 45ms; }
  .stagger > *:nth-child(3) { animation-delay: 90ms; }
  .stagger > *:nth-child(4) { animation-delay: 135ms; }
  .stagger > *:nth-child(5) { animation-delay: 180ms; }
  .stagger > *:nth-child(6) { animation-delay: 225ms; }
}

@layer components {
  .dialog-panel {
    max-height: 90vh;
  }

  @supports (height: 100dvh) {
    .dialog-panel {
      max-height: 90dvh;
    }
  }

  @media (min-width: 640px) {
    .dialog-panel {
      max-height: 85vh;
    }

    @supports (height: 100dvh) {
      .dialog-panel {
        max-height: 85dvh;
      }
    }
  }
}

'@
$script:count++

Write-ProjectFile 'src\lib\supabase.ts' @'
import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string

if (!url || !anonKey) {
  throw new Error(
    'Supabase is not configured. Copy .env.example to .env and add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.',
  )
}

export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})

'@
$script:count++

Write-ProjectFile 'src\lib\types.ts' @'
export type Role = 'owner' | 'farmer' | 'buyer' | 'admin'
export type Crop = 'rice' | 'corn' | 'watermelon'
export type JobCrop = Crop | 'general'
export type JobType = 'seasonal' | 'part-time' | 'full-time'
export type JobStatus = 'open' | 'closed' | 'filled'
export type AppStatus = 'pending' | 'accepted' | 'rejected'
export type Availability = 'available' | 'busy' | 'unavailable'
export type ProductStatus = 'available' | 'reserved' | 'sold'
export type OrderStatus = 'completed' | 'pending' | 'cancelled'
export type OrderStage =
  | 'placed' | 'confirmed' | 'preparing' | 'ready'
  | 'shipped' | 'delivered' | 'completed' | 'cancelled'
export type VerificationStatus = 'pending' | 'approved' | 'rejected'
export type AttendanceStatus = 'present' | 'absent' | 'half_day' | 'leave'
export type TxnType = 'income' | 'expense'
export type NotifType =
  | 'harvest' | 'sale' | 'purchase' | 'job_post'
  | 'application' | 'hired' | 'rejected' | 'general'
  | 'verification' | 'order_status' | 'stock'

export interface Profile {
  id: string
  user_id: string
  role: Role
  name: string
  phone: string
  email: string | null
  avatar_url: string | null
  privacy_accepted_at: string | null
  rating_warnings: number
  restricted: boolean
  company: string | null
  address: string | null
  city: string | null
  province: string | null
  zip_code: string | null
  created_at: string
}

export interface Farm {
  id: string
  owner_id: string
  name: string
  standard_hours?: number
  latitude?: number | null
  longitude?: number | null
  address: string | null
  city: string | null
  province: string | null
  zip_code: string | null
  created_at: string
}

export interface FarmerProfile {
  id: string
  bio: string | null
  skills: string[] | null
  experience_years: number | null
  availability: Availability
  province: string | null
  city: string | null
  created_at: string
}

export interface JobPost {
  id: string
  farm_id: string
  owner_id: string
  title: string
  description: string
  crop: JobCrop
  type: JobType
  wage: number
  start_time: string
  end_time: string
  slots: number
  filled_slots: number
  location: string
  start_date: string
  end_date: string | null
  status: JobStatus
  created_at: string
  farms?: { name: string; city: string | null; province: string | null } | null
}

export interface JobApplication {
  id: string
  job_id: string
  farmer_id: string
  status: AppStatus
  message: string | null
  employment_status: string
  ended_at: string | null
  end_reason: string | null
  applied_at: string
  updated_at: string
  job_posts?: JobPost | null
  profiles?: Profile | null
  farmer_profiles?: FarmerProfile | null
}

export type ScheduleStatus = 'planned' | 'planted' | 'growing' | 'harvested' | 'cancelled'

export interface Schedule {
  id: string
  farm_id: string
  crop: Crop
  variety: string
  planting_month: string
  planting_date: string | null
  harvest_date: string | null
  estimated_months: number
  seed_kg: number
  area_ha: number | null
  field_name: string | null
  expected_sacks: number
  actual_sacks: number | null
  harvested_at: string | null
  status: ScheduleStatus
  note: string | null
  listed_product_id: string | null
  created_at: string
}

export interface CropProfit {
  schedule_id: string
  crop: Crop
  variety: string
  status: ScheduleStatus
  planting_date: string | null
  harvest_date: string | null
  expected_sacks: number
  actual_sacks: number | null
  expenses: number
  income: number
  estimated_value: number
}

export interface InventoryItem {
  id: string
  farm_id: string
  crop: Crop
  quantity: number
  added_at: string
}

export interface Product {
  id: string
  farm_id: string
  variety: string
  crop: Crop
  photo_url: string | null
  quantity: number
  reserved: number
  form: 'unmilled' | 'milled'
  price: number
  status: ProductStatus
  buyer_id: string | null
  created_at: string
  farms?: { name: string; city: string | null; province: string | null } | null
}

export interface Transaction {
  id: string
  farm_id: string
  type: TxnType
  category: string
  amount: number
  description: string
  date: string
  schedule_id: string | null
  crop: Crop | null
  created_at: string
}

export interface Order {
  id: string
  buyer_id: string
  product_id: string
  quantity: number
  total_price: number
  status: OrderStatus
  stage: OrderStage
  paid: boolean
  paid_at: string | null
  cancel_reason: string | null
  updated_at: string
  created_at: string
  products?: Product | null
  profiles?: Profile | null
}

export interface OrderEvent {
  id: string
  order_id: string
  stage: OrderStage
  note: string | null
  changed_by: string | null
  created_at: string
}

export interface OwnerVerification {
  id: string
  profile_id: string
  role: Role
  status: VerificationStatus
  full_name: string
  id_type: string
  id_number: string | null
  id_photo_path: string | null
  selfie_path: string | null
  latitude: number | null
  longitude: number | null
  farm_name: string
  farm_address: string
  barangay: string
  farm_size_ha: number | null
  document_url: string | null
  notes: string | null
  review_notes: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  submitted_at: string
  profiles?: Profile | null
}

export interface AttendanceRow {
  id: string
  farm_id: string
  job_id: string | null
  farmer_id: string
  work_date: string
  status: AttendanceStatus
  hours_worked: number
  daily_wage: number
  computed_pay: number
  note: string | null
  task: string
  schedule_id: string | null
  paid: boolean
  paid_at: string | null
  paid_by: string | null
  payment_status: 'unpaid' | 'pending' | 'paid'
  payment_sent_at: string | null
  payment_confirmed_at: string | null
  time_in: string | null
  time_out: string | null
  break_minutes: number
  break_started_at: string | null
  source: string
  recorded_by: string | null
  created_at: string
  profiles?: Profile | null
  job_posts?: { title: string } | null
}

export interface StockChange {
  id: string
  product_id: string | null
  farm_id: string
  changed_by: string | null
  old_quantity: number
  new_quantity: number
  reason: string
  source: string
  created_at: string
  products?: { variety: string } | null
  profiles?: Profile | null
}

export interface Notification {
  id: string
  user_id: string
  message: string
  type: NotifType
  link: string
  unread: boolean
  created_at: string
}

'@
$script:count++

Write-ProjectFile 'src\lib\format.ts' @'
import type { AttendanceStatus, Crop, JobCrop, OrderStage, OrderStatus, Role } from './types'

export const KG_PER_SACK = 25

export const CROP_EMOJI: Record<JobCrop, string> = {
  rice: '🌾',
  corn: '🌽',
  watermelon: '🍉',
  general: '🧑‍🌾',
}

export const CROPS: Crop[] = ['rice', 'corn', 'watermelon']

export const VARIETIES: Record<Crop, string[]> = {
  rice: [
    'Dinorado',
    'Sinandomeng',
    'Jasmine',
    'Milagrosa',
    'IR64',
    'NSIC Rc222 (Tubigan 18)',
    'NSIC Rc160',
    'Angelica',
    'Black Rice',
    'Red Rice',
    'Malagkit (Glutinous)',
  ],
  corn: [
    'Sweet Corn',
    'White Corn',
    'Yellow Corn',
    'Glutinous Corn (Pilit)',
    'IPB Var 6',
    'Bt Corn',
    'Popcorn',
  ],
  watermelon: [
    'Sweet Beauty',
    'Crimson Sweet',
    'Sugar Baby',
    'Jubilee',
    'Yellow Doll',
    'Seedless Watermelon',
    'Black Beauty',
  ],
}

export const CROP_DURATION: Record<Crop, number> = { rice: 4, corn: 3, watermelon: 3 }

export const CROP_COLOR: Record<Crop, {
  dot: string
  chip: string
  soft: string
  bar: string
  ring: string
  text: string
}> = {
  rice: {
    dot: 'bg-emerald-600',
    chip: 'bg-emerald-100 text-emerald-800',
    soft: 'bg-emerald-50',
    bar: 'bg-emerald-600',
    ring: 'ring-emerald-600',
    text: 'text-emerald-700',
  },
  corn: {
    dot: 'bg-yellow-400',
    chip: 'bg-yellow-100 text-yellow-800',
    soft: 'bg-yellow-50',
    bar: 'bg-yellow-400',
    ring: 'ring-yellow-400',
    text: 'text-yellow-700',
  },
  watermelon: {
    dot: 'bg-red-700',
    chip: 'bg-red-100 text-red-800',
    soft: 'bg-red-50',
    bar: 'bg-red-700',
    ring: 'ring-red-700',
    text: 'text-red-700',
  },
}

export const SCHEDULE_LABEL: Record<string, string> = {
  planned: 'Planned',
  planted: 'Planted',
  growing: 'Growing',
  harvested: 'Harvested',
  cancelled: 'Cancelled',
}

export const SEASON: Record<Crop, number[]> = {
  rice: [4, 5, 6, 7, 10, 11, 0, 1],
  corn: [3, 4, 5, 10, 11, 0],
  watermelon: [11, 0, 1, 2, 3, 4],
}

export function suggestedCrops(monthIndex: number): Crop[] {
  return CROPS.filter((c) => SEASON[c].includes(monthIndex))
}

export function todayISO(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`
}

export function toISODate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`
}

export function daysBetween(a: string, b: string): number {
  return Math.max(0, Math.round((+new Date(b) - +new Date(a)) / 86400000))
}

export function addDays(iso: string, days: number): string {
  const d = new Date(iso)
  d.setDate(d.getDate() + days)
  return toISODate(d)
}

export const ROLE_HOME: Record<Role, string> = {
  owner: '/owner/dashboard',
  farmer: '/farmer/jobs',
  buyer: '/buyer/market',
  admin: '/admin/dashboard',
}

export const ROLE_LABEL: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
  admin: 'Administrator',
}

export const ORDER_STAGES: { stage: OrderStage; label: string; hint: string }[] = [
  { stage: 'confirmed', label: 'Order Confirmed', hint: 'The farm accepted your order' },
  { stage: 'shipped', label: 'Out for Delivery', hint: 'On the way to you' },
  { stage: 'completed', label: 'Completed', hint: 'Order finished' },
]

export const STAGE_LABEL: Record<OrderStage, string> = {
  placed: 'Order Placed',
  confirmed: 'Order Confirmed',
  preparing: 'Out for Delivery',
  ready: 'Out for Delivery',
  shipped: 'Out for Delivery',
  delivered: 'Out for Delivery',
  completed: 'Completed',
  cancelled: 'Cancelled',
}

export function simplifyStage(stage: OrderStage): OrderStage {
  if (stage === 'preparing' || stage === 'ready' || stage === 'delivered') return 'shipped'
  return stage
}

export function stageIndex(stage: OrderStage): number {
  return ORDER_STAGES.findIndex((s) => s.stage === simplifyStage(stage))
}

export function isFinishedOrder(order: { stage?: OrderStage; status?: OrderStatus }): boolean {
  if (order.stage === 'completed' || order.stage === 'cancelled') return true
  return order.status === 'completed' || order.status === 'cancelled'
}

export function effectiveStage(order: { stage?: OrderStage; status?: OrderStatus }): OrderStage {
  if (order.stage && order.stage !== 'placed') return simplifyStage(order.stage)
  if (order.status === 'completed') return 'completed'
  if (order.status === 'cancelled') return 'cancelled'
  return order.stage ?? 'placed'
}

export const ATTENDANCE_LABEL: Record<AttendanceStatus, string> = {
  present: 'Present',
  absent: 'Absent',
  half_day: 'Half day',
  leave: 'On leave',
}

export function hours(value: number | string | null | undefined): string {
  const n = Number(value ?? 0)
  if (!Number.isFinite(n)) return '0'
  return n % 1 === 0 ? String(n) : n.toFixed(2).replace(/0$/, '')
}

export function availableSacks(p: { quantity: number; reserved?: number }): number {
  return Math.max(Math.floor(p.quantity) - Math.floor(p.reserved ?? 0), 0)
}

export function toSacks(value: unknown): number {
  const n = typeof value === 'number' ? value : parseInt(String(value ?? ''), 10)
  if (!Number.isFinite(n)) return 0
  return Math.floor(n)
}

export function sacks(value: unknown): string {
  return toSacks(value).toLocaleString('en-PH', { maximumFractionDigits: 0 })
}

export function sacksLabel(value: unknown): string {
  const n = toSacks(value)
  return `${sacks(n)} ${n === 1 ? 'sack' : 'sacks'}`
}

export function weightNote(value: unknown): string {
  const n = toSacks(value)
  return `${sacks(n)} ${n === 1 ? 'sack' : 'sacks'} = ${(n * KG_PER_SACK).toLocaleString('en-PH')} kg`
}

export function peso(value: number | string | null | undefined): string {
  const n = Number(value ?? 0)
  return `₱${(Number.isFinite(n) ? n : 0).toLocaleString('en-PH', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`
}

export function pesoShort(value: number | null | undefined): string {
  const n = Number(value ?? 0)
  if (Math.abs(n) >= 1_000_000) return `₱${(n / 1_000_000).toFixed(1)}M`
  if (Math.abs(n) >= 10_000) return `₱${(n / 1000).toFixed(1)}K`
  return peso(n)
}

export function shortDate(value: string | null | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleDateString('en-PH', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
}

export function relativeDate(value: string): string {
  const diff = Date.now() - new Date(value).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'Just now'
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `${hrs}h ago`
  const days = Math.floor(hrs / 24)
  if (days < 7) return `${days}d ago`
  return shortDate(value)
}

export function monthLabel(ym: string): string {
  const [y, m] = ym.split('-').map(Number)
  if (!y || !m) return ym
  return new Date(y, m - 1, 1).toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })
}

export function addMonths(ym: string, months: number): string {
  const [y, m] = ym.split('-').map(Number)
  const d = new Date(y, m - 1 + months, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

export function initials(name: string): string {
  return (
    name
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((w) => w[0]?.toUpperCase() ?? '')
      .join('') || '?'
  )
}

export function titleCase(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}

'@
$script:count++

Write-ProjectFile 'src\lib\validation.ts' @'
const PH_LOCAL = /^09\d{9}$/
const PH_E164 = /^\+639\d{9}$/

export function normalisePhone(input: string): string | null {
  const raw = input.replace(/[\s()-]/g, '')
  if (PH_E164.test(raw)) return raw
  if (PH_LOCAL.test(raw)) return `+63${raw.slice(1)}`
  if (/^639\d{9}$/.test(raw)) return `+${raw}`
  if (/^9\d{9}$/.test(raw)) return `+63${raw}`
  return null
}

export function displayPhone(e164: string | null | undefined): string {
  if (!e164) return '—'
  const local = e164.startsWith('+63') ? `0${e164.slice(3)}` : e164
  return local.replace(/^(\d{4})(\d{3})(\d{4})$/, '$1 $2 $3')
}

export function validatePhone(input: string): string | null {
  if (!input.trim()) return 'Enter your mobile number.'
  if (!normalisePhone(input))
    return 'Use a Philippine mobile number, like 09171234567 or +639171234567.'
  return null
}

export function validatePassword(input: string): string | null {
  if (!input) return 'Enter a password.'
  if (input.length < 8) return 'Use at least 8 characters.'
  return null
}

export function validateName(input: string): string | null {
  if (!input.trim()) return 'Enter your full name.'
  if (input.trim().length < 2) return 'Enter your full name.'
  return null
}

export function validateSacks(raw: string | number, opts: { min?: number; max?: number } = {}): string | null {
  const { min = 1, max } = opts
  const s = String(raw).trim()
  if (!s) return 'Enter a number of sacks.'
  if (!/^\d+$/.test(s)) return 'Sacks must be a whole number — no decimals.'
  const n = parseInt(s, 10)
  if (n < min) return `Enter at least ${min} sack${min === 1 ? '' : 's'}.`
  if (max !== undefined && n > max) return `Only ${max} sack${max === 1 ? '' : 's'} available.`
  return null
}

export function validateWholeNumber(raw: string | number, min = 0, label = 'value'): string | null {
  const s = String(raw).trim()
  if (!s) return `Enter a ${label}.`
  if (!/^\d+$/.test(s)) return `The ${label} must be a whole number.`
  if (parseInt(s, 10) < min) return `Enter at least ${min}.`
  return null
}

export function validateAmount(raw: string | number, label = 'amount'): string | null {
  const n = Number(raw)
  if (String(raw).trim() === '') return `Enter an ${label}.`
  if (!Number.isFinite(n) || n < 0) return `Enter a valid ${label}.`
  return null
}

export function validateRequired(input: string, label: string): string | null {
  return input.trim() ? null : `${label} is required.`
}

export function friendlyError(error: unknown): string {
  const msg = (error as { message?: string })?.message ?? String(error)
  if (/duplicate key.*profiles_phone_role_key/i.test(msg))
    return 'That number is already registered for this role.'
  if (/duplicate key.*job_applications/i.test(msg))
    return 'You have already applied to this job.'
  if (/Invalid login credentials/i.test(msg))
    return 'That number and password do not match an account.'
  if (/User already registered/i.test(msg))
    return 'That number already has an account. Sign in instead.'
  if (/Password should be/i.test(msg)) return 'Use at least 8 characters.'
  return msg || 'Something went wrong. Try again.'
}

'@
$script:count++

Write-ProjectFile 'src\context\AuthContext.tsx' @'
import { createContext, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import type { Farm, Profile, Role } from '@/lib/types'
import { normalisePhone } from '@/lib/validation'

interface AuthState {
  session: Session | null

  profile: Profile | null

  farm: Farm | null
  loading: boolean
  signInWithPhone(role: Role, phone: string, password: string): Promise<void>
  registerWithPhone(role: Role, name: string, phone: string, password: string): Promise<void>
  signInWithGoogle(role: Role): Promise<void>
  completeGoogleProfile(role: Role, name: string, phone: string): Promise<void>
  sendPasswordReset(phone: string): Promise<void>
  refresh(): Promise<void>
  signOut(): Promise<void>
}

const Ctx = createContext<AuthState | null>(null)

const ROLE_KEY = 'farms.active-role'
export const getActiveRole = (): Role | null =>
  (sessionStorage.getItem(ROLE_KEY) as Role | null) ?? null
export const setActiveRole = (r: Role | null) =>
  r ? sessionStorage.setItem(ROLE_KEY, r) : sessionStorage.removeItem(ROLE_KEY)

class AuthError extends Error {}

async function phoneTaken(phone: string, role: Role): Promise<boolean> {
  const { data, error } = await supabase.rpc('phone_role_taken', {
    p_phone: phone,
    p_role: role,
  })

  if (error) return false
  return data === true
}

function aliasEmail(phoneE164: string): string {
  return `p${phoneE164.replace(/\D/g, '')}@phone.farms.ph`
}

function hasSession(res: { data?: { session?: unknown } | null }): boolean {
  return !!res?.data?.session
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [farm, setFarm] = useState<Farm | null>(null)
  const [loading, setLoading] = useState(true)
  const mounted = useRef(true)

  async function loadProfile(userId: string, role: Role | null) {
    if (!role) {
      setProfile(null)
      setFarm(null)
      return
    }
    const { data: prof } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', userId)
      .eq('role', role)
      .maybeSingle()

    if (!mounted.current) return
    setProfile((prof as Profile) ?? null)

    if (prof && role === 'owner') {
      let { data: f } = await supabase
        .from('farms')
        .select('*')
        .eq('owner_id', (prof as Profile).id)
        .maybeSingle()

      if (!f) {
        const { data: created } = await supabase
          .from('farms')
          .insert({ owner_id: (prof as Profile).id, name: `${(prof as Profile).name}'s Farm` })
          .select()
          .single()
        f = created
      }
      if (mounted.current) setFarm((f as Farm) ?? null)
    } else {
      setFarm(null)
    }
  }

  useEffect(() => {
    mounted.current = true

    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session)
      if (data.session) await loadProfile(data.session.user.id, getActiveRole())
      if (mounted.current) setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange(async (_event, s) => {
      setSession(s)
      if (s) await loadProfile(s.user.id, getActiveRole())
      else {
        setProfile(null)
        setFarm(null)
      }
    })

    return () => {
      mounted.current = false
      sub.subscription.unsubscribe()
    }
  }, [])

  async function refresh() {
    const { data } = await supabase.auth.getSession()
    if (data.session) await loadProfile(data.session.user.id, getActiveRole())
  }

  async function signInWithPhone(role: Role, phoneInput: string, password: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')

    let data = null as Awaited<ReturnType<typeof supabase.auth.signInWithPassword>>['data'] | null

    const byPhone = await supabase.auth.signInWithPassword({ phone, password })
    if (hasSession(byPhone)) {
      data = byPhone.data
    } else {
      const byAlias = await supabase.auth.signInWithPassword({
        email: aliasEmail(phone),
        password,
      })
      if (hasSession(byAlias)) data = byAlias.data
    }

    if (!data?.user || !data.session) {
      throw new AuthError('That number and password do not match an account.')
    }

    const { data: prof } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', data.user.id)
      .eq('role', role)
      .maybeSingle()

    if (!prof) {
      await supabase.auth.signOut()
      throw new AuthError(
        `That number has no ${ROLE_WORD[role]} account yet. Open the Create account tab to add one.`,
      )
    }

    setActiveRole(role)
    setSession(data.session)
    await loadProfile(data.user.id, role)
  }

  async function registerWithPhone(role: Role, name: string, phoneInput: string, password: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')

    if (await phoneTaken(phone, role)) {
      throw new AuthError(
        `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
      )
    }

    let userId: string | null = null

    const existingPhone = await supabase.auth.signInWithPassword({ phone, password })
    if (hasSession(existingPhone)) {
      userId = existingPhone.data.user!.id
      setSession(existingPhone.data.session)
    } else {
      const existingAlias = await supabase.auth.signInWithPassword({
        email: aliasEmail(phone),
        password,
      })
      if (hasSession(existingAlias)) {
        userId = existingAlias.data.user!.id
        setSession(existingAlias.data.session)
      }
    }

    if (!userId) {
      const viaPhone = await supabase.auth.signUp({
        phone,
        password,
        options: { data: { name } },
      })

      if (hasSession(viaPhone)) {
        userId = viaPhone.data.user!.id
        setSession(viaPhone.data.session)
      } else {
        const viaAlias = await supabase.auth.signUp({
          email: aliasEmail(phone),
          password,
          options: { data: { name, phone } },
        })

        if (hasSession(viaAlias)) {
          userId = viaAlias.data.user!.id
          setSession(viaAlias.data.session)
        } else if (viaAlias.error && /already registered|already been/i.test(viaAlias.error.message)) {
          throw new AuthError(
            'This number already has an account. Enter that account’s password to add this role to it.',
          )
        } else if (viaAlias.data?.user && !viaAlias.data.session) {
          throw new AuthError(
            'Account created but not signed in. In Supabase go to Authentication → Providers → Email and turn OFF “Confirm email”, then sign in.',
          )
        } else {
          throw new AuthError(viaAlias.error?.message ?? viaPhone.error?.message ?? 'Could not create the account.')
        }
      }
    }

    await createProfile(userId!, role, name, phone, null)
    setActiveRole(role)
    await loadProfile(userId!, role)
  }

  async function signInWithGoogle(role: Role) {
    setActiveRole(role)
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback?role=${role}`,
        queryParams: {
          prompt: 'select_account',
        },
      },
    })
    if (error) throw new AuthError(error.message)
  }

  async function completeGoogleProfile(role: Role, name: string, phoneInput: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')
    const { data: s } = await supabase.auth.getSession()
    if (!s.session) throw new AuthError('Your sign-in expired. Try again.')

    if (await phoneTaken(phone, role)) {
      throw new AuthError(
        `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
      )
    }

    await createProfile(s.session.user.id, role, name, phone, s.session.user.email ?? null)
    setActiveRole(role)
    await loadProfile(s.session.user.id, role)
  }

  async function createProfile(
    userId: string,
    role: Role,
    name: string,
    phone: string,
    email: string | null,
  ) {
    const { data, error } = await supabase
      .from('profiles')
      .insert({ user_id: userId, role, name, phone, email })
      .select()
      .single()

    if (error) {
      if (/profiles_phone_role_key/.test(error.message)) {
        throw new AuthError(
          `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
        )
      }
      throw new AuthError(error.message)
    }

    const p = data as Profile
    if (role === 'owner') {
      await supabase.from('farms').insert({ owner_id: p.id, name: `${name}'s Farm` })
    }
    if (role === 'farmer') {
      await supabase.from('farmer_profiles').insert({ id: p.id, availability: 'available' })
    }
  }

  async function sendPasswordReset(phoneInput: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Enter your mobile number first.')

    const { data } = await supabase
      .from('profiles')
      .select('email')
      .eq('phone', phone)
      .not('email', 'is', null)
      .limit(1)
      .maybeSingle()

    if (!data?.email) {
      throw new AuthError(
        'No email is attached to this number, so a reset link cannot be sent. Ask your farm administrator to reset it.',
      )
    }

    const { error } = await supabase.auth.resetPasswordForEmail(data.email, {
      redirectTo: `${window.location.origin}/auth/reset`,
    })
    if (error) throw new AuthError(error.message)
  }

  async function signOut() {
    await supabase.auth.signOut()
    setActiveRole(null)
    setProfile(null)
    setFarm(null)
    setSession(null)
  }

  const value = useMemo<AuthState>(
    () => ({
      session,
      profile,
      farm,
      loading,
      signInWithPhone,
      registerWithPhone,
      signInWithGoogle,
      completeGoogleProfile,
      sendPasswordReset,
      refresh,
      signOut,
    }),
    [session, profile, farm, loading],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

const ROLE_WORD: Record<Role, string> = {
  owner: 'farm owner',
  farmer: 'farmer',
  buyer: 'buyer',
  admin: 'administrator',
}
const ROLE_WORD_TITLE: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
  admin: 'Administrator',
}

export async function isPhoneTakenForRole(phone: string, role: Role) {
  return phoneTaken(phone, role)
}

export function useAuth() {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>')
  return ctx
}

'@
$script:count++

Write-ProjectFile 'src\context\NotificationsContext.tsx' @'
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import type { Notification } from '@/lib/types'

interface NotificationsState {
  items: Notification[]
  unread: number
  loading: boolean
  error: string | null
  markAllRead(): Promise<void>
  markRead(id: string): Promise<void>
  reload(): Promise<void>
}

const Ctx = createContext<NotificationsState | null>(null)

export function NotificationsProvider({ children }: { children: ReactNode }) {
  const { profile } = useAuth()
  const [items, setItems] = useState<Notification[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const profileId = profile?.id ?? null

  const load = useCallback(async () => {
    if (!profileId) {
      setItems([])
      setError(null)
      setLoading(false)
      return
    }
    try {
      const { data, error: qError } = await supabase
        .from('notifications')
        .select('*')
        .eq('user_id', profileId)
        .order('created_at', { ascending: false })
        .limit(100)

      if (qError) {
        setError(qError.message)
        setItems([])
      } else {
        setError(null)
        setItems((data as Notification[]) ?? [])
      }
    } catch (err) {
      setError((err as Error).message)
      setItems([])
    } finally {
      setLoading(false)
    }
  }, [profileId])

  useEffect(() => {
    load()
    if (!profileId) return

    const channel = supabase
      .channel(`notifications-${profileId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${profileId}` },
        () => load(),
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [profileId, load])

  const unread = items.filter((n) => n?.unread).length

  const markAllRead = useCallback(async () => {
    if (!profileId || unread === 0) return
    setItems((prev) => prev.map((n) => ({ ...n, unread: false })))
    const { error: uError } = await supabase
      .from('notifications')
      .update({ unread: false })
      .eq('user_id', profileId)
      .eq('unread', true)
    if (uError) load()
  }, [profileId, unread, load])

  const markRead = useCallback(async (id: string) => {
    setItems((prev) => prev.map((n) => (n.id === id ? { ...n, unread: false } : n)))
    await supabase.from('notifications').update({ unread: false }).eq('id', id)
  }, [])

  const value = useMemo<NotificationsState>(
    () => ({ items, unread, loading, error, markAllRead, markRead, reload: load }),
    [items, unread, loading, error, markAllRead, markRead, load],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useNotifications(): NotificationsState {
  const ctx = useContext(Ctx)

  if (!ctx) {
    return {
      items: [],
      unread: 0,
      loading: false,
      error: null,
      markAllRead: async () => {},
      markRead: async () => {},
      reload: async () => {},
    }
  }
  return ctx
}

'@
$script:count++

Write-ProjectFile 'src\components\ui\index.tsx' @'
import { useEffect, useId, useRef, useState } from 'react'
import type { ReactNode, InputHTMLAttributes, TextareaHTMLAttributes, SelectHTMLAttributes } from 'react'

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  error?: string | null
  hint?: string
}

export function Field({ label, error, hint, className = '', ...props }: FieldProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className={`field ${error ? 'field-error' : ''}`}
        aria-invalid={!!error}
        aria-describedby={error ? `${id}-err` : undefined}
        {...props}
      />
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && (
        <p className="err" id={`${id}-err`}>
          {error}
        </p>
      )}
    </div>
  )
}

export function PasswordField({ label, error, hint, className = '', ...props }: FieldProps) {
  const [shown, setShown] = useState(false)
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type={shown ? 'text' : 'password'}
          className={`field pr-16 ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
        <button
          type="button"
          onClick={() => setShown((s) => !s)}
          className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded-lg px-2.5 py-1.5
                     text-xs font-bold uppercase tracking-wide text-soil-600 hover:bg-soil-100"
          aria-pressed={shown}
        >
          {shown ? 'Hide' : 'Show'}
        </button>
      </div>
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface AreaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  label: string
  error?: string | null
  max?: number
}

export function TextArea({ label, error, max, className = '', value, ...props }: AreaProps) {
  const id = useId()
  const len = String(value ?? '').length
  return (
    <div className={className}>
      <div className="flex items-baseline justify-between">
        <label className="label" htmlFor={id}>
          {label}
        </label>
        {max && (
          <span className={`num text-[12px] ${len > max ? 'text-red-600' : 'text-soil-400'}`}>
            {len}/{max}
          </span>
        )}
      </div>
      <textarea
        id={id}
        rows={4}
        value={value}
        maxLength={max}
        className={`field resize-y ${error ? 'field-error' : ''}`}
        {...props}
      />
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label: string
  error?: string | null
  options: { value: string; label: string }[]
}

export function Select({ label, error, options, className = '', ...props }: SelectProps) {
  const id = useId()
  return (
    <div className={className}>
      {label && (
        <label className="label" htmlFor={id}>
          {label}
        </label>
      )}
      <div className="relative">
        <select
          id={id}
          className={`field select-arrow appearance-none bg-white pr-10 ${error ? 'field-error' : ''}`}
          {...props}
        >
          {options.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
        <svg
          aria-hidden
          className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-soil-400"
          width="16" height="16" viewBox="0 0 24 24" fill="none"
          stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface PhoneProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {
  label?: string
  error?: string | null
}

export function PhoneField({ label = 'Phone Number', error, className = '', ...props }: PhoneProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="flex gap-2">
        <span className="flex w-16 shrink-0 items-center justify-center rounded-lg bg-soil-100 text-[15px] font-semibold text-soil-800">
          +63
        </span>
        <input
          id={id}
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          placeholder="917 123 4567"
          className={`field-soft ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
      </div>
      {error ? (
        <p className="err">{error}</p>
      ) : (
        <p className="mt-1.5 text-[12px] text-soil-400">
          Enter your 10-digit mobile number (e.g. 917 123 4567)
        </p>
      )}
    </div>
  )
}

export function SoftPasswordField({ label, error, className = '', ...props }: FieldProps) {
  const [shown, setShown] = useState(false)
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type={shown ? 'text' : 'password'}
          className={`field-soft pr-16 ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
        <button
          type="button"
          onClick={() => setShown((v) => !v)}
          aria-pressed={shown}
          className="absolute right-2 top-1/2 -translate-y-1/2 rounded-md px-2 py-1.5
                     text-[11px] font-bold uppercase tracking-wide text-soil-600 hover:bg-soil-200"
        >
          {shown ? 'Hide' : 'Show'}
        </button>
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

export function SoftField({ label, error, className = '', ...props }: FieldProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className={`field-soft ${error ? 'field-error' : ''}`}
        aria-invalid={!!error}
        {...props}
      />
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface SackProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'step'> {
  label: string
  error?: string | null
  hint?: string
}

export function SackInput({ label, error, hint, className = '', ...props }: SackProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type="number"
          step="1"
          min={props.min ?? 1}
          inputMode="numeric"
          pattern="[0-9]*"
          onKeyDown={(e) => {
            if (['.', ',', 'e', 'E', '+', '-'].includes(e.key)) e.preventDefault()
            props.onKeyDown?.(e)
          }}
          className={`field num pr-16 ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
        <span className="absolute right-3.5 top-1/2 -translate-y-1/2 text-sm font-semibold text-soil-400">
          sacks
        </span>
      </div>
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && <p className="err">{error}</p>}
    </div>
  )
}

export function PesoInput({ label, error, hint, className = '', ...props }: FieldProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <span className="absolute left-3.5 top-1/2 -translate-y-1/2 text-[15px] font-semibold text-soil-400">
          ₱
        </span>
        <input
          id={id}
          type="number"
          min="0"
          step="0.01"
          inputMode="decimal"
          className={`field num pl-8 ${error ? 'field-error' : ''}`}
          {...props}
        />
      </div>
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && <p className="err">{error}</p>}
    </div>
  )
}

export function Dialog({
  open,
  onClose,
  title,
  description,
  children,
  footer,
}: {
  open: boolean
  onClose(): void
  title: string
  description?: string
  children: ReactNode
  footer?: ReactNode
}) {
  const panel = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) {
      document.body.style.overflow = ''
      return
    }
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', onKey)
    panel.current?.querySelector<HTMLElement>('input,select,textarea,button')?.focus()
    return () => {
      document.removeEventListener('keydown', onKey)
    }
  }, [open, onClose])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 w-screen">
      <div
        className="absolute inset-0 bg-soil-900/40 backdrop-blur-[2px]"
        onClick={onClose}
        aria-hidden
      />

      <div className="relative flex h-full items-end justify-center p-0 sm:items-center sm:p-4">
        <div
          ref={panel}
          role="dialog"
          aria-modal="true"
          aria-label={title}
          className="dialog-panel relative flex w-full max-w-md animate-scale-in flex-col
                     rounded-t-2xl bg-white shadow-2xl sm:rounded-xl"
        >
          <div className="flex shrink-0 items-start justify-between gap-4 rounded-t-2xl border-b border-soil-200 bg-white px-5 py-3.5 sm:rounded-t-xl">
            <div>
              <h2 className="text-[16px] font-bold">{title}</h2>
              {description && <p className="mt-0.5 text-[12px] text-soil-600">{description}</p>}
            </div>
            <button
              onClick={onClose}
              aria-label="Close"
              className="-mr-1 rounded-lg p-1.5 text-soil-400 hover:bg-soil-100 hover:text-soil-800"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                <path d="M18 6 6 18M6 6l12 12" strokeLinecap="round" />
              </svg>
            </button>
          </div>

          <div
            className="min-h-0 flex-1 touch-pan-y overflow-y-auto overscroll-contain px-5 py-4"
            style={{ WebkitOverflowScrolling: 'touch' }}
          >
            {children}
          </div>

        {footer && (
          <div className="flex shrink-0 gap-2 border-t border-soil-200 bg-white px-5 py-3.5 [&>*]:flex-1">
            {footer}
          </div>
        )}
        </div>
      </div>
    </div>
  )
}

const TONES = {
  green: 'bg-green-100 text-green-700',
  amber: 'bg-amber-100 text-amber-700',
  blue: 'bg-blue-100 text-blue-700',
  red: 'bg-red-100 text-red-600',
  grey: 'bg-soil-100 text-soil-600',
  brand: 'bg-brand-50 text-brand-700',
} as const

export function Badge({
  children,
  tone = 'grey',
}: {
  children: ReactNode
  tone?: keyof typeof TONES
}) {
  return <span className={`chip animate-pop ${TONES[tone]}`}>{children}</span>
}

export function Stat({
  label,
  value,
  sub,
  accent,
}: {
  label: string
  value: string
  sub?: string
  accent?: 'brand' | 'green' | 'red'
}) {
  const colour =
    accent === 'green' ? 'text-brand-600' : accent === 'red' ? 'text-red-500' : 'text-soil-900'
  return (
    <div className="card px-4 py-3.5 transition hover:-translate-y-0.5 hover:shadow-md">
      <p className="text-[12px] font-medium text-soil-600">{label}</p>
      <p key={value} className={`num mt-1 animate-count-up text-[21px] font-bold leading-tight ${colour}`}>
        {value}
      </p>
      {sub && <p className="mt-0.5 text-[11px] text-soil-400">{sub}</p>}
    </div>
  )
}

export function Empty({
  title,
  body,
  action,
}: {
  title: string
  body: string
  action?: ReactNode
}) {
  return (
    <div className="card flex animate-fade-up flex-col items-center px-6 py-12 text-center">
      <h3 className="text-[15px] font-bold">{title}</h3>
      <p className="mt-1 max-w-sm text-sm text-soil-600">{body}</p>
      {action && <div className="mt-4">{action}</div>}
    </div>
  )
}

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return (
    <div className="flex animate-fade-up flex-col items-center justify-center gap-3 py-16">
      <span className="relative flex h-9 w-9">
        <span className="absolute inset-0 animate-ping rounded-full bg-brand-600/25" />
        <span className="relative h-9 w-9 animate-spin rounded-full border-[3px] border-soil-200 border-t-brand-600" />
      </span>
      <span className="text-sm text-soil-400">{label}</span>
    </div>
  )
}

export function SectionHeading({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center justify-between gap-3">
      <h2 className="text-[15px] font-bold text-soil-900">{children}</h2>
      {action}
    </div>
  )
}

export function Search({
  value,
  onChange,
  placeholder,
}: {
  value: string
  onChange(v: string): void
  placeholder: string
}) {
  return (
    <div className="relative">
      <svg
        className="absolute left-3.5 top-1/2 -translate-y-1/2 text-soil-400"
        width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2"
      >
        <circle cx="11" cy="11" r="7" />
        <path d="m20 20-3.5-3.5" strokeLinecap="round" />
      </svg>
      <input
        type="search"
        className="field pl-10"
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        aria-label={placeholder}
      />
    </div>
  )
}

export function ViewToggle({
  view,
  onChange,
}: {
  view: 'grid' | 'table'
  onChange(v: 'grid' | 'table'): void
}) {
  return (
    <div className="inline-flex shrink-0 rounded-lg bg-soil-100 p-0.5">
      {(['grid', 'table'] as const).map((v) => (
        <button
          key={v}
          onClick={() => onChange(v)}
          aria-pressed={view === v}
          aria-label={v === 'grid' ? 'Card view' : 'Table view'}
          className={`rounded-md px-2.5 py-1.5 transition ${
            view === v ? 'bg-white text-soil-900 shadow-sm' : 'text-soil-400 hover:text-soil-600'
          }`}
        >
          {v === 'grid' ? (
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <rect x="3" y="3" width="7" height="7" rx="1" />
              <rect x="14" y="3" width="7" height="7" rx="1" />
              <rect x="3" y="14" width="7" height="7" rx="1" />
              <rect x="14" y="14" width="7" height="7" rx="1" />
            </svg>
          ) : (
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <path d="M3 6h18M3 12h18M3 18h18" />
            </svg>
          )}
        </button>
      ))}
    </div>
  )
}

export function DataTable({
  headers,
  children,
  minWidth = '42rem',
}: {
  headers: { label: string; align?: 'left' | 'right' | 'center' }[]
  children: ReactNode
  minWidth?: string
}) {
  return (
    <div className="card overflow-x-auto">
      <table className="w-full text-left text-[13px]" style={{ minWidth }}>
        <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
          <tr>
            {headers.map((h, i) => (
              <th
                key={i}
                className={`px-4 py-2.5 font-semibold ${
                  h.align === 'right' ? 'text-right' : h.align === 'center' ? 'text-center' : ''
                }`}
              >
                {h.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-soil-200">{children}</tbody>
      </table>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\AppShell.tsx' @'
import { useEffect, useRef, useState } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { useAuth } from '@/context/AuthContext'
import { useNotifications } from '@/context/NotificationsContext'
import { ROLE_LABEL, initials } from '@/lib/format'
import type { Role } from '@/lib/types'

interface NavItem {
  to: string
  label: string
  icon: JSX.Element

}

const I = (d: string) => (
  <svg
    width="21"
    height="21"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="1.8"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d={d} />
  </svg>
)

const NAV: Record<Role, NavItem[]> = {
  owner: [
    { to: '/owner/dashboard', label: 'Home', icon: I('M3 10.5 12 3l9 7.5M5 9.5V21h14V9.5') },
    { to: '/owner/calendar', label: 'Calendar', icon: I('M8 2v4M16 2v4M3 10h18M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z') },
    { to: '/owner/market', label: 'Market', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/owner/finance', label: 'Finance', icon: I('M12 2v20M17 6H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6') },
    { to: '/owner/jobs', label: 'Labor', icon: I('M4 7h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2') },
    { to: '/owner/attendance', label: 'Work Log', icon: I('M9 11l3 3 5-5M8 2v4M16 2v4M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z') },
    { to: '/owner/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
  ],
  farmer: [
    { to: '/farmer/jobs', label: 'Find Jobs', icon: I('M4 7h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2') },
    { to: '/farmer/applications', label: 'Applications', icon: I('M9 12h6M9 16h6M9 8h2M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
    { to: '/farmer/logs', label: 'Time Clock', icon: I('M12 7v5l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z') },
    { to: '/farmer/history', label: 'My Logs', icon: I('M9 11l3 3 5-5M8 2v4M16 2v4M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z') },
  ],
  admin: [
    { to: '/admin/dashboard', label: 'Overview', icon: I('M3 12h6v9H3zM9 3h6v18H9zM15 8h6v13h-6z') },
    { to: '/admin/verifications', label: 'Verify', icon: I('M9 12l2 2 4-4M12 3l7 4v5c0 4.4-3 8.3-7 9.5-4-1.2-7-5.1-7-9.5V7z') },
    { to: '/admin/requests', label: 'Admins', icon: I('M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM19 8v6M22 11h-6') },
    { to: '/admin/users', label: 'Users', icon: I('M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8') },
    { to: '/admin/catalog', label: 'Products', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/admin/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
  ],
  buyer: [
    { to: '/buyer/market', label: 'Market', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/buyer/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
  ],
}

export function AppShell({ role }: { role: Role }) {
  const { profile, signOut } = useAuth()
  const { unread } = useNotifications()
  const navigate = useNavigate()
  const [menuOpen, setMenuOpen] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  const items = NAV[role]


  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    return () => document.documentElement.removeAttribute('data-role')
  }, [role])

  useEffect(() => {
    if (!menuOpen) return
    const onClick = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) setMenuOpen(false)
    }
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setMenuOpen(false)
    document.addEventListener('mousedown', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [menuOpen])

  async function handleSignOut() {
    setMenuOpen(false)
    await signOut()
    toast.success('Signed out')
    navigate('/', { replace: true })
  }


  return (
    <div className="min-h-screen">
      <header className="app-bar sticky top-0 z-30">
        <div className="mx-auto flex max-w-[100rem] items-center justify-between gap-3 px-4 py-2.5 lg:px-8">
          <div className="flex items-center gap-2">
            <LeafMark />
            <div>
              <p className="text-[15px] font-bold leading-none tracking-tight">FARMS</p>
              <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.1em] text-white/70">
                {ROLE_LABEL[role]}
              </p>
            </div>
          </div>

          <nav className="hidden flex-1 items-center justify-center gap-0.5 lg:flex">
            {items.map((it) => (
              <NavLink
                key={it.to}
                to={it.to}
                className={({ isActive }) =>
                  `flex items-center gap-1.5 rounded-lg px-3 py-2 text-[13px] font-semibold transition ${
                    isActive
                      ? 'bg-white/20 text-white'
                      : 'text-white/75 hover:bg-white/10 hover:text-white'
                  }`
                }
              >
                <span className="shrink-0">{it.icon}</span>
                {it.label}
              </NavLink>
            ))}
          </nav>

          <div className="flex items-center gap-1">
            <button
              onClick={() => navigate(`/${role}/notifications`)}
              className="relative rounded-lg p-1.5 text-white/90 transition hover:bg-white/15"
              aria-label={unread > 0 ? `Notifications, ${unread} unread` : 'Notifications'}
            >
              <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
                <path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0" />
              </svg>
              {unread > 0 && (
                <span className="num absolute -right-0.5 -top-0.5 flex h-[17px] min-w-[17px] items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-bold text-white ring-2 ring-brand-600">
                  {unread > 99 ? '99+' : unread}
                </span>
              )}
            </button>

            <div className="relative" ref={menuRef}>
              <button
                onClick={() => setMenuOpen((v) => !v)}
                aria-expanded={menuOpen}
                aria-haspopup="menu"
                aria-label="Your account"
                className="flex items-center gap-1.5 rounded-full p-0.5 pr-1.5 transition hover:bg-white/15"
              >
                {profile?.avatar_url ? (
                  <img
                    src={profile.avatar_url}
                    alt=""
                    className="h-8 w-8 shrink-0 rounded-full object-cover ring-2 ring-white/30"
                  />
                ) : (
                  <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-white/20 text-[12px] font-bold text-white">
                    {initials(profile?.name ?? '')}
                  </span>
                )}
                <svg
                  className={`text-white/70 transition ${menuOpen ? 'rotate-180' : ''}`}
                  width="14" height="14" viewBox="0 0 24 24" fill="none"
                  stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"
                >
                  <path d="m6 9 6 6 6-6" />
                </svg>
              </button>

              {menuOpen && (
                <div
                  role="menu"
                  className="absolute right-0 top-full z-40 mt-2 w-60 animate-scale-in overflow-hidden
                             rounded-xl border border-soil-200 bg-white shadow-lg"
                >
                  <div className="flex items-center gap-3 border-b border-soil-200 px-4 py-3">
                    {profile?.avatar_url ? (
                      <img
                        src={profile.avatar_url}
                        alt=""
                        className="h-10 w-10 shrink-0 rounded-full object-cover"
                      />
                    ) : (
                      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-600 text-[13px] font-bold text-white">
                        {initials(profile?.name ?? '')}
                      </span>
                    )}
                    <span className="min-w-0">
                      <span className="block truncate text-[14px] font-bold text-soil-900">
                        {profile?.name || 'Your account'}
                      </span>
                      <span className="block truncate text-[12px] text-soil-400">
                        {ROLE_LABEL[role]}
                      </span>
                    </span>
                  </div>

                  <button
                    role="menuitem"
                    onClick={() => {
                      setMenuOpen(false)
                      navigate(`/${role}/account`)
                    }}
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[14px] font-medium text-soil-800 hover:bg-soil-100"
                  >
                    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z" />
                    </svg>
                    My account
                  </button>

                  <button
                    role="menuitem"
                    onClick={handleSignOut}
                    className="flex w-full items-center gap-2.5 border-t border-soil-200 px-4 py-2.5 text-left text-[14px] font-semibold text-red-600 hover:bg-red-50"
                  >
                    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9" />
                    </svg>
                    Log out
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>

        <nav className="scrollbar-none overflow-x-auto border-t border-white/15 lg:hidden">
          <div className="flex min-w-max gap-0.5 px-3 py-1.5">
            {items.map((it) => (
              <NavLink
                key={it.to}
                to={it.to}
                className={({ isActive }) =>
                  `whitespace-nowrap rounded-md px-3 py-1.5 text-[12px] font-semibold transition ${
                    isActive ? 'bg-white/20 text-white' : 'text-white/70'
                  }`
                }
              >
                {it.label}
              </NavLink>
            ))}
          </div>
        </nav>
      </header>

      <main className="mx-auto max-w-[100rem] px-4 pb-10 pt-4 lg:px-8 lg:pt-6">
        <Outlet />
      </main>

    </div>
  )
}

export function LeafMark({ size = 28, solid = false }: { size?: number; solid?: boolean }) {
  return (
    <span
      className={`flex shrink-0 items-center justify-center rounded-full ${
        solid ? 'bg-brand-600 text-white' : 'bg-white/20 text-white'
      }`}
      style={{ width: size, height: size }}
    >
      <svg width={size * 0.55} height={size * 0.55} viewBox="0 0 24 24" fill="currentColor">
        <path d="M20 3c0 9-5.5 14-12 14a7 7 0 0 1-4-1.2C5.6 9.7 11 5.5 20 3z" />
        <path d="M4 21c0-4 2.5-7.5 6-9.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" fill="none" />
      </svg>
    </span>
  )
}

export function Wordmark({ large = false }: { large?: boolean }) {
  return <span className={`font-bold tracking-tight ${large ? 'text-2xl' : 'text-lg'}`}>FARMS</span>
}

'@
$script:count++

Write-ProjectFile 'src\components\ProtectedRoute.tsx' @'
import { Navigate, useLocation } from 'react-router-dom'
import { useAuth, getActiveRole } from '@/context/AuthContext'
import { ROLE_HOME } from '@/lib/format'
import type { Role } from '@/lib/types'
import { Spinner } from '@/components/ui'
import type { ReactNode } from 'react'

export function ProtectedRoute({ role, children }: { role: Role; children: ReactNode }) {
  const { session, profile, loading } = useAuth()
  const location = useLocation()

  if (loading) return <Spinner label="Checking your account" />

  if (!session) {
    return <Navigate to={`/${role}/login`} state={{ from: location.pathname }} replace />
  }

  if (!profile) {
    const active = getActiveRole()
    if (active && active !== role) return <Navigate to={ROLE_HOME[active]} replace />
    return <Navigate to={`/${role}/login`} replace />
  }

  if (profile.role !== role) return <Navigate to={ROLE_HOME[profile.role]} replace />

  return <>{children}</>
}

'@
$script:count++

Write-ProjectFile 'src\components\AccountHeader.tsx' @'
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { initials } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { ReactNode } from 'react'

export function AccountHeader({ subtitle, extra }: { subtitle?: string; extra?: ReactNode }) {
  const { profile, signOut, refresh } = useAuth()
  const navigate = useNavigate()
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<string | null>(null)

  useEffect(() => {
    setPreview(profile?.avatar_url ?? null)
  }, [profile?.avatar_url])

  async function out() {
    await signOut()
    toast.success('Signed out')
    navigate('/', { replace: true })
  }

  async function pickPhoto(file: File) {
    if (!profile) return
    if (file.size > 3 * 1024 * 1024) {
      toast.error('That photo is over 3 MB. Try a smaller one.')
      return
    }
    setBusy(true)
    const { data: sess } = await supabase.auth.getSession()
    const uid = sess.session?.user.id
    const ext = file.name.split('.').pop()?.toLowerCase() || 'jpg'
    const path = `${uid}/avatar-${Date.now()}.${ext}`

    const { error: upErr } = await supabase.storage
      .from('avatars')
      .upload(path, file, { upsert: true, contentType: file.type })

    if (upErr) {
      setBusy(false)
      toast.error(`Upload failed: ${upErr.message}`)
      return
    }

    const url = supabase.storage.from('avatars').getPublicUrl(path).data.publicUrl
    const { error } = await supabase.from('profiles').update({ avatar_url: url }).eq('id', profile.id)
    setBusy(false)

    if (error) {
      toast.error(error.message)
      return
    }
    setPreview(url)
    toast.success('Profile picture updated')
    await refresh()
  }

  async function removePhoto() {
    if (!profile) return
    setBusy(true)
    await supabase.from('profiles').update({ avatar_url: null }).eq('id', profile.id)
    setBusy(false)
    setPreview(null)
    toast.success('Profile picture removed')
    await refresh()
  }

  return (
    <div className="card animate-fade-up flex flex-wrap items-center gap-4 p-5">
      <div className="group relative shrink-0">
        <label
          htmlFor="avatar"
          className="block cursor-pointer overflow-hidden rounded-full transition hover:opacity-90"
        >
          {preview ? (
            <img
              src={preview}
              alt="Your profile picture"
              className="h-16 w-16 rounded-full object-cover ring-2 ring-brand-600/20"
            />
          ) : (
            <span className="flex h-16 w-16 items-center justify-center rounded-full bg-brand-600 text-lg font-bold text-white">
              {initials(profile?.name ?? '')}
            </span>
          )}
          <span className="absolute inset-0 flex items-center justify-center rounded-full bg-soil-900/55 text-[11px] font-bold text-white opacity-0 transition group-hover:opacity-100">
            {busy ? '…' : 'Change'}
          </span>
        </label>
        <input
          id="avatar"
          type="file"
          accept="image/jpeg,image/png,image/webp"
          className="sr-only"
          disabled={busy}
          onChange={(e) => {
            const f = e.target.files?.[0]
            if (f) pickPhoto(f)
          }}
        />
      </div>

      <div className="min-w-0 flex-1">
        <h2 className="truncate text-lg font-bold">{profile?.name || 'Your account'}</h2>
        {subtitle && <p className="truncate text-sm text-soil-600">{subtitle}</p>}
        <p className="num text-sm text-soil-400">{displayPhone(profile?.phone)}</p>
        {preview ? (
          <button
            onClick={removePhoto}
            disabled={busy}
            className="mt-1 text-[12px] font-semibold text-soil-400 hover:text-red-600"
          >
            Remove photo
          </button>
        ) : (
          <label htmlFor="avatar" className="mt-1 block cursor-pointer text-[12px] font-semibold text-brand-700 hover:underline">
            Add a profile picture (optional)
          </label>
        )}
        {extra}
      </div>

      <button className="btn-ghost" onClick={out}>
        Log out
      </button>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\ErrorBoundary.tsx' @'
import { Component } from 'react'
import type { ErrorInfo, ReactNode } from 'react'

interface Props {
  children: ReactNode
}
interface State {
  error: Error | null
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('FARMS crashed while rendering:', error, info.componentStack)
  }

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="flex min-h-screen items-center justify-center bg-soil-50 px-5 py-10">
        <div className="card w-full max-w-lg p-6">
          <span className="text-3xl" aria-hidden>
            ⚠️
          </span>
          <h1 className="mt-3 text-[20px] font-bold">This page could not load</h1>
          <p className="mt-1.5 text-[14px] leading-relaxed text-soil-600">
            Something went wrong while drawing this screen. The details below say what.
          </p>

          <pre className="mt-4 max-h-52 overflow-auto whitespace-pre-wrap rounded-lg bg-soil-100 p-3.5 text-[12px] leading-relaxed text-soil-800">
            {error.message}
          </pre>

          <div className="mt-5 grid grid-cols-2 gap-2">
            <button className="btn-ghost" onClick={() => this.setState({ error: null })}>
              Try again
            </button>
            <button className="btn-primary" onClick={() => (window.location.href = '/')}>
              Back to start
            </button>
          </div>
        </div>
      </div>
    )
  }
}

'@
$script:count++

Write-ProjectFile 'src\components\BuyerContactCard.tsx' @'
import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { RatingBadge } from '@/components/Ratings'
import { initials, peso, sacks, shortDate } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { Profile } from '@/lib/types'

export function BuyerContactCard({ buyer }: { buyer: Profile | null | undefined }) {
  const [mapOpen, setMapOpen] = useState(false)
  const [history, setHistory] = useState<
    { id: string; quantity: number; total_price: number; created_at: string; variety: string }[] | null
  >(null)
  const [historyOpen, setHistoryOpen] = useState(false)

  useEffect(() => {
    if (!historyOpen || history || !buyer) return
    supabase
      .from('orders')
      .select('id, quantity, total_price, created_at, products(variety)')
      .eq('buyer_id', buyer.id)
      .order('created_at', { ascending: false })
      .limit(10)
      .then(({ data }) =>
        setHistory(
          ((data as any[]) ?? []).map((o) => ({
            id: o.id,
            quantity: o.quantity,
            total_price: o.total_price,
            created_at: o.created_at,
            variety: o.products?.variety ?? 'Product',
          })),
        ),
      )
  }, [historyOpen, buyer?.id])

  if (!buyer) {
    return (
      <p className="rounded-lg bg-soil-100 px-3.5 py-2.5 text-[13px] text-soil-600">
        Buyer details are not available for this order.
      </p>
    )
  }

  const address = [buyer.address, buyer.city, buyer.zip_code].filter(Boolean).join(', ')
  const mapQuery = encodeURIComponent(address || buyer.city || '')

  return (
    <div className="rounded-xl border border-soil-200 bg-white p-4">
      <div className="flex items-start gap-3">
        <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-600 text-[13px] font-semibold text-white">
          {initials(buyer.name || 'B')}
        </span>
        <div className="min-w-0 flex-1">
          <p className="truncate text-[15px] font-bold">{buyer.name || 'Buyer'}</p>
          {buyer.company && (
            <p className="truncate text-[13px] text-soil-600">{buyer.company}</p>
          )}
          <p className="num text-[13px] text-soil-600">{displayPhone(buyer.phone)}</p>
        </div>
      </div>

      {address ? (
        <p className="mt-3 text-[13px] leading-relaxed text-soil-600">📍 {address}</p>
      ) : (
        <p className="mt-3 rounded-lg bg-amber-50 px-3 py-2 text-[12px] leading-relaxed text-amber-800">
          This buyer has not added a delivery address yet. Call them to arrange the drop-off point.
        </p>
      )}

      <div className="mt-3 grid grid-cols-2 gap-2">
        <a href={`tel:${buyer.phone}`} className="btn-primary py-2 text-[13px]">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z" />
          </svg>
          Call buyer
        </a>
        <a href={`sms:${buyer.phone}`} className="btn-ghost py-2 text-[13px]">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.9-.9L3 21l2-4.1A8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z" />
          </svg>
          Text buyer
        </a>
      </div>

      {buyer && (
        <div className="mb-2">
          <RatingBadge profileId={buyer.id} compact />
        </div>
      )}

      <button
        onClick={() => setHistoryOpen((v) => !v)}
        aria-expanded={historyOpen}
        className="mt-2 w-full rounded-lg border border-soil-200 px-3 py-2 text-[13px] font-semibold text-soil-800 hover:bg-soil-100"
      >
        {historyOpen ? 'Hide purchase history' : 'Purchase history'}
      </button>

      {historyOpen && (
        <div className="mt-2 rounded-lg border border-soil-200">
          {history === null ? (
            <p className="px-3.5 py-3 text-[13px] text-soil-400">Loading…</p>
          ) : history.length === 0 ? (
            <p className="px-3.5 py-3 text-[13px] text-soil-600">
              This is their first order with any farm.
            </p>
          ) : (
            <ul className="divide-y divide-soil-200">
              {history.map((h) => (
                <li key={h.id} className="flex items-center justify-between gap-3 px-3.5 py-2.5">
                  <span className="min-w-0">
                    <span className="block truncate text-[13px] font-semibold">{h.variety}</span>
                    <span className="num block text-[11px] text-soil-400">
                      {shortDate(h.created_at)}
                    </span>
                  </span>
                  <span className="num shrink-0 text-right text-[12px]">
                    <span className="block font-semibold">{sacks(h.quantity)} sacks</span>
                    <span className="block text-brand-700">{peso(h.total_price)}</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {mapQuery && (
        <>
          <button
            onClick={() => setMapOpen((v) => !v)}
            className="mt-2 w-full rounded-lg border border-soil-200 px-3 py-2 text-[13px] font-semibold text-soil-800 hover:bg-soil-100"
            aria-expanded={mapOpen}
          >
            {mapOpen ? 'Hide map' : 'Show location on map'}
          </button>

          {mapOpen && (
            <div className="mt-2 space-y-2">
              <iframe
                title={`Map showing ${address}`}
                className="h-56 w-full rounded-lg border border-soil-200"
                loading="lazy"
                referrerPolicy="no-referrer-when-downgrade"
                src={`https://maps.google.com/maps?q=${mapQuery}&z=15&output=embed`}
              />
              <a
                href={`https://www.google.com/maps/search/?api=1&query=${mapQuery}`}
                target="_blank"
                rel="noreferrer"
                className="block text-center text-[13px] font-semibold text-brand-700 hover:underline"
              >
                Open in Google Maps for directions
              </a>
            </div>
          )}
        </>
      )}
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\BuyerPurchases.tsx' @'
import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Empty, Spinner } from '@/components/ui'
import { CROP_COLOR, CROP_EMOJI, peso, sacks, shortDate, titleCase } from '@/lib/format'
import type { Crop } from '@/lib/types'

interface Row {
  id: string
  variety: string
  crop: Crop
  photo_url: string | null
  quantity: number
  total_price: number
  price: number
  stage: string
  paid: boolean
  created_at: string
}

export function BuyerPurchases({ buyerId }: { buyerId: string }) {
  const [rows, setRows] = useState<Row[] | null>(null)

  useEffect(() => {
    setRows(null)
    supabase
      .rpc('buyer_orders_for_my_farm', { p_buyer_id: buyerId })
      .then(({ data }) => setRows((data as Row[]) ?? []))
  }, [buyerId])

  if (!rows) return <Spinner label="Loading their purchases" />
  if (rows.length === 0) {
    return <Empty title="No purchases yet" body="This buyer has not completed an order with you." />
  }

  const completed = rows.filter((r) => r.stage === 'completed')
  const totalSacks = completed.reduce((s, r) => s + r.quantity, 0)
  const totalSpent = completed.reduce((s, r) => s + Number(r.total_price), 0)

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-3 gap-2 rounded-xl bg-brand-50 px-4 py-3 text-center">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
            Orders
          </p>
          <p className="num text-[18px] font-bold text-brand-900">{completed.length}</p>
        </div>
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
            Sacks
          </p>
          <p className="num text-[18px] font-bold text-brand-900">{sacks(totalSacks)}</p>
        </div>
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
            Spent
          </p>
          <p className="num text-[18px] font-bold text-brand-900">{peso(totalSpent)}</p>
        </div>
      </div>

      <ul className="space-y-2">
        {rows.map((r) => (
          <li
            key={r.id}
            className="flex items-center gap-3 rounded-xl border border-soil-200 p-2.5"
          >
            {r.photo_url ? (
              <img
                src={r.photo_url}
                alt={r.variety}
                className="h-14 w-14 shrink-0 rounded-lg object-cover"
              />
            ) : (
              <span
                className={`flex h-14 w-14 shrink-0 items-center justify-center rounded-lg text-2xl ${
                  CROP_COLOR[r.crop].soft
                }`}
              >
                {CROP_EMOJI[r.crop]}
              </span>
            )}

            <span className="min-w-0 flex-1">
              <span className="block truncate text-[14px] font-bold">{r.variety}</span>
              <span className="block text-[12px] text-soil-500">
                {titleCase(r.crop)} · {shortDate(r.created_at)}
              </span>
              <span className="num block text-[12px] text-soil-600">
                {sacks(r.quantity)} sacks × {peso(r.price)}
              </span>
            </span>

            <span className="shrink-0 text-right">
              <span className="num block text-[14px] font-bold text-brand-700">
                {peso(r.total_price)}
              </span>
              <span
                className={`chip mt-1 ${
                  r.stage === 'completed'
                    ? 'bg-green-100 text-green-800'
                    : r.stage === 'cancelled'
                      ? 'bg-red-100 text-red-700'
                      : 'bg-amber-100 text-amber-800'
                }`}
              >
                {titleCase(r.stage)}
              </span>
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\Ratings.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Dialog, Spinner, TextArea } from '@/components/ui'
import { friendlyError } from '@/lib/validation'

export interface RatingSummary {
  average: number
  total: number
  five: number
  four: number
  three: number
  two: number
  one: number
}

export function Stars({ value, size = 16 }: { value: number; size?: number }) {
  return (
    <span className="inline-flex items-center gap-0.5" aria-label={`${value} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((i) => {
        const fill = Math.min(Math.max(value - i + 1, 0), 1)
        return (
          <span key={i} className="relative inline-block" style={{ width: size, height: size }}>
            <Star size={size} className="absolute inset-0 text-soil-200" />
            <span
              className="absolute inset-0 overflow-hidden"
              style={{ width: `${fill * 100}%` }}
              aria-hidden
            >
              <Star size={size} className="text-amber-400" />
            </span>
          </span>
        )
      })}
    </span>
  )
}

function Star({ size, className }: { size: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" className={className}>
      <path d="M12 2l2.9 6.1 6.6.9-4.8 4.6 1.2 6.6L12 17.1 6.1 20.2l1.2-6.6L2.5 9l6.6-.9z" />
    </svg>
  )
}

export function RatingBadge({ profileId, compact }: { profileId: string; compact?: boolean }) {
  const [data, setData] = useState<RatingSummary | null>(null)

  useEffect(() => {
    supabase
      .rpc('rating_summary', { p_profile_id: profileId })
      .then(({ data: d }) => setData((d as RatingSummary) ?? null))
  }, [profileId])

  if (!data || data.total === 0) {
    return compact ? null : (
      <span className="text-[12px] text-soil-400">No ratings yet</span>
    )
  }

  if (compact) {
    return (
      <span className="inline-flex items-center gap-1 text-[12px]">
        <Star size={12} className="text-amber-400" />
        <span className="num font-bold">{Number(data.average).toFixed(1)}</span>
        <span className="text-soil-400">({data.total})</span>
      </span>
    )
  }

  return (
    <div className="rounded-xl border border-soil-200 p-4">
      <div className="flex items-center gap-4">
        <div className="text-center">
          <p className="num text-[30px] font-bold leading-none text-soil-900">
            {Number(data.average).toFixed(1)}
          </p>
          <p className="text-[11px] text-soil-400">out of 5.0</p>
        </div>
        <div className="min-w-0 flex-1">
          <Stars value={Number(data.average)} size={18} />
          <p className="num mt-1 text-[12px] text-soil-600">
            {data.total} rating{data.total === 1 ? '' : 's'}
          </p>
        </div>
      </div>

      <dl className="mt-3 space-y-1">
        {([5, 4, 3, 2, 1] as const).map((n) => {
          const key = (['one', 'two', 'three', 'four', 'five'] as const)[n - 1]
          const count = data[key]
          const pct = data.total ? (count / data.total) * 100 : 0
          return (
            <div key={n} className="flex items-center gap-2">
              <dt className="num w-3 text-[11px] text-soil-500">{n}</dt>
              <Star size={11} className="text-amber-400" />
              <dd className="h-1.5 flex-1 overflow-hidden rounded-full bg-soil-100">
                <span className="block h-full bg-amber-400" style={{ width: `${pct}%` }} />
              </dd>
              <span className="num w-6 text-right text-[11px] text-soil-500">{count}</span>
            </div>
          )
        })}
      </dl>
    </div>
  )
}

export function RateDialog({
  open,
  onClose,
  title,
  description,
  onSubmit,
}: {
  open: boolean
  onClose(): void
  title: string
  description?: string
  onSubmit(stars: number, comment: string): Promise<{ error: unknown } | void>
}) {
  const [stars, setStars] = useState(0)
  const [hover, setHover] = useState(0)
  const [comment, setComment] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (open) {
      setStars(0)
      setHover(0)
      setComment('')
    }
  }, [open])

  const LABELS = ['', 'Poor', 'Fair', 'Good', 'Very good', 'Excellent']

  async function save() {
    if (stars === 0) {
      toast.error('Choose a star rating first.')
      return
    }
    setBusy(true)
    const res = await onSubmit(stars, comment.trim())
    setBusy(false)
    if (res && (res as any).error) {
      toast.error(friendlyError((res as any).error))
      return
    }
    toast.success('Thank you for rating')
    onClose()
  }

  if (!open) return null

  return (
    <Dialog
      open
      onClose={onClose}
      title={title}
      description={description}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Not now
          </button>
          <button className="btn-primary" onClick={save} disabled={busy}>
            {busy ? 'Sending…' : 'Submit rating'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="text-center">
          <div
            className="inline-flex gap-1.5"
            onMouseLeave={() => setHover(0)}
            role="radiogroup"
            aria-label="Star rating"
          >
            {[1, 2, 3, 4, 5].map((n) => (
              <button
                key={n}
                type="button"
                role="radio"
                aria-checked={stars === n}
                aria-label={`${n} star${n === 1 ? '' : 's'}`}
                onMouseEnter={() => setHover(n)}
                onClick={() => setStars(n)}
                className="transition hover:scale-110"
              >
                <Star
                  size={38}
                  className={
                    (hover || stars) >= n ? 'text-amber-400' : 'text-soil-200'
                  }
                />
              </button>
            ))}
          </div>
          <p className="mt-1.5 h-5 text-[14px] font-semibold text-soil-700">
            {LABELS[hover || stars]}
          </p>
        </div>

        <TextArea
          label="Comment (optional)"
          max={300}
          placeholder="What was the transaction like?"
          value={comment}
          onChange={(e) => setComment(e.target.value)}
        />

        <p className="rounded-lg bg-soil-50 px-3.5 py-2.5 text-[12px] leading-relaxed text-soil-600">
          Rate honestly based on your real dealing. Unfair or abusive ratings can be removed by an
          administrator, and repeated cases restrict your account from rating.
        </p>
      </div>
    </Dialog>
  )
}

export function RatingPanel({ profileId }: { profileId: string }) {
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const t = setTimeout(() => setLoading(false), 0)
    return () => clearTimeout(t)
  }, [])

  if (loading) return <Spinner label="Loading ratings" />
  return <RatingBadge profileId={profileId} />
}

'@
$script:count++

Write-ProjectFile 'src\components\PrivacyGate.tsx' @'
import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Spinner } from '@/components/ui'
import { friendlyError } from '@/lib/validation'
import type { ReactNode } from 'react'

export function PrivacyGate({ children }: { children: ReactNode }) {
  const { profile, signOut } = useAuth()
  const [accepted, setAccepted] = useState<boolean | null>(null)
  const [checked, setChecked] = useState(false)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_privacy_accepted')
    setAccepted(Boolean(data))
  }, [profile?.id])

  useEffect(() => {
    load()
  }, [load])

  if (accepted === null) return <Spinner label="Checking your account" />
  if (accepted) return <>{children}</>

  async function accept() {
    if (!checked) {
      toast.error('Please tick the box to continue.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('accept_privacy_notice')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    setAccepted(true)
  }

  return (
    <div className="auth-wash flex min-h-screen items-center justify-center px-5 py-10">
      <div className="relative z-10 w-full max-w-lg">
        <div className="auth-card animate-fade-up rounded-2xl p-6 sm:p-8">
          <div className="text-center">
            <span className="inline-flex h-12 w-12 items-center justify-center rounded-xl bg-white text-brand-700 shadow-sm">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <path d="M12 3l8 3.5v5c0 5-3.4 9.3-8 10.5C7.4 20.8 4 16.5 4 11.5v-5z" />
                <path d="M9 12l2.2 2.2L15.5 10" />
              </svg>
            </span>
            <h1 className="mt-4 text-[22px] font-bold">Data Privacy Notice</h1>
            <p className="mt-1 text-[13px] text-soil-600">
              Please read this before using FARMS. You cannot continue without agreeing.
            </p>
          </div>

          <div className="mt-5 max-h-[42vh] space-y-3 overflow-y-auto rounded-xl bg-white/70 p-4 text-[14px] leading-relaxed text-soil-700">
            <p className="font-semibold text-soil-900">What we collect</p>
            <p>
              Your name, mobile number, and a photo of a valid government ID together with a selfie
              holding that ID. Farm owners also give their farm name, address, and map location.
              Buyers give a delivery address. Farmers record the hours they work.
            </p>

            <p className="font-semibold text-soil-900">Why we collect it</p>
            <p>
              An administrator checks your ID and selfie to confirm you are a real person before
              your account is activated. This protects everyone from fake accounts. The rest is used
              to run orders, jobs, and wages between you and the people you deal with.
            </p>

            <p className="font-semibold text-soil-900">Who can see it</p>
            <p>
              Your ID photo and selfie are stored privately. Only you and the system administrator
              can open them. Other users see only your name, your rating, and your mobile number
              when you have an active order or job together. Farm locations are shown to buyers so
              they can find the farm.
            </p>

            <p className="font-semibold text-soil-900">How long we keep it</p>
            <p>
              Records of orders, work logs, and wages are kept as the shared account of what
              happened between both parties, so either side can rely on them later.
            </p>

            <p className="font-semibold text-soil-900">Your rights</p>
            <p>
              You may ask the administrator to correct your details or remove your account. This
              system is a student capstone project for Barangay Pagatban, Bayawan City, and personal
              information is handled in line with the Data Privacy Act of 2012 (RA 10173).
            </p>
          </div>

          <label className="mt-4 flex cursor-pointer items-start gap-2.5 rounded-xl border border-soil-200 bg-white p-3.5">
            <input
              type="checkbox"
              checked={checked}
              onChange={(e) => setChecked(e.target.checked)}
              className="mt-0.5 h-4 w-4 shrink-0 rounded border-soil-300 text-brand-600 focus:ring-2 focus:ring-brand-600/30"
            />
            <span className="text-[14px] font-medium leading-relaxed text-soil-800">
              I have read and agree to the Data Privacy Notice.
            </span>
          </label>

          <button className="btn-primary mt-4 w-full py-3" onClick={accept} disabled={!checked || busy}>
            {busy ? 'Saving…' : 'Agree and continue'}
          </button>

          <button
            className="mt-2 w-full py-2 text-[13px] font-medium text-soil-500 hover:text-soil-800"
            onClick={async () => {
              await signOut()
            }}
          >
            Disagree and sign out
          </button>
        </div>
      </div>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\FarmProfileDialog.tsx' @'
import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Dialog, Empty, Spinner } from '@/components/ui'
import { RatingBadge } from '@/components/Ratings'
import { CROP_COLOR, CROP_EMOJI, availableSacks, peso, sacks, titleCase } from '@/lib/format'
import type { Crop } from '@/lib/types'

interface FarmProduct {
  id: string
  variety: string
  crop: Crop
  price: number
  quantity: number
  reserved: number
  photo_url: string | null
  status: string
}

interface BestSeller {
  variety: string
  crop: Crop
  photo_url: string | null
  sacks_sold: number
  orders: number
}

interface Profile {
  farm: {
    id: string
    name: string
    city: string | null
    province: string | null
    address: string | null
    latitude: number | null
    longitude: number | null
  } | null
  products: FarmProduct[]
  best_sellers: BestSeller[]
  total_sold: number
}

export function FarmProfileDialog({
  farmId,
  onClose,
}: {
  farmId: string | null
  onClose(): void
}) {
  const [data, setData] = useState<Profile | null>(null)

  useEffect(() => {
    if (!farmId) return
    setData(null)
    supabase.rpc('farm_profile', { p_farm_id: farmId }).then(({ data: d }) => {
      setData((d as Profile) ?? null)
    })
  }, [farmId])

  if (!farmId) return null

  return (
    <Dialog
      open
      onClose={onClose}
      title={data?.farm?.name ?? 'Farm'}
      description={
        data?.farm
          ? [data.farm.city, data.farm.province].filter(Boolean).join(', ') || 'Farm'
          : undefined
      }
      footer={
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      }
    >
      {!data ? (
        <Spinner label="Loading the farm" />
      ) : (
        <div className="space-y-5">
          {data.farm && <RatingBadge profileId={(data as any).owner_id ?? data.farm.id} compact />}

          {data.farm?.latitude != null && data.farm?.longitude != null && (
            <section>
              <h3 className="mb-2 text-[13px] font-bold uppercase tracking-wide text-soil-400">
                Where the farm is
              </h3>
              <iframe
                title={`${data.farm.name} location`}
                className="h-52 w-full rounded-xl border border-soil-200"
                loading="lazy"
                referrerPolicy="no-referrer-when-downgrade"
                src={`https://maps.google.com/maps?q=${data.farm.latitude},${data.farm.longitude}&z=15&output=embed`}
              />
              <a
                href={`https://www.google.com/maps/search/?api=1&query=${data.farm.latitude},${data.farm.longitude}`}
                target="_blank"
                rel="noreferrer"
                className="mt-2 block text-center text-[13px] font-semibold text-brand-700 hover:underline"
              >
                Open in Google Maps
              </a>
            </section>
          )}

          {data.best_sellers.length > 0 && (
            <section>
              <h3 className="mb-2 text-[13px] font-bold uppercase tracking-wide text-soil-400">
                Best selling
              </h3>
              <ul className="space-y-2">
                {data.best_sellers.map((b, i) => (
                  <li
                    key={b.variety + b.crop}
                    className="flex items-center gap-3 rounded-xl border border-amber-200 bg-amber-50 p-2.5"
                  >
                    <span className="num flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-amber-400 text-[13px] font-bold text-white">
                      {i + 1}
                    </span>
                    {b.photo_url ? (
                      <img
                        src={b.photo_url}
                        alt={b.variety}
                        className="h-12 w-12 shrink-0 rounded-lg object-cover"
                      />
                    ) : (
                      <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg bg-white text-xl">
                        {CROP_EMOJI[b.crop]}
                      </span>
                    )}
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[14px] font-bold text-amber-900">
                        {b.variety}
                      </span>
                      <span className="block text-[12px] text-amber-800">
                        {titleCase(b.crop)}
                      </span>
                    </span>
                    <span className="num shrink-0 text-right text-[12px] text-amber-900">
                      <span className="block font-bold">{sacks(b.sacks_sold)} sacks</span>
                      <span className="block">
                        {b.orders} order{b.orders === 1 ? '' : 's'}
                      </span>
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}

          <section>
            <h3 className="mb-2 text-[13px] font-bold uppercase tracking-wide text-soil-400">
              All products
              <span className="num ml-1.5 font-semibold text-soil-400">
                ({data.products.length})
              </span>
            </h3>

            {data.products.length === 0 ? (
              <Empty
                title="Nothing listed"
                body="This farm has no products on the market right now."
              />
            ) : (
              <ul className="grid grid-cols-2 gap-2">
                {data.products.map((p) => {
                  const avail = availableSacks(p)
                  return (
                    <li
                      key={p.id}
                      className="overflow-hidden rounded-xl border border-soil-200 bg-white"
                    >
                      <div className="relative flex aspect-square items-center justify-center overflow-hidden bg-brand-50">
                        {p.photo_url ? (
                          <img
                            src={p.photo_url}
                            alt={p.variety}
                            loading="lazy"
                            className={`h-full w-full object-cover ${
                              avail === 0 ? 'opacity-50 grayscale' : ''
                            }`}
                          />
                        ) : (
                          <span className="text-4xl">{CROP_EMOJI[p.crop]}</span>
                        )}
                        <span
                          className={`absolute left-0 top-2 rounded-r px-2 py-0.5 text-[9px] font-bold uppercase tracking-wide text-white ${
                            avail === 0 ? 'bg-soil-600' : CROP_COLOR[p.crop].bar
                          }`}
                        >
                          {avail === 0 ? 'Sold out' : titleCase(p.crop)}
                        </span>
                      </div>

                      <div className="p-2">
                        <p className="truncate text-[13px] font-semibold">{p.variety}</p>
                        <p className="num text-[15px] font-bold text-brand-700">{peso(p.price)}</p>
                        <p className="num text-[11px] text-soil-500">
                          {avail === 0 ? 'None left' : `${sacks(avail)} sacks available`}
                        </p>
                      </div>
                    </li>
                  )
                })}
              </ul>
            )}
          </section>

          {data.total_sold > 0 && (
            <p className="rounded-lg bg-soil-50 px-4 py-3 text-center text-[13px] text-soil-600">
              This farm has sold{' '}
              <span className="num font-bold text-soil-900">{sacks(data.total_sold)} sacks</span> in
              completed orders.
            </p>
          )}
        </div>
      )}
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\OrderTimeline.tsx' @'
import { ORDER_STAGES, STAGE_LABEL, relativeDate, simplifyStage, stageIndex } from '@/lib/format'
import type { OrderEvent, OrderStage } from '@/lib/types'

export function OrderTimeline({
  stage,
  events = [],
  cancelReason,
}: {
  stage: OrderStage
  events?: OrderEvent[]
  cancelReason?: string | null
}) {
  if (stage === 'cancelled') {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3">
        <p className="text-[14px] font-bold text-red-800">Order cancelled</p>
        {cancelReason && (
          <p className="mt-1 text-[13px] leading-relaxed text-red-700">{cancelReason}</p>
        )}
        <p className="mt-1.5 text-[12px] text-red-600">
          The sacks were returned to the farm's stock.
        </p>
      </div>
    )
  }

  const current = stageIndex(stage)
  const waiting = stage === 'placed'
  const timeFor = (s: OrderStage) =>
    events.find((e) => e.stage === s || simplifyStage(e.stage) === s)?.created_at

  return (
    <>
      {waiting && (
        <p className="mb-3 rounded-lg bg-amber-50 px-3.5 py-2.5 text-[13px] font-medium text-amber-900">
          Waiting for the farm to confirm your order.
        </p>
      )}
      <ol className="relative space-y-0">
      {ORDER_STAGES.map((step, i) => {
        const done = i < current
        const active = i === current
        const at = timeFor(step.stage)

        return (
          <li key={step.stage} className="relative flex gap-3 pb-4 last:pb-0">
            {i < ORDER_STAGES.length - 1 && (
              <span
                aria-hidden
                className={`absolute left-[11px] top-6 h-full w-0.5 ${
                  done ? 'bg-brand-600' : 'bg-soil-200'
                }`}
              />
            )}

            <span
              aria-hidden
              className={`relative z-10 mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2 ${
                done
                  ? 'border-brand-600 bg-brand-600 text-white'
                  : active
                    ? 'border-brand-600 bg-white text-brand-700'
                    : 'border-soil-200 bg-white text-soil-400'
              }`}
            >
              {done ? (
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
              ) : (
                <span className={`h-2 w-2 rounded-full ${active ? 'bg-brand-600' : 'bg-soil-200'}`} />
              )}
            </span>

            <span className="min-w-0 flex-1 pb-1">
              <span
                className={`block text-[14px] leading-snug ${
                  active ? 'font-bold text-brand-700' : done ? 'font-semibold' : 'text-soil-400'
                }`}
              >
                {step.label}
              </span>
              <span className={`block text-[12px] ${active ? 'text-soil-600' : 'text-soil-400'}`}>
                {at ? relativeDate(at) : step.hint}
              </span>
            </span>
          </li>
        )
      })}
      </ol>
    </>
  )
}

export function StageBadge({ stage }: { stage: OrderStage }) {
  const tone =
    stage === 'cancelled'
      ? 'bg-red-100 text-red-700'
      : stage === 'completed' || stage === 'delivered'
        ? 'bg-green-100 text-green-700'
        : stage === 'shipped' || stage === 'ready'
          ? 'bg-blue-100 text-blue-700'
          : 'bg-amber-100 text-amber-700'

  return <span className={`chip ${tone}`}>{STAGE_LABEL[stage]}</span>
}

'@
$script:count++

Write-ProjectFile 'src\components\TopFarms.tsx' @'
import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Empty, Spinner } from '@/components/ui'
import { peso, sacks } from '@/lib/format'

export interface TopFarm {
  rank: number
  farm_id: string
  farm_name: string
  owner_name: string
  city: string | null
  order_count: number
  sacks_sold: number
  total_sales: number
}

export const PERIODS = [
  { days: 7, label: 'This week' },
  { days: 30, label: 'This month' },
  { days: 0, label: 'All time' },
] as const

const MEDAL = ['🥇', '🥈', '🥉']

export function TopFarms({
  limit = 10,
  highlightFarmId,
  showPeriodPicker = true,
  defaultDays = 7,
}: {
  limit?: number
  highlightFarmId?: string | null
  showPeriodPicker?: boolean
  defaultDays?: number
}) {
  const [days, setDays] = useState<number>(defaultDays)
  const [rows, setRows] = useState<TopFarm[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    setRows(null)

    ;(async () => {
      const { data, error: rpcError } = await supabase.rpc('top_selling_farms', {
        p_days: days,
        p_limit: limit,
      })
      if (!alive) return
      if (rpcError) {
        setError(rpcError.message)
        setRows([])
        return
      }
      setError(null)
      setRows((data as TopFarm[]) ?? [])
    })()

    return () => {
      alive = false
    }
  }, [days, limit])

  return (
    <div className="space-y-3">
      {showPeriodPicker && (
        <div className="flex flex-wrap gap-2">
          {PERIODS.map((p) => (
            <button
              key={p.days}
              onClick={() => setDays(p.days)}
              aria-pressed={days === p.days}
              className={`chip border transition ${
                days === p.days
                  ? 'border-brand-600 bg-brand-600 text-white'
                  : 'border-soil-200 bg-white text-soil-600 hover:bg-soil-100'
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
          {error}
        </div>
      )}

      {rows === null ? (
        <Spinner label="Working out the rankings" />
      ) : rows.length === 0 ? (
        <Empty
          title="No sales yet"
          body={
            days === 0
              ? 'Once buyers start ordering, the best-selling farms appear here.'
              : 'No orders in this period. Try a longer one.'
          }
        />
      ) : (
        <ul className="card divide-y divide-soil-200">
          {rows.map((r) => {
            const mine = highlightFarmId && r.farm_id === highlightFarmId
            const top = r.rank <= 3

            return (
              <li
                key={r.farm_id}
                className={`flex items-center gap-3 px-4 py-3 ${mine ? 'bg-brand-50' : ''}`}
              >
                <span
                  className={`num flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-[13px] font-bold ${
                    top ? 'bg-transparent text-lg' : 'bg-soil-100 text-soil-600'
                  }`}
                  aria-label={`Rank ${r.rank}`}
                >
                  {top ? MEDAL[r.rank - 1] : r.rank}
                </span>

                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] font-bold">
                    {r.farm_name}
                    {mine && (
                      <span className="ml-1.5 align-middle text-[10px] font-bold uppercase tracking-wide text-brand-700">
                        You
                      </span>
                    )}
                  </span>
                  <span className="block truncate text-[12px] text-soil-400">
                    {r.owner_name}
                    {r.city ? ` · ${r.city}` : ''}
                  </span>
                </span>

                <span className="shrink-0 text-right">
                  <span className="num block text-[14px] font-bold text-brand-700">
                    {peso(r.total_sales)}
                  </span>
                  <span className="num block text-[11px] text-soil-400">
                    {sacks(r.sacks_sold)} sacks · {r.order_count}{' '}
                    {Number(r.order_count) === 1 ? 'order' : 'orders'}
                  </span>
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

export function MyFarmRank({ days = 7 }: { days?: number }) {
  const [data, setData] = useState<{
    rank: number | null
    orders: number
    sacks: number
    sales: number
    farms: number
  } | null>(null)

  useEffect(() => {
    ;(async () => {
      const { data: res } = await supabase.rpc('my_farm_sales', { p_days: days })
      setData((res as any) ?? null)
    })()
  }, [days])

  if (!data) return null

  return (
    <div className="card flex items-center justify-between gap-4 px-5 py-4">
      <div className="min-w-0">
        <p className="text-[11px] font-bold uppercase tracking-[0.08em] text-soil-400">
          Your sales this week
        </p>
        <p className="num mt-0.5 text-[22px] font-bold text-brand-700">{peso(data.sales)}</p>
        <p className="text-[12px] text-soil-400">
          {sacks(data.sacks)} sacks across {data.orders} {data.orders === 1 ? 'order' : 'orders'}
        </p>
      </div>

      <div className="shrink-0 text-right">
        {data.rank ? (
          <>
            <p className="num text-[28px] font-bold leading-none">
              {data.rank <= 3 ? MEDAL[data.rank - 1] : `#${data.rank}`}
            </p>
            <p className="mt-1 text-[12px] text-soil-400">
              of {data.farms} {data.farms === 1 ? 'farm' : 'farms'}
            </p>
          </>
        ) : (
          <p className="max-w-[9rem] text-[12px] leading-snug text-soil-400">
            No sales yet this week
          </p>
        )}
      </div>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\components\VerificationGate.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Field, SectionHeading, Select, Spinner, TextArea } from '@/components/ui'
import { shortDate } from '@/lib/format'
import { friendlyError, validateRequired } from '@/lib/validation'
import type { OwnerVerification, Role, VerificationStatus } from '@/lib/types'
import type { ReactNode } from 'react'

const ID_TYPES = [
  'PhilSys National ID',
  "Driver's Licence",
  'UMID / SSS',
  'Postal ID',
  'Voter’s ID',
  'Barangay Certificate',
  'Other government ID',
]

export function VerificationGate({ role, children }: { role: Role; children: ReactNode }) {
  const { profile } = useAuth()
  const [record, setRecord] = useState<OwnerVerification | null>(null)
  const [status, setStatus] = useState<VerificationStatus | 'none' | null>(null)

  async function load() {
    if (!profile) return
    const { data } = await supabase
      .from('owner_verifications')
      .select('*')
      .eq('profile_id', profile.id)
      .maybeSingle()

    setRecord((data as OwnerVerification) ?? null)
    setStatus(((data as OwnerVerification)?.status as VerificationStatus) ?? 'none')
  }

  useEffect(() => {
    load()
    if (!profile) return

    const channel = supabase
      .channel(`verification-${profile.id}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'owner_verifications',
          filter: `profile_id=eq.${profile.id}`,
        },
        () => load(),
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [profile?.id])

  if (status === null) return <Spinner label="Checking your verification" />
  if (status === 'approved') return <>{children}</>

  return <VerificationScreen role={role} status={status} record={record} onSubmitted={load} />
}

const ROLE_WORD: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
  admin: 'Administrator',
}

function VerificationScreen({
  role,
  status,
  record,
  onSubmitted,
}: {
  role: Role
  status: VerificationStatus | 'none'
  record: OwnerVerification | null
  onSubmitted(): void
}) {
  const { profile, signOut } = useAuth()
  const [form, setForm] = useState({
    full_name: '',
    id_type: ID_TYPES[0],
    id_number: '',
    farm_name: '',
    farm_address: '',
    barangay: 'Pagatban, Bayawan City',
    farm_size_ha: '',
    latitude: '',
    longitude: '',
    notes: '',
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)
  const [idFile, setIdFile] = useState<File | null>(null)
  const [selfie, setSelfie] = useState<File | null>(null)
  const [selfiePreview, setSelfiePreview] = useState<string | null>(null)

  useEffect(() => {
    if (!selfie) return
    const url = URL.createObjectURL(selfie)
    setSelfiePreview(url)
    return () => URL.revokeObjectURL(url)
  }, [selfie])
  const [preview, setPreview] = useState<string | null>(null)
  const [uploading, setUploading] = useState(false)
  const [locating, setLocating] = useState(false)

  useEffect(() => {
    if (!idFile) return
    const url = URL.createObjectURL(idFile)
    setPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [idFile])

  useEffect(() => {
    if (!record?.id_photo_path) return
    supabase.storage
      .from('verification-ids')
      .createSignedUrl(record.id_photo_path, 600)
      .then(({ data }) => {
        if (data?.signedUrl) setPreview((prev) => prev ?? data.signedUrl)
      })
  }, [record?.id_photo_path])

  useEffect(() => {
    setForm((f) => ({
      ...f,
      full_name: record?.full_name || profile?.name || '',
      id_type: record?.id_type || ID_TYPES[0],
      id_number: record?.id_number || '',
      farm_name: record?.farm_name || '',
      farm_address: record?.farm_address || '',
      barangay: record?.barangay || 'Pagatban, Bayawan City',
      farm_size_ha: record?.farm_size_ha ? String(record.farm_size_ha) : '',
      latitude: record?.latitude != null ? String(record.latitude) : '',
      longitude: record?.longitude != null ? String(record.longitude) : '',
      notes: record?.notes || '',
    }))
  }, [record?.id, profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  if (status === 'pending') {
    return (
      <Shell
        icon="⏳"
        title="Verification under review"
        body={`An administrator is checking your details. You will be notified as soon as your ${ROLE_WORD[role]} account is approved, usually within a working day.`}
        onSignOut={signOut}
      >
        {record && (
          <dl className="mt-4 space-y-2 rounded-lg bg-soil-50 px-4 py-3 text-[13px]">
            <Row label="Submitted" value={shortDate(record.submitted_at)} />
            <Row label="Farm" value={record.farm_name || '—'} />
            <Row label="ID presented" value={record.id_type} />
          </dl>
        )}
      </Shell>
    )
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    const next = {
      full_name: validateRequired(form.full_name, 'Full name'),
      id_photo: idFile || record?.id_photo_path ? null : 'Upload a photo of your ID.',
      selfie: selfie || record?.selfie_path ? null : 'Take a photo of yourself holding your ID.',
      farm_name: role === 'owner' ? validateRequired(form.farm_name, 'Farm name') : null,
      latitude:
        role === 'owner' && !form.latitude ? 'Pin your farm so buyers can find it.' : null,
      longitude: role === 'owner' && !form.longitude ? 'Longitude is missing.' : null,
      farm_address: role === 'owner' ? validateRequired(form.farm_address, 'Farm address') : null,
      barangay: validateRequired(form.barangay, 'Barangay'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)

    let photoPath = record?.id_photo_path ?? null
    if (idFile) {
      setUploading(true)
      const { data: session } = await supabase.auth.getSession()
      const uid = session.session?.user.id
      const ext = idFile.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `${uid}/id-${Date.now()}.${ext}`
      const { error: upError } = await supabase.storage
        .from('verification-ids')
        .upload(path, idFile, { upsert: true, contentType: idFile.type })
      setUploading(false)

      if (upError) {
        setBusy(false)
        toast.error(`Photo upload failed: ${upError.message}`)
        return
      }
      photoPath = path
    }

    let selfiePath = record?.selfie_path ?? null
    if (selfie) {
      setUploading(true)
      const { data: session } = await supabase.auth.getSession()
      const uid = session.session?.user.id
      const ext = selfie.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `${uid}/selfie-${Date.now()}.${ext}`
      const { error: upError } = await supabase.storage
        .from('verification-ids')
        .upload(path, selfie, { upsert: true, contentType: selfie.type })
      setUploading(false)
      if (upError) {
        setBusy(false)
        toast.error(`Selfie upload failed: ${upError.message}`)
        return
      }
      selfiePath = path
    }

    const payload = {
      profile_id: profile.id,
      role,
      status: 'pending' as const,
      full_name: form.full_name.trim(),
      id_type: form.id_type,
      id_number: null,
      id_photo_path: photoPath,
      selfie_path: selfiePath,
      farm_name: form.farm_name.trim(),
      farm_address: form.farm_address.trim(),
      barangay: form.barangay.trim(),
      latitude: form.latitude ? Number(form.latitude) : null,
      longitude: form.longitude ? Number(form.longitude) : null,
      farm_size_ha: form.farm_size_ha ? Number(form.farm_size_ha) : null,
      notes: form.notes.trim() || null,
      review_notes: null,
    }

    const { error } = record
      ? await supabase.from('owner_verifications').update(payload).eq('id', record.id)
      : await supabase.from('owner_verifications').insert(payload)

    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Verification submitted for review')
    onSubmitted()
  }

  return (
    <Shell
      icon={status === 'rejected' ? '⚠️' : '🔒'}
      title={
        status === 'rejected'
          ? 'Verification not approved'
          : `Verify your ${ROLE_WORD[role]} account`
      }
      body={
        status === 'rejected'
          ? 'Your details could not be verified. Correct them below and submit again.'
          : 'Every account is verified before it is activated. Give your details below and an administrator will review them.'
      }
      onSignOut={signOut}
    >
      {status === 'rejected' && record?.review_notes && (
        <div className="mt-4 rounded-lg border border-red-200 bg-red-50 px-4 py-3">
          <p className="text-[13px] font-semibold text-red-800">Reason given</p>
          <p className="mt-0.5 text-[13px] leading-relaxed text-red-700">{record.review_notes}</p>
        </div>
      )}

      <form onSubmit={submit} className="mt-5 space-y-5 text-left" noValidate>
        <section>
          <SectionHeading>Your identity</SectionHeading>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Full legal name"
              className="sm:col-span-2"
              value={form.full_name}
              error={errors.full_name}
              onChange={(e) => set('full_name', e.target.value)}
            />
            <Select
              label="ID type"
              className="sm:col-span-2"
              value={form.id_type}
              onChange={(e) => set('id_type', e.target.value)}
              options={ID_TYPES.map((t) => ({ value: t, label: t }))}
            />

            <div className="sm:col-span-2">
              <label className="label" htmlFor="idphoto">
                Photo of your ID
              </label>

              {preview ? (
                <div className="overflow-hidden rounded-xl border border-soil-200">
                  <img src={preview} alt="Your uploaded ID" className="max-h-64 w-full object-contain bg-soil-50" />
                  <div className="flex items-center justify-between gap-3 border-t border-soil-200 px-3 py-2">
                    <span className="text-[12px] text-soil-600">
                      {idFile ? idFile.name : 'Uploaded earlier'}
                    </span>
                    <button
                      type="button"
                      onClick={() => {
                        setIdFile(null)
                        setPreview(null)
                      }}
                      className="text-[13px] font-semibold text-red-600 hover:underline"
                    >
                      Replace
                    </button>
                  </div>
                </div>
              ) : (
                <label
                  htmlFor="idphoto"
                  className={`flex cursor-pointer flex-col items-center gap-1.5 rounded-xl border-2 border-dashed
                              px-4 py-8 text-center transition hover:bg-soil-50 ${
                                errors.id_photo ? 'border-red-400' : 'border-soil-200'
                              }`}
                >
                  <span className="text-3xl" aria-hidden>
                    📷
                  </span>
                  <span className="text-[14px] font-semibold">Take or choose a photo</span>
                  <span className="text-[12px] text-soil-400">
                    Make sure the name and number are readable. JPG or PNG, up to 5 MB.
                  </span>
                </label>
              )}

              <input
                id="idphoto"
                type="file"
                accept="image/jpeg,image/png,image/webp"
                capture="environment"
                className="sr-only"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (!f) return
                  if (f.size > 5 * 1024 * 1024) {
                    setErrors((x) => ({ ...x, id_photo: 'That photo is over 5 MB. Try a smaller one.' }))
                    return
                  }
                  setIdFile(f)
                  setErrors((x) => ({ ...x, id_photo: null }))
                }}
              />
              {errors.id_photo && <p className="err">{errors.id_photo}</p>}
            </div>

            <div className="sm:col-span-2">
              <label className="label" htmlFor="selfie">
                Photo of yourself holding your ID
              </label>

              {selfiePreview ? (
                <div className="overflow-hidden rounded-xl border border-soil-200">
                  <img
                    src={selfiePreview}
                    alt="You holding your ID"
                    className="max-h-64 w-full bg-soil-50 object-contain"
                  />
                  <div className="flex items-center justify-between gap-3 border-t border-soil-200 px-3 py-2">
                    <span className="text-[12px] text-soil-600">{selfie?.name}</span>
                    <button
                      type="button"
                      onClick={() => setSelfie(null)}
                      className="text-[13px] font-semibold text-red-600 hover:underline"
                    >
                      Retake
                    </button>
                  </div>
                </div>
              ) : (
                <label
                  htmlFor="selfie"
                  className={`flex cursor-pointer flex-col items-center gap-1.5 rounded-xl border-2 border-dashed
                              px-4 py-8 text-center transition hover:bg-soil-50 ${
                                errors.selfie ? 'border-red-400' : 'border-soil-200'
                              }`}
                >
                  <span className="text-3xl" aria-hidden>
                    🤳
                  </span>
                  <span className="text-[14px] font-semibold">Take a selfie with your ID</span>
                  <span className="text-[12px] leading-relaxed text-soil-400">
                    Hold your ID next to your face so the administrator can see the person on the ID
                    is you. Good light, no sunglasses or hat.
                  </span>
                </label>
              )}

              <input
                id="selfie"
                type="file"
                accept="image/jpeg,image/png,image/webp"
                capture="user"
                className="sr-only"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (!f) return
                  if (f.size > 5 * 1024 * 1024) {
                    setErrors((x) => ({ ...x, selfie: 'That photo is over 5 MB.' }))
                    return
                  }
                  setSelfie(f)
                  setErrors((x) => ({ ...x, selfie: null }))
                }}
              />
              {errors.selfie && <p className="err">{errors.selfie}</p>}
            </div>
          </div>
        </section>

        <section className={role === 'owner' ? '' : 'hidden'}>
          <SectionHeading>Your farm</SectionHeading>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Farm name"
              className="sm:col-span-2"
              value={form.farm_name}
              error={errors.farm_name}
              onChange={(e) => set('farm_name', e.target.value)}
            />
            <Field
              label="Farm address"
              className="sm:col-span-2"
              placeholder="Purok / sitio, street"
              value={form.farm_address}
              error={errors.farm_address}
              onChange={(e) => set('farm_address', e.target.value)}
            />
            <Field
              label="Barangay / city"
              value={form.barangay}
              error={errors.barangay}
              onChange={(e) => set('barangay', e.target.value)}
            />
            <div className="sm:col-span-2">
              <label className="label">Pin your farm on the map</label>
              <div className="rounded-xl border border-soil-200 p-4">
                <p className="text-[13px] leading-relaxed text-soil-600">
                  Buyers see this marker so they can find you. Stand at your farm and tap the button
                  below, or open Google Maps, long-press your farm, and copy the two numbers.
                </p>

                <button
                  type="button"
                  className="btn-ghost mt-3 w-full py-2.5 text-[13px]"
                  disabled={locating}
                  onClick={() => {
                    if (!navigator.geolocation) {
                      toast.error('This device cannot share its location.')
                      return
                    }
                    setLocating(true)
                    navigator.geolocation.getCurrentPosition(
                      (pos) => {
                        set('latitude', pos.coords.latitude.toFixed(6))
                        set('longitude', pos.coords.longitude.toFixed(6))
                        setLocating(false)
                        toast.success('Location captured')
                      },
                      () => {
                        setLocating(false)
                        toast.error('Could not read your location. Type the numbers instead.')
                      },
                      { enableHighAccuracy: true, timeout: 10000 },
                    )
                  }}
                >
                  {locating ? 'Finding you…' : '📍 Use my current location'}
                </button>

                <div className="mt-3 grid gap-4 sm:grid-cols-2">
                  <Field
                    label="Latitude"
                    placeholder="9.3644"
                    inputMode="decimal"
                    value={form.latitude}
                    error={errors.latitude}
                    onChange={(e) => set('latitude', e.target.value)}
                  />
                  <Field
                    label="Longitude"
                    placeholder="122.8064"
                    inputMode="decimal"
                    value={form.longitude}
                    error={errors.longitude}
                    onChange={(e) => set('longitude', e.target.value)}
                  />
                </div>

                {form.latitude && form.longitude ? (
                  <>
                    <iframe
                      title="Your farm location"
                      className="mt-3 h-56 w-full rounded-lg border border-soil-200"
                      loading="lazy"
                      referrerPolicy="no-referrer-when-downgrade"
                      src={`https://maps.google.com/maps?q=${form.latitude},${form.longitude}&z=15&output=embed`}
                    />
                    <p className="mt-2 text-center text-[12px] text-soil-500">
                      Check the marker sits on your farm. Adjust the numbers if it does not.
                    </p>
                  </>
                ) : (
                  <p className="mt-3 rounded-lg bg-soil-50 px-3.5 py-3 text-center text-[13px] text-soil-500">
                    No location set yet
                  </p>
                )}
              </div>
            </div>

            <Field
              label="Farm size (hectares)"
              type="number"
              min="0"
              step="0.01"
              inputMode="decimal"
              placeholder="Optional"
              value={form.farm_size_ha}
              onChange={(e) => set('farm_size_ha', e.target.value)}
            />
          </div>
        </section>

        {role !== 'owner' && (
          <Field
            label="Barangay / city"
            value={form.barangay}
            error={errors.barangay}
            onChange={(e) => set('barangay', e.target.value)}
          />
        )}

        <TextArea
          label="Anything else the reviewer should know"
          max={300}
          placeholder="Optional"
          value={form.notes}
          onChange={(e) => set('notes', e.target.value)}
        />

        <button className="btn-primary w-full" disabled={busy}>
          {uploading ? 'Uploading photo…' : busy ? 'Submitting…' : 'Submit for verification'}
        </button>
      </form>
    </Shell>
  )
}

function Shell({
  icon,
  title,
  body,
  children,
  onSignOut,
}: {
  icon: string
  title: string
  body: string
  children?: ReactNode
  onSignOut(): void
}) {
  return (
    <div className="mx-auto max-w-2xl">
      <div className="card p-6 text-center sm:p-8">
        <span className="text-4xl" aria-hidden>
          {icon}
        </span>
        <h1 className="mt-3 text-[22px] font-bold">{title}</h1>
        <p className="mx-auto mt-2 max-w-md text-[14px] leading-relaxed text-soil-600">{body}</p>
        {children}
      </div>
      <div className="mt-4 text-center">
        <button onClick={onSignOut} className="text-[13px] font-semibold text-soil-600 hover:underline">
          Sign out
        </button>
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-soil-600">{label}</dt>
      <dd className="font-semibold">{value}</dd>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\Landing.tsx' @'
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import type { Role } from '@/lib/types'

const line = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.4,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

function SheafIcon() {
  return (
    <svg viewBox="0 0 40 40" className="h-8 w-8" {...line}>
      <path d="M20 34V15" />
      <path d="M20 15c0-3.6-1.5-6.6-4.3-8.7-1.5 3.2-1.3 6.6.6 9.2 1 1.4 2.3 2.4 3.7 3z" />
      <path d="M20 15c0-3.6 1.5-6.6 4.3-8.7 1.5 3.2 1.3 6.6-.6 9.2-1 1.4-2.3 2.4-3.7 3z" />
      <path d="M20 24c-1.6-2.9-4.2-4.7-7.6-5.2.3 3.4 2 6 4.8 7.2 1 .4 1.9.6 2.8.7z" />
      <path d="M20 24c1.6-2.9 4.2-4.7 7.6-5.2-.3 3.4-2 6-4.8 7.2-1 .4-1.9.6-2.8.7z" />
      <path d="M12 34h16" />
    </svg>
  )
}

function WorkerIcon() {
  return (
    <svg viewBox="0 0 40 40" className="h-8 w-8" {...line}>
      <path d="M11 17a9 9 0 0 1 18 0" />
      <path d="M8 17h24" />
      <circle cx="20" cy="23" r="4" />
      <path d="M10 35c0-4.4 4.5-7.5 10-7.5S30 30.6 30 35" />
      <path d="M20 8v2" />
    </svg>
  )
}

function TruckIcon() {
  return (
    <svg viewBox="0 0 40 40" className="h-8 w-8" {...line}>
      <path d="M4 12h17v14H4z" />
      <path d="M21 17h7l5 5v4h-12z" />
      <circle cx="12" cy="29" r="3" />
      <circle cx="27" cy="29" r="3" />
      <path d="M4 26h5M15 26h9" />
    </svg>
  )
}

function ShieldIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" {...line} strokeWidth={1.6}>
      <path d="M12 3l8 3.5v5c0 5-3.4 9.3-8 10.5C7.4 20.8 4 16.5 4 11.5v-5z" />
      <path d="M9 12l2.2 2.2L15.5 10" />
    </svg>
  )
}

const ROLES: {
  role: Role
  title: string
  description: string
  href: string
  icon: JSX.Element
  ring: string
  tint: string
  btn: string
}[] = [
  {
    role: 'owner',
    title: 'Farm Owner',
    description: 'Manage crops, stock, market listings and finances',
    href: '/owner/login',
    icon: <SheafIcon />,
    ring: 'group-hover:border-green-700/40',
    tint: 'bg-green-50 text-green-800',
    btn: 'bg-green-700 hover:bg-green-800',
  },
  {
    role: 'farmer',
    title: 'Farmer',
    description: 'Find farm work, record your hours and track your pay',
    href: '/farmer/login',
    icon: <WorkerIcon />,
    ring: 'group-hover:border-amber-700/40',
    tint: 'bg-amber-50 text-amber-800',
    btn: 'bg-amber-700 hover:bg-amber-800',
  },
  {
    role: 'buyer',
    title: 'Buyer',
    description: 'Buy rice, corn and watermelon direct from the farm',
    href: '/buyer/login',
    icon: <TruckIcon />,
    ring: 'group-hover:border-blue-700/40',
    tint: 'bg-blue-50 text-blue-800',
    btn: 'bg-blue-700 hover:bg-blue-800',
  },
]

export default function Landing() {
  const navigate = useNavigate()
  const [leaving, setLeaving] = useState<string | null>(null)

  function go(href: string, key: string) {
    if (leaving) return
    setLeaving(key)
    window.setTimeout(() => navigate(href), 320)
  }

  return (
    <div className="hero-photo hero-photo-img relative min-h-screen overflow-hidden">
      <div className="hero-scrim absolute inset-0" aria-hidden />

      <div
        className={`relative flex min-h-screen flex-col transition-all duration-300 ${
          leaving ? 'scale-[.98] opacity-0' : 'opacity-100'
        }`}
      >
        <header className="flex items-center gap-3 px-6 py-6 lg:px-12">
          <span className="flex h-9 w-9 items-center justify-center rounded-lg border border-white/25 bg-white/10 text-white backdrop-blur">
            <svg viewBox="0 0 24 24" className="h-5 w-5" {...line} strokeWidth={1.6}>
              <path d="M12 21V11" />
              <path d="M12 11c0-3.9 2.8-6.8 7-7 .2 4.2-2.7 7-7 7z" />
              <path d="M12 15c-3.4 0-5.8-2.3-6-5.8 3.5.2 5.8 2.4 6 5.8z" />
            </svg>
          </span>
          <div>
            <p className="text-[15px] font-semibold leading-none tracking-tight text-white">
              FARMS
            </p>
            <p className="mt-1 text-[11px] tracking-wide text-white/65">
              Barangay Pagatban · Bayawan City
            </p>
          </div>
        </header>

        <main className="flex flex-1 items-center px-6 pb-14 lg:px-12">
          <div className="mx-auto w-full max-w-5xl">
            <div className="max-w-xl animate-fade-up">
              <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-white/60">
                Farm Management System
              </p>
              <h1 className="mt-3 text-[34px] font-semibold leading-[1.1] tracking-tight text-white sm:text-[44px]">
                Plan the harvest.
                <br />
                Sell by the sack.
              </h1>
              <p className="mt-4 max-w-md text-[15px] leading-relaxed text-white/75">
                One system for the farms, workers and buyers of Barangay Pagatban.
                Pumili kung paano mo gagamitin ang FARMS.
              </p>
            </div>

            <div className="mt-10 grid gap-3 sm:grid-cols-3">
              {ROLES.map((r, i) => (
                <button
                  key={r.role}
                  onClick={() => go(r.href, r.role)}
                  style={{ animationDelay: `${120 + i * 80}ms` }}
                  className={`group animate-fade-up rounded-xl border border-white/15 bg-white/95 p-5 text-left
                              backdrop-blur transition duration-200 hover:-translate-y-1 hover:bg-white
                              hover:shadow-[0_18px_40px_-12px_rgba(8,20,12,.45)]
                              focus-visible:-translate-y-1 ${r.ring} ${
                                leaving === r.role ? 'scale-[1.03] ring-2 ring-white' : ''
                              }`}
                >
                  <span
                    className={`inline-flex h-12 w-12 items-center justify-center rounded-lg ${r.tint}`}
                  >
                    {r.icon}
                  </span>

                  <h2 className="mt-4 text-[17px] font-semibold tracking-tight text-soil-900">
                    {r.title}
                  </h2>
                  <p className="mt-1 text-[13px] leading-relaxed text-soil-600">{r.description}</p>

                  <span
                    className={`mt-4 flex w-full items-center justify-center gap-1.5 rounded-lg py-2.5
                                text-[14px] font-semibold text-white transition ${r.btn}`}
                  >
                    {leaving === r.role ? 'Opening…' : 'Sign In'}
                    {leaving !== r.role && (
                      <svg
                        className="transition group-hover:translate-x-0.5"
                        viewBox="0 0 24 24"
                        width="15"
                        height="15"
                        {...line}
                        strokeWidth={2.2}
                      >
                        <path d="M5 12h13M13 6l6 6-6 6" />
                      </svg>
                    )}
                  </span>
                </button>
              ))}
            </div>

            <div className="mt-8 flex animate-fade-up items-center gap-4" style={{ animationDelay: '380ms' }}>
              <span className="h-px flex-1 bg-white/20" />
              <button
                onClick={() => go('/admin/login', 'admin')}
                className="group inline-flex items-center gap-2 rounded-lg border border-white/20 px-4 py-2
                           text-[13px] font-medium text-white/80 transition hover:border-white/40 hover:bg-white/10 hover:text-white"
              >
                <ShieldIcon />
                Administrator access
                <svg
                  className="opacity-60 transition group-hover:translate-x-0.5 group-hover:opacity-100"
                  viewBox="0 0 24 24" width="14" height="14" {...line} strokeWidth={2}
                >
                  <path d="M5 12h13M13 6l6 6-6 6" />
                </svg>
              </button>
              <span className="h-px flex-1 bg-white/20" />
            </div>
          </div>
        </main>
      </div>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\NotificationsPage.tsx' @'
import { useNavigate } from 'react-router-dom'
import { useNotifications } from '@/context/NotificationsContext'
import { Empty, Spinner } from '@/components/ui'
import { relativeDate } from '@/lib/format'
import type { NotifType } from '@/lib/types'

const ICON: Record<string, string> = {
  harvest: '🌾',
  sale: '💰',
  purchase: '📦',
  job_post: '📋',
  application: '✉️',
  hired: '🎉',
  rejected: '📭',
  general: '🔔',
}

const TINT: Record<string, string> = {
  harvest: 'bg-green-100',
  sale: 'bg-green-100',
  purchase: 'bg-blue-100',
  job_post: 'bg-amber-100',
  application: 'bg-amber-100',
  hired: 'bg-green-100',
  rejected: 'bg-soil-100',
  general: 'bg-soil-100',
}

export default function NotificationsPage() {
  const { items, unread, loading, error, markAllRead, markRead, reload } = useNotifications()
  const navigate = useNavigate()

  if (loading) return <Spinner label="Loading notifications" />

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Notifications</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            {unread > 0 ? `${unread} unread` : 'You are all caught up'}
          </p>
        </div>
        {unread > 0 && (
          <button className="btn-ghost" onClick={markAllRead}>
            Mark all as read
          </button>
        )}
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700"
        >
          <p className="font-semibold">Notifications could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
          <button onClick={reload} className="mt-2 font-semibold underline">
            Try again
          </button>
        </div>
      )}

      {!error && items.length === 0 ? (
        <Empty
          title="Nothing yet"
          body="Sales, job applications and hiring decisions all show up here."
        />
      ) : (
        <ul className="card divide-y divide-soil-200">
          {items.map((n) => {
            const type = (n?.type ?? 'general') as NotifType
            return (
              <li key={n.id}>
                <button
                  onClick={() => {
                    markRead(n.id)
                    if (n.link) navigate(n.link)
                  }}
                  className={`flex w-full items-start gap-3 px-4 py-3.5 text-left transition hover:bg-soil-50 ${
                    n.unread ? 'bg-brand-50/60' : ''
                  }`}
                >
                  <span
                    className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-[17px] ${
                      TINT[type] ?? 'bg-soil-100'
                    }`}
                    aria-hidden
                  >
                    {ICON[type] ?? '🔔'}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span
                      className={`block text-[14px] leading-snug ${n.unread ? 'font-semibold' : ''}`}
                    >
                      {n.message ?? ''}
                    </span>
                    <span className="mt-0.5 block text-[12px] text-soil-400">
                      {n.created_at ? relativeDate(n.created_at) : ''}
                    </span>
                  </span>
                  {n.unread && (
                    <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-brand-600" />
                  )}
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\auth\LoginPage.tsx' @'
import { useEffect, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { Dialog } from '@/components/ui'
import { useAuth } from '@/context/AuthContext'
import { ROLE_HOME, ROLE_LABEL } from '@/lib/format'
import type { Role } from '@/lib/types'
import { friendlyError, validateName, validatePassword, validatePhone } from '@/lib/validation'

const BLURB: Record<Role, string> = {
  owner: 'Manage your farm, crops, market listings and finances',
  farmer: 'Find farm work opportunities and apply for jobs',
  buyer: 'Browse and buy fresh farm products by the sack',
  admin: 'Verify accounts and oversee the whole system',
}

const NEXT_ROLE: Record<Role, { role: Role; label: string }> = {
  owner: { role: 'buyer', label: 'Log in as Buyer' },
  farmer: { role: 'buyer', label: 'Log in as Buyer' },
  buyer: { role: 'owner', label: 'Log in as Farm Owner' },
  admin: { role: 'owner', label: 'Log in as Farm Owner' },
}

type Errors = Record<string, string | null>

export default function LoginPage({ role }: { role: Role }) {
  const { session, profile, signInWithPhone, registerWithPhone, signInWithGoogle, sendPasswordReset } =
    useAuth()
  const navigate = useNavigate()

  const [tab, setTab] = useState<'signin' | 'register'>('signin')
  const [busy, setBusy] = useState(false)
  const [agreed, setAgreed] = useState(false)
  const [privacyOpen, setPrivacyOpen] = useState(false)
  const [errors, setErrors] = useState<Errors>({})
  const [form, setForm] = useState({ name: '', phone: '', password: '', confirm: '' })

  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    return () => document.documentElement.removeAttribute('data-role')
  }, [role])

  if (session && profile?.role === role) return <Navigate to={ROLE_HOME[role]} replace />

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    if (errors[k]) setErrors((e) => ({ ...e, [k]: null }))
  }

  function switchTab(next: 'signin' | 'register') {
    setTab(next)
    setErrors({})
  }

  async function onSignIn(e: React.FormEvent) {
    e.preventDefault()
    const next: Errors = {
      phone: validatePhone(form.phone),
      password: form.password ? null : 'Enter your password.',
    }
    setErrors(next)
    if (next.phone || next.password) return

    setBusy(true)
    try {
      await signInWithPhone(role, form.phone, form.password)
      toast.success(`Signed in as ${ROLE_LABEL[role]}`)
      navigate(ROLE_HOME[role], { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  async function onRegister(e: React.FormEvent) {
    e.preventDefault()
    if (!agreed) {
      setErrors({ form: 'Please read and agree to the Data Privacy Notice first.' })
      return
    }
    const next: Errors = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      password: validatePassword(form.password),
      confirm: form.password !== form.confirm ? 'Both passwords must match.' : null,
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    try {
      await registerWithPhone(role, form.name.trim(), form.phone, form.password)
      toast.success(`${ROLE_LABEL[role]} account created`)
      navigate(ROLE_HOME[role], { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  async function onGoogle() {
    if (tab === 'register' && !agreed) {
      setErrors({ form: 'Please read and agree to the Data Privacy Notice first.' })
      return
    }
    setBusy(true)
    try {
      await signInWithGoogle(role)
    } catch (err) {
      setErrors({ form: friendlyError(err) })
      setBusy(false)
    }
  }

  async function onForgot() {
    if (validatePhone(form.phone)) {
      setErrors({ phone: 'Enter your mobile number first, then tap Forgot password.' })
      return
    }
    try {
      await sendPasswordReset(form.phone)
      toast.success('Password reset link sent to the email on this account.')
    } catch (err) {
      toast.error(friendlyError(err))
    }
  }

  const other = NEXT_ROLE[role]

  return (
    <div className="auth-wash flex min-h-screen flex-col px-5 py-6">
      <Link
        to="/"
        className="relative z-10 inline-flex w-fit items-center gap-2.5 rounded-lg border border-white/20
                   bg-white/10 px-3.5 py-2 text-[13px] font-semibold text-white backdrop-blur
                   transition hover:border-white/40 hover:bg-white/20"
      >
        <span className="flex h-6 w-6 items-center justify-center rounded-md bg-white/15 text-white">
          <SproutIcon size={14} />
        </span>
        FARMS
      </Link>

      <div className="relative z-10 flex flex-1 items-center justify-center py-8">
        <div className="w-full max-w-[26rem]">
          <div className="auth-card animate-fade-up rounded-3xl p-7 sm:p-9">
            <div className="flex flex-col items-center text-center">
              <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white text-brand-700 shadow-[0_4px_14px_-4px_rgba(16,24,40,.25)]">
                <SproutIcon size={26} />
              </span>

              <h1 className="mt-5 text-[26px] font-bold leading-tight tracking-tight">
                Sign in as {ROLE_LABEL[role]}
              </h1>
              <p className="mt-1.5 max-w-[19rem] text-[14px] leading-relaxed text-soil-600">
                {BLURB[role]}
              </p>
            </div>

            <div role="tablist" className="mt-6 grid grid-cols-2 gap-1 rounded-xl bg-white/70 p-1">
              {(['signin', 'register'] as const).map((t) => (
                <button
                  key={t}
                  role="tab"
                  aria-selected={tab === t}
                  onClick={() => switchTab(t)}
                  className={`rounded-lg px-3 py-2 text-[13px] font-semibold transition ${
                    tab === t
                      ? 'bg-white text-soil-900 shadow-sm'
                      : 'text-soil-500 hover:text-soil-900'
                  }`}
                >
                  {t === 'signin' ? 'Sign in' : 'Create account'}
                </button>
              ))}
            </div>

            {errors.form && (
              <div
                role="alert"
                className="mt-4 animate-fade-up rounded-xl border border-red-200 bg-red-50 px-3.5 py-2.5 text-[13px] font-medium text-red-700"
              >
                {errors.form}
              </div>
            )}

            {tab === 'signin' ? (
              <form onSubmit={onSignIn} className="mt-5 space-y-3" noValidate>
                <PhoneRow
                  value={form.phone}
                  error={errors.phone}
                  onChange={(v) => set('phone', v)}
                />
                <PasswordRow
                  value={form.password}
                  error={errors.password}
                  autoComplete="current-password"
                  placeholder="Password"
                  onChange={(v) => set('password', v)}
                />

                <div className="flex justify-end pt-0.5">
                  <button
                    type="button"
                    onClick={onForgot}
                    className="text-[13px] font-medium text-soil-600 hover:text-soil-900 hover:underline"
                  >
                    Forgot password?
                  </button>
                </div>

                <button type="submit" className="btn-dark mt-1" disabled={busy}>
                  {busy ? 'Signing in…' : 'Get Started'}
                </button>
              </form>
            ) : (
              <form onSubmit={onRegister} className="mt-5 space-y-3" noValidate>
                <IconRow
                  icon={<UserIcon />}
                  placeholder="Full name"
                  autoComplete="name"
                  value={form.name}
                  error={errors.name}
                  onChange={(v) => set('name', v)}
                />
                <PhoneRow
                  value={form.phone}
                  error={errors.phone}
                  onChange={(v) => set('phone', v)}
                />
                <PasswordRow
                  value={form.password}
                  error={errors.password}
                  autoComplete="new-password"
                  placeholder="Password (at least 8 characters)"
                  onChange={(v) => set('password', v)}
                />
                <PasswordRow
                  value={form.confirm}
                  error={errors.confirm}
                  autoComplete="new-password"
                  placeholder="Confirm password"
                  onChange={(v) => set('confirm', v)}
                />

                <div className="rounded-xl border border-soil-200 bg-white/70 p-3.5">
                  <button
                    type="button"
                    onClick={() => setPrivacyOpen(true)}
                    className="text-left text-[13px] font-semibold text-brand-700 hover:underline"
                  >
                    Read the Data Privacy Notice
                  </button>

                  <label className="mt-2 flex cursor-pointer items-start gap-2.5">
                    <input
                      type="checkbox"
                      checked={agreed}
                      onChange={(e) => setAgreed(e.target.checked)}
                      className="mt-0.5 h-4 w-4 shrink-0 rounded border-soil-300 text-brand-600
                                 focus:ring-2 focus:ring-brand-600/30"
                    />
                    <span className="text-[13px] leading-relaxed text-soil-700">
                      I have read and agree to the Data Privacy Notice.
                    </span>
                  </label>
                </div>

                <button type="submit" className="btn-dark mt-1" disabled={busy || !agreed}>
                  {busy ? 'Creating account…' : 'Create account'}
                </button>
              </form>
            )}

            <div className="my-5 flex items-center gap-3">
              <span className="dotted-rule h-px flex-1" />
              <span className="text-[12px] text-soil-400">Or sign in with</span>
              <span className="dotted-rule h-px flex-1" />
            </div>

            <button
              onClick={onGoogle}
              disabled={busy}
              className="flex w-full items-center justify-center gap-2.5 rounded-xl border border-soil-200
                         bg-white py-3 text-[14px] font-semibold text-soil-800 transition
                         hover:-translate-y-px hover:shadow-md disabled:opacity-50"
            >
              <GoogleMark />
              Google
            </button>
          </div>

          <div className="mt-5 flex flex-col items-center gap-2.5">
            <Link
              to={`/${other.role}/login`}
              className="inline-flex items-center gap-2 rounded-full bg-white px-5 py-2.5 text-[13px]
                         font-semibold text-soil-800 shadow-sm transition hover:-translate-y-px hover:shadow-md"
            >
              {other.label}
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
                <path d="M5 12h13M13 6l6 6-6 6" />
              </svg>
            </Link>
            <p className="text-center text-[12px] text-white/60">
              One mobile number can hold a separate account for each role.
            </p>
          </div>
        </div>
      </div>
      <PrivacyNotice open={privacyOpen} onClose={() => setPrivacyOpen(false)} />
    </div>
  )
}

function PrivacyNotice({ open, onClose }: { open: boolean; onClose(): void }) {
  if (!open) return null
  return (
    <Dialog
      open
      onClose={onClose}
      title="Data Privacy Notice"
      description="How FARMS handles your information"
      footer={
        <button className="btn-primary" onClick={onClose}>
          I understand
        </button>
      }
    >
      <div className="space-y-3 text-[14px] leading-relaxed text-soil-700">
        <p>
          FARMS collects your name, mobile number, and a photo of a valid ID so that an
          administrator can confirm you are a real person before your account is activated. Farm
          owners also give their farm name and location, and buyers give a delivery address.
        </p>
        <p>
          Your ID photo and selfie are stored privately. Only you and the system administrator can
          open them, and they are used solely to verify your identity.
        </p>
        <p>
          Other users see only what is needed to deal with you: your name, your mobile number when
          you have an active order or job together, and your rating. Nobody else sees your ID.
        </p>
        <p>
          Records of orders, work logs, and wages are kept as the shared account of what happened
          between you and the other party, so both sides can rely on them.
        </p>
        <p>
          You may ask the administrator to correct your details or to remove your account. This
          system is a student capstone project for Barangay Pagatban and is handled in line with
          the Data Privacy Act of 2012 (RA 10173).
        </p>
      </div>
    </Dialog>
  )
}

function IconRow({
  icon,
  error,
  onChange,
  ...props
}: {
  icon: React.ReactNode
  error?: string | null
  onChange(v: string): void
} & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'onChange'>) {
  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-soil-400">
          {icon}
        </span>
        <input
          className={`field-icon ${error ? 'border-red-300 bg-red-50/50' : ''}`}
          aria-invalid={!!error}
          onChange={(e) => onChange(e.target.value)}
          {...props}
        />
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

function PhoneRow({
  value,
  error,
  onChange,
}: {
  value: string
  error?: string | null
  onChange(v: string): void
}) {
  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 flex items-center gap-1.5">
          <PhoneIcon />
          <span className="text-[14px] font-semibold text-soil-500">+63</span>
        </span>
        <input
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          placeholder="917 123 4567"
          className={`field-icon pl-[5.2rem] ${error ? 'border-red-300 bg-red-50/50' : ''}`}
          aria-invalid={!!error}
          aria-label="Mobile number"
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
      </div>
      {error ? (
        <p className="err">{error}</p>
      ) : (
        <p className="mt-1 pl-1 text-[12px] text-soil-400">Your 10-digit mobile number</p>
      )}
    </div>
  )
}

function PasswordRow({
  value,
  error,
  placeholder,
  autoComplete,
  onChange,
}: {
  value: string
  error?: string | null
  placeholder: string
  autoComplete: string
  onChange(v: string): void
}) {
  const [shown, setShown] = useState(false)
  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-soil-400">
          <LockIcon />
        </span>
        <input
          type={shown ? 'text' : 'password'}
          autoComplete={autoComplete}
          placeholder={placeholder}
          className={`field-icon pr-11 ${error ? 'border-red-300 bg-red-50/50' : ''}`}
          aria-invalid={!!error}
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
        <button
          type="button"
          onClick={() => setShown((v) => !v)}
          aria-label={shown ? 'Hide password' : 'Show password'}
          aria-pressed={shown}
          className="absolute right-3 top-1/2 -translate-y-1/2 text-soil-400 transition hover:text-soil-800"
        >
          {shown ? <EyeOffIcon /> : <EyeIcon />}
        </button>
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

const stroke = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.9,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

function UserIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" {...stroke}>
      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z" />
    </svg>
  )
}

function PhoneIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" {...stroke}>
      <rect x="6" y="2" width="12" height="20" rx="2.5" />
      <path d="M11 18.5h2" />
    </svg>
  )
}

function LockIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" {...stroke}>
      <rect x="4" y="10" width="16" height="11" rx="2.5" />
      <path d="M8 10V7a4 4 0 0 1 8 0v3" />
    </svg>
  )
}

function EyeIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" {...stroke}>
      <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  )
}

function EyeOffIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" {...stroke}>
      <path d="M10.6 6.2A9.9 9.9 0 0 1 12 6c6.4 0 10 6 10 6a17 17 0 0 1-3 3.6M6.5 7.8A17 17 0 0 0 2 12s3.6 6 10 6a9.6 9.6 0 0 0 4-.8" />
      <path d="M3 3l18 18" />
      <path d="M9.9 10.1a3 3 0 0 0 4.1 4.2" />
    </svg>
  )
}

function SproutIcon({ size = 26 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 21V11" />
      <path d="M12 11C12 7.5 9.5 5 6 5c0 3.5 2.5 6 6 6z" fill="currentColor" stroke="none" />
      <path d="M12 12c0-3.5 2.5-6 6-6 0 3.5-2.5 6-6 6z" fill="currentColor" stroke="none" />
    </svg>
  )
}

function GoogleMark() {
  return (
    <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden>
      <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.6l6.7-6.7C35.6 2.6 30.2 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.8 6.1C12.3 13.2 17.6 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.6 24.6c0-1.6-.1-3.2-.4-4.6H24v9.1h12.7c-.6 3-2.3 5.5-4.8 7.2l7.5 5.8c4.4-4.1 7.2-10.1 7.2-17.5z" />
      <path fill="#FBBC05" d="M10.4 28.7c-.5-1.5-.8-3-.8-4.7s.3-3.2.8-4.7l-7.8-6.1C1 16.4 0 20.1 0 24s1 7.6 2.6 10.8l7.8-6.1z" />
      <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.5-5.8c-2.1 1.4-4.8 2.3-8.4 2.3-6.4 0-11.7-3.7-13.6-9.8l-7.8 6.1C6.5 42.6 14.6 48 24 48z" />
    </svg>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\auth\AuthCallback.tsx' @'
import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, setActiveRole } from '@/context/AuthContext'
import { Field, Spinner } from '@/components/ui'
import { Wordmark } from '@/components/AppShell'
import { ROLE_HOME, ROLE_LABEL } from '@/lib/format'
import type { Role } from '@/lib/types'
import { friendlyError, validateName, validatePhone } from '@/lib/validation'

export default function AuthCallback() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { completeGoogleProfile, refresh } = useAuth()

  const role = (params.get('role') as Role) ?? 'owner'
  const [checking, setChecking] = useState(true)
  const [googleEmail, setGoogleEmail] = useState('')
  const [form, setForm] = useState({ name: '', phone: '' })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    ;(async () => {
      const { data } = await supabase.auth.getSession()
      if (!data.session) {
        navigate(`/${role}/login`, { replace: true })
        return
      }
      setActiveRole(role)

      const { data: prof } = await supabase
        .from('profiles')
        .select('id')
        .eq('user_id', data.session.user.id)
        .eq('role', role)
        .maybeSingle()

      if (prof) {
        await refresh()
        navigate(ROLE_HOME[role], { replace: true })
        return
      }

      const meta = data.session.user.user_metadata as { full_name?: string; name?: string }
      setGoogleEmail(data.session.user.email ?? '')
      setForm((f) => ({ ...f, name: meta.full_name ?? meta.name ?? '' }))
      setChecking(false)
    })()
  }, [role])

  async function switchAccount() {
    await supabase.auth.signOut()
    navigate(`/${role}/login`, { replace: true })
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    const next = { name: validateName(form.name), phone: validatePhone(form.phone) }
    setErrors(next)
    if (next.name || next.phone) return

    setBusy(true)
    try {
      await completeGoogleProfile(role, form.name.trim(), form.phone)
      toast.success(`${ROLE_LABEL[role]} account ready`)
      navigate(ROLE_HOME[role], { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  if (checking) return <Spinner label="Finishing sign in" />

  return (
    <div className="min-h-screen bg-soil-50">
      <div className="mx-auto max-w-md px-5 py-10">
        <Wordmark large />
        <p className="mt-1 text-[12px] font-bold uppercase tracking-[0.14em] text-brand-700">
          {ROLE_LABEL[role]}
        </p>
        <h1 className="mt-6 text-2xl font-bold">Finish your profile</h1>
        <p className="mt-2 text-[15px] leading-relaxed text-soil-600">
          Google does not share a mobile number. Add yours so farms and buyers can reach you.
        </p>

        {googleEmail && (
          <div className="mt-4 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-soil-200 bg-white px-4 py-3">
            <span className="min-w-0">
              <span className="block text-[11px] font-semibold uppercase tracking-wide text-soil-400">
                Signed in with Google as
              </span>
              <span className="block truncate text-[14px] font-semibold">{googleEmail}</span>
            </span>
            <button
              type="button"
              onClick={switchAccount}
              className="text-[13px] font-semibold text-brand-700 hover:underline"
            >
              Use another account
            </button>
          </div>
        )}

        {errors.form && (
          <div role="alert" className="mt-5 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-700">
            {errors.form}
          </div>
        )}

        <form onSubmit={onSubmit} className="mt-6 space-y-4" noValidate>
          <Field
            label="Full name"
            value={form.name}
            error={errors.name}
            onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
          />
          <Field
            label="Mobile number"
            type="tel"
            inputMode="tel"
            placeholder="09171234567"
            value={form.phone}
            error={errors.phone}
            onChange={(e) => setForm((f) => ({ ...f, phone: e.target.value }))}
          />
          <button className="btn-primary w-full" disabled={busy}>
            {busy ? 'Saving…' : 'Enter FARMS'}
          </button>
        </form>
      </div>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\auth\AdminLoginPage.tsx' @'
import { useEffect, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { useAuth } from '@/context/AuthContext'
import { ROLE_HOME } from '@/lib/format'
import { friendlyError, validatePhone } from '@/lib/validation'

const line = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

export default function AdminLoginPage() {
  const { session, profile, signInWithPhone, signInWithGoogle } = useAuth()
  const navigate = useNavigate()

  const [phone, setPhone] = useState('')
  const [password, setPassword] = useState('')
  const [shown, setShown] = useState(false)
  const [busy, setBusy] = useState(false)
  const [errors, setErrors] = useState<Record<string, string | null>>({})

  useEffect(() => {
    document.documentElement.setAttribute('data-role', 'admin')
    return () => document.documentElement.removeAttribute('data-role')
  }, [])

  if (session && profile?.role === 'admin') return <Navigate to={ROLE_HOME.admin} replace />

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      phone: validatePhone(phone),
      password: password ? null : 'Enter your password.',
    }
    setErrors(next)
    if (next.phone || next.password) return

    setBusy(true)
    try {
      await signInWithPhone('admin', phone, password)
      toast.success('Signed in as Administrator')
      navigate(ROLE_HOME.admin, { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  async function onGoogle() {
    setBusy(true)
    try {
      await signInWithGoogle('admin')
    } catch (err) {
      setErrors({ form: friendlyError(err) })
      setBusy(false)
    }
  }

  return (
    <div className="admin-login flex min-h-screen items-center justify-center px-5 py-10">
      <div className="w-full max-w-[24rem]">
        <div className="admin-card relative animate-fade-up overflow-hidden rounded-2xl">
          <div className="relative z-10 px-8 pt-9">
            <div className="flex flex-col items-center text-center">
              <span className="flex h-14 w-14 items-center justify-center rounded-xl bg-white/10 text-white ring-1 ring-white/15">
                <svg viewBox="0 0 24 24" className="h-7 w-7" {...line}>
                  <path d="M12 3l8 3.5v5c0 5-3.4 9.3-8 10.5C7.4 20.8 4 16.5 4 11.5v-5z" />
                  <path d="M9 12l2.2 2.2L15.5 10" />
                </svg>
              </span>

              <h1 className="mt-5 text-[20px] font-bold uppercase tracking-[0.14em] text-white">
                Admin Panel
              </h1>
              <p className="mt-1 text-[13px] text-white/45">FARMS control panel login</p>
            </div>

            {errors.form && (
              <div
                role="alert"
                className="mt-6 rounded-lg border border-red-400/30 bg-red-500/15 px-3.5 py-2.5 text-[13px] font-medium text-red-200"
              >
                {errors.form}
              </div>
            )}

            <form onSubmit={onSubmit} className="mt-7 space-y-5" noValidate>
              <div>
                <div className="flex items-center gap-3 border-b border-white/20 pb-2 transition focus-within:border-white/60">
                  <span className="text-blue-400">
                    <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
                      <circle cx="12" cy="7" r="4" />
                    </svg>
                  </span>
                  <span className="text-[14px] font-medium text-white/40">+63</span>
                  <input
                    type="tel"
                    inputMode="tel"
                    autoComplete="tel"
                    placeholder="917 123 4567"
                    aria-label="Mobile number"
                    aria-invalid={!!errors.phone}
                    value={phone}
                    onChange={(e) => {
                      setPhone(e.target.value)
                      setErrors((x) => ({ ...x, phone: null }))
                    }}
                    className="w-full bg-transparent text-[15px] text-white placeholder:text-white/25 focus:outline-none"
                  />
                </div>
                {errors.phone && (
                  <p className="mt-1.5 text-[12px] font-medium text-red-300">{errors.phone}</p>
                )}
              </div>

              <div>
                <div className="flex items-center gap-3 border-b border-white/20 pb-2 transition focus-within:border-white/60">
                  <span className="text-blue-400">
                    <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                      <circle cx="8" cy="14" r="4" />
                      <path d="M11 12l8-8 2 2-2 2 2 2-3 3-2-2-2 2" />
                    </svg>
                  </span>
                  <input
                    type={shown ? 'text' : 'password'}
                    autoComplete="current-password"
                    placeholder="Password"
                    aria-invalid={!!errors.password}
                    value={password}
                    onChange={(e) => {
                      setPassword(e.target.value)
                      setErrors((x) => ({ ...x, password: null }))
                    }}
                    className="w-full bg-transparent text-[15px] text-white placeholder:text-white/25 focus:outline-none"
                  />
                  <button
                    type="button"
                    onClick={() => setShown((v) => !v)}
                    aria-label={shown ? 'Hide password' : 'Show password'}
                    className="shrink-0 text-white/35 transition hover:text-white/80"
                  >
                    {shown ? (
                      <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                        <path d="M10.6 6.2A9.9 9.9 0 0 1 12 6c6.4 0 10 6 10 6a17 17 0 0 1-3 3.6M6.5 7.8A17 17 0 0 0 2 12s3.6 6 10 6a9.6 9.6 0 0 0 4-.8" />
                        <path d="M3 3l18 18" />
                      </svg>
                    ) : (
                      <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                        <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7z" />
                        <circle cx="12" cy="12" r="3" />
                      </svg>
                    )}
                  </button>
                </div>
                {errors.password && (
                  <p className="mt-1.5 text-[12px] font-medium text-red-300">{errors.password}</p>
                )}
              </div>

              <button
                type="submit"
                disabled={busy}
                className="mt-2 w-full rounded-full bg-amber-400 py-3 text-[15px] font-bold text-slate-900
                           shadow-[0_6px_18px_-6px_rgba(251,191,36,.7)] transition
                           hover:-translate-y-px hover:bg-amber-300 disabled:opacity-50"
              >
                {busy ? 'Signing in…' : 'Login'}
              </button>
            </form>

            <button
              onClick={onGoogle}
              disabled={busy}
              className="mt-4 flex w-full items-center justify-center gap-2.5 rounded-full border border-white/15
                         py-2.5 text-[13px] font-semibold text-white/70 transition
                         hover:border-white/35 hover:bg-white/5 hover:text-white disabled:opacity-50"
            >
              <svg width="15" height="15" viewBox="0 0 48 48" aria-hidden>
                <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.6l6.7-6.7C35.6 2.6 30.2 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.8 6.1C12.3 13.2 17.6 9.5 24 9.5z" />
                <path fill="#4285F4" d="M46.6 24.6c0-1.6-.1-3.2-.4-4.6H24v9.1h12.7c-.6 3-2.3 5.5-4.8 7.2l7.5 5.8c4.4-4.1 7.2-10.1 7.2-17.5z" />
                <path fill="#FBBC05" d="M10.4 28.7c-.5-1.5-.8-3-.8-4.7s.3-3.2.8-4.7l-7.8-6.1C1 16.4 0 20.1 0 24s1 7.6 2.6 10.8l7.8-6.1z" />
                <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.5-5.8c-2.1 1.4-4.8 2.3-8.4 2.3-6.4 0-11.7-3.7-13.6-9.8l-7.8 6.1C6.5 42.6 14.6 48 24 48z" />
              </svg>
              Continue with Google
            </button>
          </div>

          <svg
            className="relative z-0 -mt-10 block w-full"
            viewBox="0 0 400 150"
            preserveAspectRatio="none"
            aria-hidden
          >
            <path
              d="M0 92c48-30 96 6 144-4s96-52 144-30 76 34 112 22v70H0z"
              fill="#1e3a8a"
              opacity="0.55"
            />
            <path
              d="M0 108c52-24 88 10 140 2s92-40 140-24 84 30 120 20v44H0z"
              fill="#2547a8"
              opacity="0.8"
            />
            <path d="M0 124c56-20 96 8 148 0s96-30 148-16 76 20 104 14v28H0z" fill="#3b62e8" />
          </svg>
        </div>

        <div className="mt-6 flex flex-col items-center gap-2 text-center">
          <Link
            to="/admin/request"
            className="text-[13px] font-medium text-white/55 transition hover:text-white"
          >
            Need administrator access? Request it
          </Link>
          <Link
            to="/"
            className="text-[13px] font-medium text-white/40 transition hover:text-white/80"
          >
            Back to role selection
          </Link>
        </div>
      </div>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Dashboard.tsx' @'
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Empty, SectionHeading, Select, Spinner, Stat } from '@/components/ui'
import { MyFarmRank, TopFarms } from '@/components/TopFarms'
import { CROPS, CROP_EMOJI, peso, pesoShort, relativeDate, sacks, titleCase, weightNote } from '@/lib/format'
import type { Crop, InventoryItem } from '@/lib/types'

interface Snapshot {
  revenue: number
  schedules: number
  stock: Record<Crop, number>
  recent: InventoryItem[]
  openJobs: number
  pendingApps: number
}

export default function OwnerDashboard() {
  const { profile, farm } = useAuth()
  const [data, setData] = useState<Snapshot | null>(null)
  const [stockFilter, setStockFilter] = useState('all')

  useEffect(() => {
    if (!farm || !profile) return
    let alive = true

    ;(async () => {
      supabase.rpc('generate_harvest_reminders').then(({ error }) => {
        if (error) console.warn('Harvest reminders skipped:', error.message)
      })

      const [txns, scheds, inv, jobs] = await Promise.all([
        supabase.from('transactions').select('amount,type').eq('farm_id', farm.id).eq('type', 'income'),
        supabase.from('schedules').select('id').eq('farm_id', farm.id),
        supabase.from('inventory').select('*').eq('farm_id', farm.id).order('added_at', { ascending: false }),
        supabase.from('job_posts').select('id,status').eq('owner_id', profile.id),
      ])

      const jobIds = (jobs.data ?? []).map((j) => j.id)
      let pendingApps = 0
      if (jobIds.length) {
        const { count } = await supabase
          .from('job_applications')
          .select('id', { count: 'exact', head: true })
          .in('job_id', jobIds)
          .eq('status', 'pending')
        pendingApps = count ?? 0
      }

      const stock: Record<Crop, number> = { rice: 0, corn: 0, watermelon: 0 }
      for (const row of (inv.data ?? []) as InventoryItem[]) {
        stock[row.crop] += Math.floor(row.quantity)
      }

      if (!alive) return
      setData({
        revenue: (txns.data ?? []).reduce((s, t) => s + Number(t.amount), 0),
        schedules: scheds.data?.length ?? 0,
        stock,
        recent: ((inv.data ?? []) as InventoryItem[]).slice(0, 40),
        openJobs: (jobs.data ?? []).filter((j) => j.status === 'open').length,
        pendingApps,
      })
    })()

    return () => {
      alive = false
    }
  }, [farm?.id, profile?.id])

  if (!data) return <Spinner label="Loading your farm" />

  const shownStock = (
    stockFilter === 'all' ? data.recent : data.recent.filter((r) => r.crop === stockFilter)
  ).slice(0, 6)

  return (
    <div className="space-y-7">
      <div>
        <h1 className="text-[22px] font-bold">
          {greeting()}, {profile?.name.split(' ')[0]}
        </h1>
        <p className="mt-0.5 text-[13px] text-soil-600">{farm?.name}</p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Revenue" value={pesoShort(data.revenue)} accent="green" sub="All recorded income" />
        <Stat label="Active schedules" value={String(data.schedules)} sub="Planting plans" />
        <Stat label="Rice stock" value={sacks(data.stock.rice)} sub={weightNote(data.stock.rice)} />
        <Stat label="Corn stock" value={sacks(data.stock.corn)} sub={weightNote(data.stock.corn)} />
      </div>

      <div className="card flex items-center justify-between gap-4 px-5 py-4">
        <div>
          <p className="text-[11px] font-bold uppercase tracking-[0.08em] text-soil-400">Today</p>
          <p className="num mt-0.5 text-2xl font-bold">28°C</p>
          <p className="text-sm text-soil-600">Sunny — good drying weather</p>
        </div>
        <span className="text-4xl" aria-hidden>☀️</span>
      </div>

      <section>
        <SectionHeading
          action={
            <Link to="/owner/market" className="text-sm font-semibold text-brand-700 hover:underline">
              Sell stock
            </Link>
          }
        >
          Inventory
        </SectionHeading>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {CROPS.map((crop) => (
            <div key={crop} className="card flex items-center gap-4 px-4 py-4">
              <span className="text-3xl" aria-hidden>{CROP_EMOJI[crop]}</span>
              <div className="min-w-0">
                <p className="text-sm font-bold">{titleCase(crop)}</p>
                <p className="num text-xl font-bold leading-tight">{sacks(data.stock[crop])}</p>
                <p className="text-[12px] text-soil-400">{weightNote(data.stock[crop])}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section>
        <SectionHeading
          action={
            <div className="w-40">
              <Select
                label=""
                value={stockFilter}
                onChange={(e) => setStockFilter(e.target.value)}
                options={[
                  { value: 'all', label: 'All crops' },
                  ...CROPS.map((c) => ({
                    value: c,
                    label: `${CROP_EMOJI[c]} ${titleCase(c)}`,
                  })),
                ]}
              />
            </div>
          }
        >
          Recent stock added
        </SectionHeading>
        {shownStock.length === 0 ? (
          <Empty
            title={stockFilter === 'all' ? 'No stock recorded yet' : `No ${stockFilter} recorded`}
            body="Harvest entries appear here once you record them on the Calendar."
          />
        ) : (
          <ul className="card divide-y divide-soil-200/70">
            {shownStock.map((row) => (
              <li key={row.id} className="flex items-center justify-between gap-3 px-4 py-3">
                <span className="flex min-w-0 items-center gap-3">
                  <span className="text-xl" aria-hidden>{CROP_EMOJI[row.crop]}</span>
                  <span className="min-w-0">
                    <span className="block text-sm font-semibold">{titleCase(row.crop)}</span>
                    <span className="block text-[12px] text-soil-400">{relativeDate(row.added_at)}</span>
                  </span>
                </span>
                <span className="num shrink-0 text-sm font-bold text-brand-700">
                  +{sacks(row.quantity)} sacks
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <SectionHeading>Sales ranking</SectionHeading>
        <div className="space-y-3">
          <MyFarmRank days={7} />
          <TopFarms limit={5} highlightFarmId={farm?.id} showPeriodPicker={false} />
        </div>
      </section>

      <section>
        <SectionHeading
          action={
            <Link to="/owner/jobs" className="text-sm font-semibold text-brand-700 hover:underline">
              Manage jobs
            </Link>
          }
        >
          Hiring
        </SectionHeading>
        <div className="stagger grid grid-cols-2 gap-3">
          <Stat label="Open job posts" value={String(data.openJobs)} />
          <Stat
            label="Pending applications"
            value={String(data.pendingApps)}
            sub={data.pendingApps > 0 ? 'Waiting on your decision' : 'Nothing to review'}
          />
        </div>
      </section>
    </div>
  )
}

function greeting() {
  const h = new Date().getHours()
  if (h < 11) return 'Magandang umaga'
  if (h < 18) return 'Magandang hapon'
  return 'Magandang gabi'
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Calendar.tsx' @'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Dialog,
  Empty,
  Field,
  PesoInput,
  SackInput,
  Select,
  Spinner,
  Stat,
  TextArea,
  ViewToggle,
} from '@/components/ui'
import {
  CROPS,
  CROP_COLOR,
  CROP_EMOJI,
  SCHEDULE_LABEL,
  SEASON,
  VARIETIES,
  addDays,
  daysBetween,
  peso,
  sacks,
  shortDate,
  toSacks,
  suggestedCrops,
  titleCase,
  todayISO,
} from '@/lib/format'
import { friendlyError, validateRequired } from '@/lib/validation'
import type { Crop, Schedule } from '@/lib/types'

const ALLOW_EARLY_HARVEST_FOR_TESTING = true

const EXPENSE_CATEGORIES = [
  'Seeds',
  'Fertilizer',
  'Pesticides',
  'Labor',
  'Equipment',
  'Fuel',
  'Water',
  'Other',
]

export default function OwnerCalendar() {
  const { farm } = useAuth()
  const [cursor, setCursor] = useState(() => new Date())
  const [rows, setRows] = useState<Schedule[] | null>(null)
  const [view, setView] = useState<'calendar' | 'table'>('calendar')
  const [cropFilter, setCropFilter] = useState('all')
  const [varietyFilter, setVarietyFilter] = useState('all')
  const [adding, setAdding] = useState<string | null>(null)
  const [detail, setDetail] = useState<Schedule | null>(null)
  const [harvesting, setHarvesting] = useState<Schedule | null>(null)
  const [todayKey, setTodayKey] = useState(todayISO())

  useEffect(() => {
    const t = setInterval(() => {
      const now = todayISO()
      setTodayKey((prev) => (prev === now ? prev : now))
    }, 60000)
    return () => clearInterval(t)
  }, [])

  const load = useCallback(async () => {
    if (!farm) return
    const { data } = await supabase
      .from('schedules')
      .select('*')
      .eq('farm_id', farm.id)
      .order('planting_date', { ascending: false })
    setRows((data as Schedule[]) ?? [])
  }, [farm?.id])

  useEffect(() => {
    load()
  }, [load])

  const varieties = useMemo(
    () => [...new Set((rows ?? []).map((r) => r.variety).filter(Boolean))].sort(),
    [rows],
  )

  const filtered = useMemo(
    () =>
      (rows ?? []).filter((r) => {
        if (r.status === 'cancelled') return false
        if (cropFilter !== 'all' && r.crop !== cropFilter) return false
        if (varietyFilter !== 'all' && r.variety !== varietyFilter) return false
        return true
      }),
    [rows, cropFilter, varietyFilter],
  )

  if (!rows) return <Spinner label="Loading your calendar" />

  const monthKey = `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, '0')}`
  const suggestions = suggestedCrops(cursor.getMonth())
  const plantedThisMonth = filtered.filter((r) => (r.planting_date ?? '').startsWith(monthKey))
  const todayIso = todayKey
  const dueSoon = filtered.filter(
    (r) =>
      r.status !== 'harvested' &&
      r.harvest_date &&
      r.harvest_date >= todayIso &&
      daysBetween(todayIso, r.harvest_date) <= 14,
  )

  return (
    <div className="animate-fade-up space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[26px] font-bold">Planting calendar</h1>
          <p className="mt-1 text-[14px] text-soil-600">
            Plan each planting, follow it to harvest, then send it straight to the market.
          </p>
        </div>
        <button
          className="btn-primary px-5 py-3 text-[15px]"
          onClick={() => setAdding(todayISO())}
        >
          Add planting
        </button>
      </div>

      {dueSoon.length > 0 && (
        <div className="rounded-xl border border-amber-300 bg-amber-50 px-5 py-4">
          <p className="text-[15px] font-bold text-amber-900">Harvest coming up</p>
          <ul className="mt-2 space-y-1">
            {dueSoon.map((r) => (
              <li key={r.id} className="text-[14px] text-amber-800">
                <span className="font-semibold">
                  {CROP_EMOJI[r.crop]} {r.variety || titleCase(r.crop)}
                </span>{' '}
                is due {shortDate(r.harvest_date)} — about{' '}
                <span className="num font-semibold">{sacks(r.expected_sacks)}</span> sacks.
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex flex-wrap items-end gap-3">
        <Select
          label="Crop"
          className="w-44"
          value={cropFilter}
          onChange={(e) => setCropFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All crops' },
            ...CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` })),
          ]}
        />
        <Select
          label="Variety"
          className="w-52"
          value={varietyFilter}
          onChange={(e) => setVarietyFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All varieties' },
            ...varieties.map((v) => ({ value: v, label: v })),
          ]}
        />
        <div className="ml-auto">
          <ViewToggle
            view={view === 'calendar' ? 'grid' : 'table'}
            onChange={(v) => setView(v === 'grid' ? 'calendar' : 'table')}
          />
        </div>
      </div>

      {view === 'calendar' ? (
        <CalendarView
          cursor={cursor}
          setCursor={setCursor}
          rows={filtered}
          suggestions={suggestions}
          plantedThisMonth={plantedThisMonth}
          onOpen={setDetail}
          onPlant={setAdding}
          today={todayKey}
        />
      ) : (
        <TableView rows={filtered} onOpen={setDetail} onHarvest={setHarvesting} />
      )}

      <AddPlantingDialog
        date={adding}
        onClose={() => setAdding(null)}
        farmId={farm?.id ?? ''}
        existing={rows}
        onSaved={() => {
          setAdding(null)
          load()
        }}
      />

      <DetailDialog
        schedule={harvesting}
        startInHarvest
        onClose={() => setHarvesting(null)}
        onChanged={() => {
          setHarvesting(null)
          load()
        }}
      />

      <DetailDialog
        schedule={detail}
        onClose={() => setDetail(null)}
        onChanged={() => {
          setDetail(null)
          load()
        }}
      />
    </div>
  )
}

function CalendarView({
  cursor,
  setCursor,
  rows,
  suggestions,
  plantedThisMonth,
  onOpen,
  onPlant,
  today,
}: {
  cursor: Date
  setCursor: (d: Date) => void
  rows: Schedule[]
  suggestions: Crop[]
  plantedThisMonth: Schedule[]
  onOpen: (s: Schedule) => void
  onPlant: (iso: string) => void
  today: string
}) {
  const year = cursor.getFullYear()
  const month = cursor.getMonth()
  const firstDay = new Date(year, month, 1).getDay()
  const days = new Date(year, month + 1, 0).getDate()
  const cells: (number | null)[] = [
    ...Array(firstDay).fill(null),
    ...Array.from({ length: days }, (_, i) => i + 1),
  ]

  const plantedCrops = (key: string): Crop[] =>
    rows.filter((r) => r.planting_date === key).map((r) => r.crop)
  return (
    <div className="space-y-4">
      <div className="grid gap-3 lg:grid-cols-2">
        <div className="card p-5">
          <h3 className="text-[15px] font-bold">
            Good to plant in {cursor.toLocaleDateString('en-PH', { month: 'long' })}
          </h3>
          {suggestions.length === 0 ? (
            <p className="mt-2 text-[14px] leading-relaxed text-soil-600">
              None of the three crops is in its usual planting window this month.
            </p>
          ) : (
            <ul className="mt-3 space-y-2">
              {suggestions.map((c) => (
                <li
                  key={c}
                  className={`flex items-center gap-3 rounded-lg px-3 py-2.5 ${CROP_COLOR[c].soft}`}
                >
                  <span className="text-2xl">{CROP_EMOJI[c]}</span>
                  <span>
                    <span className={`block text-[14px] font-bold ${CROP_COLOR[c].text}`}>
                      {titleCase(c)}
                    </span>
                    <span className="block text-[12px] text-soil-600">In season this month</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="card p-5">
          <h3 className="text-[15px] font-bold">This month's plantings</h3>
          {plantedThisMonth.length === 0 ? (
            <p className="mt-2 text-[14px] text-soil-600">Nothing planted this month yet.</p>
          ) : (
            <>
              <p className="mt-1 text-[13px] text-soil-600">
                You already have {plantedThisMonth.length} planting
                {plantedThisMonth.length === 1 ? '' : 's'} recorded this month.
              </p>
              <ul className="mt-3 space-y-2">
                {plantedThisMonth.map((r) => (
                  <li key={r.id}>
                    <button
                      onClick={() => onOpen(r)}
                      className="flex w-full items-center justify-between gap-3 rounded-lg border border-soil-200 px-3 py-2.5 text-left transition hover:bg-soil-50"
                    >
                      <span className="min-w-0">
                        <span className="block truncate text-[14px] font-semibold">
                          {CROP_EMOJI[r.crop]} {r.variety || titleCase(r.crop)}
                        </span>
                        <span className="block text-[12px] text-soil-400">
                          Harvest {shortDate(r.harvest_date)}
                        </span>
                      </span>
                      <span className="num shrink-0 text-[13px] font-bold">
                        {sacks(r.expected_sacks)} sacks
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
      </div>

      <div className="card p-4 sm:p-6">
        <div className="mb-5 flex items-center justify-between">
          <button
            className="rounded-lg p-2.5 text-soil-600 transition hover:bg-soil-100"
            aria-label="Previous month"
            onClick={() => setCursor(new Date(year, month - 1, 1))}
          >
            <Chevron dir="left" />
          </button>
          <h2 className="text-[20px] font-bold">
            {cursor.toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
          </h2>
          <button
            className="rounded-lg p-2.5 text-soil-600 transition hover:bg-soil-100"
            aria-label="Next month"
            onClick={() => setCursor(new Date(year, month + 1, 1))}
          >
            <Chevron dir="right" />
          </button>
        </div>

        <div className="mb-4 flex flex-wrap items-center gap-x-5 gap-y-2 border-b border-soil-200 pb-4 text-[13px]">
          <span className="flex items-center gap-3">
            <span className="flex h-2.5 w-16 overflow-hidden rounded-full bg-soil-100">
              {CROPS.map((c) => (
                <span key={c} className={`h-full flex-1 ${CROP_COLOR[c].bar}`} />
              ))}
            </span>
            <span className="text-soil-500">Best to plant this month</span>
          </span>

          {CROPS.map((c) => (
            <span key={c} className="flex items-center gap-2">
              <span className={`h-3 w-3 rounded-sm ${CROP_COLOR[c].dot}`} />
              <span className="font-semibold">{titleCase(c)}</span>
            </span>
          ))}
          <span className="ml-auto flex items-center gap-3 text-soil-400">
            <span>🌱 Planting date</span>
            <span>🌾 Expected harvest</span>
          </span>
        </div>

        <div className="grid grid-cols-7 gap-1.5 text-center sm:gap-2">
          {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map((d) => (
            <div
              key={d}
              className="pb-2 text-[11px] font-semibold uppercase tracking-[0.08em] text-soil-400"
            >
              <span className="hidden sm:inline">{d}</span>
              <span className="sm:hidden">{d[0]}</span>
            </div>
          ))}

          {cells.map((day, i) => {
            if (!day) return <div key={i} className="min-h-[6rem] sm:min-h-[7.5rem]" />
            const iso = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`
            const plantedHere = rows.filter((r) => r.planting_date === iso)
            const harvestsHere = rows.filter(
              (r) => r.harvest_date === iso && r.planting_date !== iso,
            )
            const isToday = iso === today
            const isPast = iso < today

            return (
              <div
                key={i}
                className={`group relative flex min-h-[6.5rem] flex-col rounded-lg border p-2 text-left transition sm:min-h-[8rem] ${
                  isToday
                    ? 'border-brand-600 bg-white ring-1 ring-brand-600'
                    : isPast
                      ? 'border-soil-200/70 bg-soil-50/40'
                      : 'border-soil-200 bg-white hover:border-soil-300'
                }`}
              >
                <span
                  className={`num text-[13px] font-bold sm:text-[15px] ${
                    isToday ? 'text-brand-700' : isPast ? 'text-soil-400' : 'text-soil-800'
                  }`}
                >
                  {day}
                </span>

                <SeasonBar suggestions={suggestions} />

                {plantedHere.length > 0 && (
                  <span className="mt-1 flex flex-col gap-1">
                    {plantedHere.map((r) => {
                      const total =
                        r.planting_date && r.harvest_date
                          ? Math.max(1, daysBetween(r.planting_date, r.harvest_date))
                          : 1
                      const done =
                        r.status === 'harvested'
                          ? total
                          : Math.min(Math.max(daysBetween(r.planting_date!, today), 0), total)
                      const pct = Math.round((done / total) * 100)

                      return (
                        <button
                          key={r.id}
                          onClick={() => onOpen(r)}
                          title={`${r.variety || titleCase(r.crop)} — ${pct}% grown`}
                          className="relative block overflow-hidden rounded bg-soil-100 text-left"
                        >
                          <span
                            aria-hidden
                            className={`absolute inset-y-0 left-0 ${CROP_COLOR[r.crop].bar}`}
                            style={{ width: `${Math.max(pct, 12)}%` }}
                          />
                          <span
                            className={`relative flex items-center gap-1 px-1.5 py-1 text-[10px] font-semibold ${
                              pct > 55 ? 'text-white' : 'text-soil-800'
                            }`}
                          >
                            <span className="truncate">{r.variety || titleCase(r.crop)}</span>
                            <span className="num ml-auto shrink-0 opacity-90">{pct}%</span>
                          </span>
                        </button>
                      )
                    })}
                  </span>
                )}

                {harvestsHere.length > 0 && (
                  <span className="mt-1 flex flex-col gap-1">
                    {harvestsHere.map((r) => (
                      <button
                        key={r.id + 'h'}
                        onClick={() => onOpen(r)}
                        title={`Expected harvest: ${r.variety || titleCase(r.crop)} — ${sacks(
                          r.expected_sacks,
                        )} sacks`}
                        className={`block truncate rounded px-1.5 py-1 text-left text-[10px] font-semibold ${
                          CROP_COLOR[r.crop].chip
                        }`}
                      >
                        🌾 {r.variety || titleCase(r.crop)}
                      </button>
                    ))}
                  </span>
                )}


                {!isPast && (
                  <button
                    onClick={() => onPlant(iso)}
                    aria-label={`Plan a planting on ${iso}`}
                    className="mt-auto w-full rounded-md border border-dashed border-soil-300 py-1
                               text-[10px] font-medium text-soil-400 opacity-0 transition
                               hover:border-brand-600 hover:bg-brand-50 hover:text-brand-700
                               focus-visible:opacity-100 group-hover:opacity-100 sm:text-[11px]"
                  >
                    {isToday ? '+ Plant' : '+ Schedule'}
                  </button>
                )}
              </div>
            )
          })}
        </div>

      </div>

    </div>
  )
}

function SeasonBar({ suggestions }: { suggestions: Crop[] }) {
  const inSeason = CROPS.filter((c) => suggestions.includes(c))

  return (
    <span
      className="mt-1.5 flex h-2 overflow-hidden rounded-full bg-soil-100"
      title={
        inSeason.length === 0
          ? 'No crop is in its usual planting season this month'
          : `Good to plant: ${inSeason.map(titleCase).join(', ')}`
      }
    >
      {CROPS.map((c) => (
        <span
          key={c}
          className={`h-full ${inSeason.includes(c) ? CROP_COLOR[c].bar : ''}`}
          style={{ width: `${100 / CROPS.length}%` }}
        />
      ))}
    </span>
  )
}

function TableView({
  rows,
  onOpen,
  onHarvest,
}: {
  rows: Schedule[]
  onOpen: (s: Schedule) => void
  onHarvest: (s: Schedule) => void
}) {
  const [anchor, setAnchor] = useState(() => new Date())

  const year = anchor.getFullYear()
  const month = anchor.getMonth()
  const total = new Date(year, month + 1, 0).getDate()
  const days = Array.from({ length: total }, (_, i) => new Date(year, month, i + 1))

  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

  const todayIso = todayISO()

  function plantedCrops(key: string): Crop[] {
    return rows.filter((r) => r.planting_date === key).map((r) => r.crop)
  }

  function eventsOn(d: Date) {
    const key = iso(d)
    return rows
      .filter((r) => r.planting_date === key || r.harvest_date === key)
      .map((r) => ({
        row: r,
        kind: r.planting_date === key ? ('plant' as const) : ('harvest' as const),
      }))
  }

  return (
    <div className="card overflow-hidden">
      <div className="flex items-center gap-2 border-b border-soil-200 px-4 py-3">
        <button
          className="btn-sm border border-soil-200 hover:bg-soil-100"
          onClick={() => setAnchor(new Date())}
        >
          Today
        </button>
        <button
          className="rounded-lg p-1.5 text-soil-600 hover:bg-soil-100"
          aria-label="Previous month"
          onClick={() => setAnchor(new Date(year, month - 1, 1))}
        >
          <Chevron dir="left" />
        </button>
        <button
          className="rounded-lg p-1.5 text-soil-600 hover:bg-soil-100"
          aria-label="Next month"
          onClick={() => setAnchor(new Date(year, month + 1, 1))}
        >
          <Chevron dir="right" />
        </button>
        <h2 className="ml-1 text-[18px] font-bold">
          {anchor.toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
        </h2>
      </div>

      <div className="max-h-[36rem] overflow-y-auto">
        {days.map((d) => {
          const key = iso(d)
          const events = eventsOn(d)
          const isToday = key === todayIso
          const isPast = key < todayIso
          const weekend = d.getDay() === 0 || d.getDay() === 6

          return (
            <div
              key={key}
              className={`grid grid-cols-[5rem_1fr] border-b border-soil-200/70 last:border-b-0 ${
                isToday ? 'bg-brand-50' : weekend ? 'bg-soil-50/50' : ''
              }`}
            >
              <div className="flex items-start justify-end gap-2 px-3 py-2.5 text-right">
                <span
                  className={`text-[11px] font-semibold uppercase ${
                    isToday ? 'text-brand-700' : 'text-soil-400'
                  }`}
                >
                  {d.toLocaleDateString('en-PH', { weekday: 'short' })}
                </span>
                <span
                  className={`num flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-[15px] font-semibold ${
                    isToday
                      ? 'bg-brand-600 text-white'
                      : isPast
                        ? 'text-soil-400'
                        : 'text-soil-800'
                  }`}
                >
                  {d.getDate()}
                </span>
              </div>

              <div className="min-h-[3rem] space-y-1 border-l border-soil-200 px-2 py-2">
                {events.length === 0 ? (
                  <span className="block h-full" />
                ) : (
                  events.map(({ row, kind }) => {
                    const c = CROP_COLOR[row.crop]
                    const total =
                      row.planting_date && row.harvest_date
                        ? Math.max(1, daysBetween(row.planting_date, row.harvest_date))
                        : 0
                    const elapsed =
                      row.planting_date && total
                        ? Math.min(Math.max(daysBetween(row.planting_date, todayIso), 0), total)
                        : 0
                    const done = row.status === 'harvested'
                    const pct = done ? 100 : total ? Math.round((elapsed / total) * 100) : 0
                    const left = Math.max(total - elapsed, 0)

                    return (
                      <button
                        key={row.id + kind}
                        onClick={() => onOpen(row)}
                        title={[
                          `${row.variety || titleCase(row.crop)} (${titleCase(row.crop)})`,
                          `Planted: ${shortDate(row.planting_date)}`,
                          `Expected harvest: ${shortDate(row.harvest_date)}`,
                          `Expected sacks: ${sacks(row.expected_sacks)}`,
                          done
                            ? 'Harvested'
                            : `${pct}% grown - day ${elapsed} of ${total}, ${left} days left`,
                        ].join('\n')}
                        className="relative block w-full overflow-hidden rounded border border-soil-200 bg-soil-100 text-left transition hover:shadow-sm"
                      >
                        <span
                          aria-hidden
                          className={`absolute inset-y-0 left-0 transition-all duration-500 ${c.bar}`}
                          style={{ width: `${Math.max(pct, 6)}%` }}
                        />

                        <span className="relative flex items-center gap-2 px-2.5 py-1.5">
                          <span className="text-[13px]">{kind === 'plant' ? '🌱' : '🌾'}</span>
                          <span
                            className={`truncate text-[13px] font-semibold ${
                              pct > 18 ? 'text-white' : 'text-soil-800'
                            }`}
                          >
                            {kind === 'plant' ? 'Planted' : 'Expected harvest'} ·{' '}
                            {row.variety || titleCase(row.crop)}
                          </span>

                          <span
                            className={`num ml-auto shrink-0 text-[12px] font-semibold ${
                              pct > 88 ? 'text-white' : 'text-soil-600'
                            }`}
                          >
                            {done
                              ? `Harvested · ${sacks(row.actual_sacks ?? 0)} sacks`
                              : `${pct}%`}
                          </span>

                          {!done && (pct >= 100 || ALLOW_EARLY_HARVEST_FOR_TESTING) && (
                            <span
                              onClick={(ev) => {
                                ev.stopPropagation()
                                onHarvest(row)
                              }}
                              role="button"
                              tabIndex={0}
                              onKeyDown={(ev) => {
                                if (ev.key === 'Enter' || ev.key === ' ') {
                                  ev.preventDefault()
                                  ev.stopPropagation()
                                  onHarvest(row)
                                }
                              }}
                              className={`shrink-0 cursor-pointer rounded px-2.5 py-1 text-[11px] font-bold uppercase tracking-wide text-white shadow-sm transition ${
                                pct >= 100
                                  ? 'bg-green-600 hover:bg-green-700'
                                  : 'bg-red-600 hover:bg-red-700'
                              }`}
                            >
                              {pct >= 100 ? 'Harvest' : 'Harvest now'}
                            </span>
                          )}
                        </span>
                      </button>
                    )
                  })
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function AddPlantingDialog({
  date,
  onClose,
  farmId,
  existing,
  onSaved,
}: {
  date: string | null
  onClose(): void
  farmId: string
  existing: Schedule[]
  onSaved(): void
}) {
  const open = date !== null
  const today = todayISO()
  const [form, setForm] = useState({
    crop: 'rice' as Crop,
    variety: '',
    customVariety: '',
    seed_kg: '',
    note: '',
  })

  useEffect(() => {
    if (!date) return
    setForm({ crop: 'rice', variety: '', customVariety: '', seed_kg: '', note: '' })
    setErrors({})
  }, [date])
  const [estimate, setEstimate] = useState<{
    expected_sacks: number
    expected_kg: number
    days_to_harvest: number
  } | null>(null)
  const [land, setLand] = useState<{ hectares: number; sqm: number; kg_per_hectare: number } | null>(
    null,
  )
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  const chosenVariety =
    form.variety === '__other' ? form.customVariety.trim() : form.variety.trim()

  useEffect(() => {
    if (!open) return
    const seed = Number(form.seed_kg || 0)
    if (seed <= 0) {
      setEstimate(null)
      return
    }
    let alive = true
    supabase
      .rpc('estimate_harvest', {
        p_crop: form.crop,
        p_variety: chosenVariety,
        p_seed_kg: seed,
      })
      .then(({ data }) => {
        if (alive) setEstimate(data as any)
      })

    supabase
      .rpc('land_needed', {
        p_crop: form.crop,
        p_variety: chosenVariety,
        p_seed_kg: seed,
      })
      .then(({ data }) => {
        if (alive) setLand(data as any)
      })
    return () => {
      alive = false
    }
  }, [open, form.crop, chosenVariety, form.seed_kg])

  const plantingDate = date ?? today
  const harvestDate = estimate ? addDays(plantingDate, estimate.days_to_harvest) : null

  const mergeInto = existing.find(
    (r) =>
      r.status !== 'cancelled' &&
      r.crop === form.crop &&
      r.planting_date === plantingDate &&
      (r.variety || '').trim().toLowerCase() === chosenVariety.toLowerCase() &&
      chosenVariety !== '',
  )

  const monthIndex = new Date(plantingDate).getMonth()
  const offSeason = !SEASON[form.crop].includes(monthIndex)
  const monthName = new Date(plantingDate).toLocaleDateString('en-PH', { month: 'long' })
  const goodMonths = SEASON[form.crop]
    .map((m) => new Date(2000, m, 1).toLocaleDateString('en-PH', { month: 'short' }))
    .join(', ')
  const month = plantingDate.slice(0, 7)

  const sameDay = existing.filter(
    (r) => r.status !== 'cancelled' && r.planting_date === plantingDate,
  )

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      variety: form.variety ? null : 'Choose a variety.',
      customVariety:
        form.variety === '__other'
          ? validateRequired(form.customVariety, 'Variety name')
          : null,
      seed_kg: Number(form.seed_kg) > 0 ? null : 'Enter the seed weight in kilograms.',
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    const { data, error } = await supabase.rpc('add_or_merge_planting', {
      p_farm_id: farmId,
      p_crop: form.crop,
      p_variety: chosenVariety,
      p_planting_date: plantingDate,
      p_seed_kg: Number(form.seed_kg),
      p_note: form.note.trim(),
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }

    const result = data as { merged?: boolean; seed_kg?: number } | null
    toast.success(
      result?.merged
        ? `Merged into your existing ${chosenVariety} planting — now ${result.seed_kg} kg of seed`
        : plantingDate > today
          ? 'Planting scheduled'
          : 'Planting added to your calendar',
    )
    onSaved()
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={date && date > today ? 'Schedule a planting' : 'Plan a planting'}
      description={
        date
          ? new Date(date).toLocaleDateString('en-PH', {
              weekday: 'long',
              day: 'numeric',
              month: 'long',
              year: 'numeric',
            })
          : undefined
      }
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Saving…' : 'Add planting'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        {offSeason && (
          <div className="flex gap-3 rounded-lg border border-amber-300 bg-amber-50 px-3.5 py-3">
            <span className="shrink-0 text-lg" aria-hidden>
              ⚠️
            </span>
            <span>
              <span className="block text-[13px] font-bold text-amber-900">
                {monthName} is not the usual season for {titleCase(form.crop)}
              </span>
              <span className="mt-0.5 block text-[13px] leading-relaxed text-amber-800">
                {titleCase(form.crop)} is normally planted in {goodMonths}. Planting outside these
                months can mean lower yield or more pests, so the estimate may be optimistic. You
                can still schedule it.
              </span>
            </span>
          </div>
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => {
              set('crop', e.target.value)
              set('variety', '')
            }}
            options={CROPS.map((c) => ({
              value: c,
              label: `${CROP_EMOJI[c]} ${titleCase(c)}`,
            }))}
          />
          <Select
            label="Variety"
            value={form.variety}
            error={errors.variety}
            onChange={(e) => set('variety', e.target.value)}
            options={[
              { value: '', label: 'Choose a variety…' },
              ...VARIETIES[form.crop].map((v) => ({ value: v, label: v })),
              { value: '__other', label: 'Other (not on the list)' },
            ]}
          />
        </div>

        {form.variety === '__other' && (
          <Field
            label="Name the variety you are planting"
            placeholder="Type the exact variety, e.g. Ifugao Tinawon"
            value={form.customVariety}
            error={errors.customVariety}
            onChange={(e) => set('customVariety', e.target.value)}
          />
        )}

        {mergeInto && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-3.5 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              You already planted {chosenVariety} on this date
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
              This seed is added to that planting, taking it from{' '}
              <span className="num font-semibold">{mergeInto.seed_kg} kg</span> to{' '}
              <span className="num font-semibold">
                {Number(mergeInto.seed_kg) + Number(form.seed_kg || 0)} kg
              </span>
              . No second entry or progress bar is created.
            </p>
          </div>
        )}


        <div className="flex items-center gap-3 rounded-lg bg-brand-50 px-4 py-3">
          <span className="text-xl">🌱</span>
          <span>
            <span className="block text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
              {plantingDate > today ? 'Scheduled planting date' : 'Planting date'}
            </span>
            <span className="num block text-[15px] font-bold text-brand-900">
              {shortDate(plantingDate)}
            </span>
            {plantingDate > today && (
              <span className="block text-[11px] text-brand-900/70">
                In {daysBetween(today, plantingDate)} day
                {daysBetween(today, plantingDate) === 1 ? '' : 's'}
              </span>
            )}
          </span>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            label="Seed used (kg)"
            type="number"
            min="0"
            step="0.5"
            inputMode="decimal"
            placeholder="e.g. 40"
            value={form.seed_kg}
            error={errors.seed_kg}
            onChange={(e) => set('seed_kg', e.target.value)}
          />
        </div>

        {sameDay.length > 0 && (
          <p className="rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px] leading-relaxed text-soil-600">
            You already have {sameDay.length} planting{sameDay.length === 1 ? '' : 's'} on this
            date. Adding another is fine if it is a different plot.
          </p>
        )}

        {estimate && (
          <div className="rounded-xl bg-brand-50 px-4 py-3.5">
            <p className="text-center text-[13px] font-bold text-brand-900">Expected harvest</p>
            <div className="mt-3 rounded-lg bg-white/70 px-4 py-3 text-center">
              <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                Expected harvest date
              </p>
              <p className="num mt-0.5 text-[20px] font-bold text-brand-900">
                {shortDate(harvestDate)}
              </p>
              <p className="mt-0.5 text-[11px] text-brand-900/60">
                {estimate.days_to_harvest} days after planting
              </p>
            </div>

            <dl className="mt-3 grid grid-cols-2 gap-3">
              <div className="rounded-lg bg-white/70 px-3 py-2.5 text-center">
                <dt className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                  Sacks
                </dt>
                <dd className="num text-[19px] font-bold text-brand-900">
                  {sacks(estimate.expected_sacks)}
                </dd>
              </div>
              <div className="rounded-lg bg-white/70 px-3 py-2.5 text-center">
                <dt className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                  Weight
                </dt>
                <dd className="num text-[19px] font-bold text-brand-900">
                  {Math.round(estimate.expected_kg)} kg
                </dd>
              </div>
            </dl>
          </div>
        )}

        <TextArea
          label="Note"
          max={200}
          rows={2}
          placeholder="Optional"
          value={form.note}
          onChange={(e) => set('note', e.target.value)}
        />
      </form>
    </Dialog>
  )
}

function DetailDialog({
  schedule,
  onClose,
  onChanged,
  startInHarvest = false,
}: {
  schedule: Schedule | null
  onClose(): void
  onChanged(): void
  startInHarvest?: boolean
}) {
  const [mode, setMode] = useState<'view' | 'harvest' | 'cost' | 'cancel'>('view')
  const [cancelReason, setCancelReason] = useState('')
  const [actual, setActual] = useState('')
  const [category, setCategory] = useState(EXPENSE_CATEGORIES[0])
  const [amount, setAmount] = useState('')
  const [spent, setSpent] = useState(0)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!schedule) return
    setMode(startInHarvest ? 'harvest' : 'view')
    setCancelReason('')
    setActual(schedule.actual_sacks != null ? String(schedule.actual_sacks) : '')
    setAmount('')
    supabase
      .from('transactions')
      .select('amount')
      .eq('schedule_id', schedule.id)
      .then(({ data }) => setSpent((data ?? []).reduce((s, t: any) => s + Number(t.amount), 0)))
  }, [schedule?.id])

  if (!schedule) return null
  const c = CROP_COLOR[schedule.crop]

  async function doHarvest() {
    setBusy(true)
    const { error } = await supabase.rpc('harvest_schedule', {
      p_schedule_id: schedule!.id,
      p_actual_sacks: parseInt(actual || '0', 10),
      p_price: null,
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Harvest recorded — list it on the Market when you are ready to sell')
    onChanged()
  }

  async function doCancel() {
    setBusy(true)
    const { error } = await supabase.rpc('cancel_schedule', {
      p_schedule_id: schedule!.id,
      p_reason: cancelReason.trim(),
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Planting cancelled')
    onChanged()
  }

  async function doCost() {
    if (!amount || Number(amount) <= 0) {
      toast.error('Enter the amount spent.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('add_crop_expense', {
      p_schedule_id: schedule!.id,
      p_category: category,
      p_amount: Number(amount),
      p_description: '',
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Cost recorded against this crop')
    onChanged()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={schedule.variety || titleCase(schedule.crop)}
      description={`${titleCase(schedule.crop)} · ${SCHEDULE_LABEL[schedule.status]}`}
      footer={
        mode === 'view' ? undefined : (
          <>
            <button className="btn-ghost" onClick={() => setMode('view')}>
              Back
            </button>
            <button
              className={mode === 'cancel' ? 'btn-danger' : 'btn-primary'}
              onClick={mode === 'harvest' ? doHarvest : mode === 'cancel' ? doCancel : doCost}
              disabled={busy}
            >
              {busy
                ? 'Saving…'
                : mode === 'harvest'
                  ? 'Save harvest'
                  : mode === 'cancel'
                    ? 'Cancel planting'
                    : 'Save cost'}
            </button>
          </>
        )
      }
    >
      {mode === 'view' && (
        <div className="space-y-4">
          <div className={`rounded-xl px-4 py-3.5 ${c.soft}`}>
            <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-[14px]">
              <Row label="Crop" value={`${CROP_EMOJI[schedule.crop]} ${titleCase(schedule.crop)}`} />
              <Row label="Variety" value={schedule.variety || '—'} />
              <Row label="Planting date" value={shortDate(schedule.planting_date)} />
              <Row label="Expected harvest" value={shortDate(schedule.harvest_date)} />
              <Row
                label="Days to harvest"
                value={
                  schedule.planting_date && schedule.harvest_date
                    ? `${daysBetween(schedule.planting_date, schedule.harvest_date)} days`
                    : '—'
                }
              />
              <Row label="Seed used" value={`${schedule.seed_kg} kg`} />
              <Row label="Expected sacks" value={`${sacks(schedule.expected_sacks)} sacks`} />
              <Row label="Expected weight" value={`${schedule.expected_sacks * 25} kg`} />
              {schedule.actual_sacks != null && (
                <>
                  <Row label="Actual harvest" value={`${sacks(schedule.actual_sacks)} sacks`} />
                  <Row
                    label="Harvested on"
                    value={shortDate(schedule.harvested_at ?? schedule.harvest_date)}
                  />
                </>
              )}
              <Row label="Costs so far" value={peso(spent)} />
            </dl>
          </div>

          {schedule.note && (
            <p className="rounded-lg bg-soil-50 px-3.5 py-3 text-[14px] leading-relaxed text-soil-700">
              {schedule.note}
            </p>
          )}

          {schedule.listed_product_id && (
            <p className="rounded-lg border border-green-200 bg-green-50 px-3.5 py-3 text-[13px] font-medium text-green-800">
              This harvest is listed on the market.
            </p>
          )}

          {schedule.status === 'harvested' ? (
            <div className="border-t border-soil-200 pt-4">
              <span className="flex items-center justify-center rounded-lg bg-green-100 py-2 text-[13px] font-semibold text-green-800">
                Harvested — no further costs can be added
              </span>
            </div>
          ) : (
            <div className="space-y-2 border-t border-soil-200 pt-4">
              <div className="grid grid-cols-2 gap-2">
                <button className="btn-ghost py-2 text-[13px]" onClick={() => setMode('cost')}>
                  Add cost
                </button>
                <button className="btn-primary py-2 text-[13px]" onClick={() => setMode('harvest')}>
                  Record harvest
                </button>
              </div>
              <button
                className="btn-ghost w-full py-2 text-[13px] text-red-600 hover:bg-red-50"
                onClick={() => setMode('cancel')}
              >
                Cancel this planting
              </button>
            </div>
          )}
        </div>
      )}

      {mode === 'harvest' && (
        <div className="space-y-4">
          {(() => {
            const total =
              schedule.planting_date && schedule.harvest_date
                ? Math.max(1, daysBetween(schedule.planting_date, schedule.harvest_date))
                : 0
            const done = schedule.planting_date
              ? Math.min(Math.max(daysBetween(schedule.planting_date, todayISO()), 0), total)
              : 0
            const pct = total ? Math.round((done / total) * 100) : 0
            if (pct >= 100) return null

            return (
              <div className="flex gap-3 rounded-lg border border-amber-300 bg-amber-50 px-3.5 py-3">
                <span className="shrink-0 text-lg" aria-hidden>
                  ⚠️
                </span>
                <span>
                  <span className="block text-[13px] font-bold text-amber-900">
                    This crop has not reached full growth
                  </span>
                  <span className="mt-0.5 block text-[13px] leading-relaxed text-amber-800">
                    It is {pct}% grown, with {total - done} day{total - done === 1 ? '' : 's'} left
                    until {shortDate(schedule.harvest_date)}. Harvesting early usually means fewer
                    and lighter sacks than the estimate.
                  </span>
                </span>
              </div>
            )
          })()}

          <p className="text-[14px] leading-relaxed text-soil-700">
            Enter what you actually harvested.
          </p>
          <SackInput
            label="Exact sacks harvested"
            min={0}
            value={actual}
            hint={`Estimate was ${sacks(schedule.expected_sacks)} sacks — enter what you really got`}
            onChange={(e) => setActual(e.target.value)}
          />

          {/^\d+$/.test(actual) && (
            <dl className="space-y-1 rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px]">
              <div className="flex justify-between gap-3">
                <dt className="text-soil-600">Estimated</dt>
                <dd className="num">{sacks(schedule.expected_sacks)} sacks</dd>
              </div>
              <div className="flex justify-between gap-3 border-t border-soil-200 pt-1">
                <dt className="font-semibold">Actual harvest</dt>
                <dd className="num font-bold text-brand-700">{sacks(actual)} sacks</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-soil-600">Difference</dt>
                <dd
                  className={`num font-semibold ${
                    toSacks(actual) >= schedule.expected_sacks ? 'text-green-700' : 'text-red-600'
                  }`}
                >
                  {toSacks(actual) - schedule.expected_sacks > 0 ? '+' : ''}
                  {toSacks(actual) - schedule.expected_sacks} sacks
                </dd>
              </div>
            </dl>
          )}
          <p className="rounded-lg bg-soil-50 px-3.5 py-3 text-[13px] leading-relaxed text-soil-600">
            This goes into your inventory. To sell it, open Market and add a listing with the
            number of sacks and the price you want.
          </p>
        </div>
      )}

      {mode === 'cancel' && (
        <div className="space-y-4">
          <p className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-[14px] leading-relaxed text-amber-900">
            This removes the planting from your calendar. Use it when something was scheduled ahead
            and never went into the ground. Costs already recorded against it stay in Finance.
          </p>
          <TextArea
            label="Why is it being cancelled?"
            max={200}
            placeholder="Optional"
            value={cancelReason}
            onChange={(e) => setCancelReason(e.target.value)}
          />
        </div>
      )}

      {mode === 'cancel' && (
        <div className="space-y-4">
          <p className="text-[14px] leading-relaxed text-soil-800">
            The planting is closed and comes off the calendar. Any costs you already recorded stay
            in Finance, so the books still show what was spent.
          </p>
          <TextArea
            label="Reason (optional)"
            max={200}
            placeholder="e.g. planted too early, field flooded"
            value={cancelReason}
            onChange={(e) => setCancelReason(e.target.value)}
          />
        </div>
      )}

      {mode === 'cost' && (
        <div className="space-y-4">
          <p className="text-[14px] leading-relaxed text-soil-700">
            Costs recorded here belong to this planting, so Finance can show the profit for this
            crop rather than only the farm as a whole.
          </p>
          <Select
            label="What was it for?"
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            options={EXPENSE_CATEGORIES.map((x) => ({ value: x, label: x }))}
          />
          <PesoInput
            label="Amount spent"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
        </div>
      )}
    </Dialog>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-[11px] font-semibold uppercase tracking-wide text-soil-400">{label}</dt>
      <dd className="num mt-0.5 font-semibold text-soil-900">{value}</dd>
    </div>
  )
}

function Chevron({ dir }: { dir: 'left' | 'right' }) {
  return (
    <svg
      width="22"
      height="22"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d={dir === 'left' ? 'M15 18l-6-6 6-6' : 'M9 18l6-6-6-6'} />
    </svg>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Market.tsx' @'
import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  DataTable,
  Dialog,
  Empty,
  Field,
  PesoInput,
  SackInput,
  Search,
  SectionHeading,
  Select,
  Spinner,
  Stat,
} from '@/components/ui'
import {
  CROPS,
  CROP_EMOJI,
  availableSacks,
  peso,
  pesoShort,
  effectiveStage,
  isFinishedOrder,
  sacks,
  shortDate,
  titleCase,
} from '@/lib/format'
import { friendlyError, validateAmount, validateSacks } from '@/lib/validation'
import { BuyerContactCard } from '@/components/BuyerContactCard'
import { BuyerPurchases } from '@/components/BuyerPurchases'
import { StageBadge } from '@/components/OrderTimeline'
import type { Crop, Order, Product, Profile, Schedule } from '@/lib/types'

export default function OwnerMarket() {
  const { farm } = useAuth()
  const [items, setItems] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [revenue, setRevenue] = useState(0)
  const [orders, setOrders] = useState<(Order & { buyer?: Profile | null })[]>([])
  const [editing, setEditing] = useState<Product | null>(null)
  const [settling, setSettling] = useState<string | null>(null)
  const [viewingBuyer, setViewingBuyer] = useState<Profile | null>(null)
  const [sukiCounts, setSukiCounts] = useState<Record<string, number>>({})
  const [harvests, setHarvests] = useState<Schedule[]>([])

  async function load() {
    if (!farm) return
    const [{ data }, { data: orderRows }] = await Promise.all([
      supabase.from('products').select('*').eq('farm_id', farm.id).order('created_at', { ascending: false }),
      supabase
        .from('orders')
        .select('total_price, products!inner(farm_id)')
        .eq('products.farm_id', farm.id),
    ])
    setItems((data as Product[]) ?? [])
    setRevenue((orderRows ?? []).reduce((s: number, o: any) => s + Number(o.total_price), 0))

    const { data: full } = await supabase
      .from('orders')
      .select('*, products!inner(variety, crop, price, farm_id), profiles!orders_buyer_id_fkey(*)')
      .eq('products.farm_id', farm.id)
      .order('created_at', { ascending: false })
      .limit(30)

    setOrders(
      ((full as any[]) ?? []).map((o) => ({ ...o, buyer: (o.profiles as Profile) ?? null })),
    )

    const counts: Record<string, number> = {}
    for (const o of ((full as any[]) ?? [])) {
      if (o.stage === 'completed' && o.buyer_id) {
        counts[o.buyer_id] = (counts[o.buyer_id] ?? 0) + 1
      }
    }
    setSukiCounts(counts)

    const { data: hv } = await supabase
      .from('schedules')
      .select('*')
      .eq('farm_id', farm.id)
      .eq('status', 'harvested')
      .order('harvest_date', { ascending: false })
    setHarvests((hv as Schedule[]) ?? [])

  }

  useEffect(() => {
    load()
    if (!farm) return

    const channel = supabase
      .channel(`owner-market:${farm.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'products', filter: `farm_id=eq.${farm.id}` },
        () => load(),
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [farm?.id])

  async function togglePaid(o: Order) {
    setSettling(o.id)
    const { error } = await supabase.rpc('set_order_paid', {
      p_order_id: o.id,
      p_paid: !o.paid,
    })
    setSettling(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(o.paid ? 'Payment undone' : 'Order marked as paid')
    load()
  }

  const activeOrders = useMemo(() => orders.filter((o) => !isFinishedOrder(o)), [orders])
  const finishedOrders = useMemo(() => orders.filter((o) => isFinishedOrder(o)), [orders])

  const filtered = useMemo(() => {
    if (!items) return []
    const q = query.trim().toLowerCase()
    if (!q) return items
    return items.filter(
      (p) => p.variety.toLowerCase().includes(q) || p.crop.toLowerCase().includes(q),
    )
  }, [items, query])

  if (!items) return <Spinner label="Loading your listings" />

  const available = items.filter((p) => availableSacks(p) > 0).length
  const sold = items.filter((p) => availableSacks(p) === 0).length

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Market</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            What you list here appears instantly on the buyer market.
          </p>
        </div>
        <button className="btn-primary" onClick={() => setOpen(true)}>
          Add product
        </button>
      </div>

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="Available" value={String(available)} sub="Listings" />
        <Stat label="Sold out" value={String(sold)} sub="Listings" />
        <Stat label="Sales revenue" value={pesoShort(revenue)} accent="green" />
      </div>

      <Search value={query} onChange={setQuery} placeholder="Search variety or crop" />

      {filtered.length === 0 ? (
        <Empty
          title={query ? 'Nothing matches that search' : 'No listings yet'}
          body={
            query
              ? 'Try the variety name, or a crop like rice, corn or watermelon.'
              : 'Add your harvest as a listing and buyers can order it by the sack.'
          }
          action={
            !query && (
              <button className="btn-primary" onClick={() => setOpen(true)}>
                Add product
              </button>
            )
          }
        />
      ) : (
        <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
          {filtered.map((p) => {
            const avail = availableSacks(p)
            const out = avail === 0
            return (
              <article
                key={p.id}
                className="flex flex-col overflow-hidden rounded-lg border border-soil-200 bg-white transition hover:shadow-md"
              >
                <div className="relative flex aspect-square items-center justify-center overflow-hidden bg-brand-50">
                  {p.photo_url ? (
                    <img
                      src={p.photo_url}
                      alt={p.variety}
                      loading="lazy"
                      className={`h-full w-full object-cover ${out ? 'opacity-50 grayscale' : ''}`}
                    />
                  ) : (
                    <span className={`text-6xl ${out ? 'opacity-40 grayscale' : ''}`} aria-hidden>
                      {CROP_EMOJI[p.crop]}
                    </span>
                  )}
                  <span
                    className={`absolute left-0 top-2 rounded-r px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white ${
                      out ? 'bg-soil-600' : avail <= 5 ? 'bg-amber-500' : 'bg-brand-700'
                    }`}
                  >
                    {out ? 'Sold out' : avail <= 5 ? `Only ${sacks(avail)} left` : 'On sale'}
                  </span>
                </div>

                <div className="flex flex-1 flex-col gap-1 p-2.5">
                  <h3 className="line-clamp-2 text-[13px] font-semibold leading-snug">
                    {p.variety}
                  </h3>
                  <span
                    className={`chip mt-0.5 ${
                      p.form === 'milled'
                        ? 'bg-brand-100 text-brand-800'
                        : 'bg-soil-100 text-soil-700'
                    }`}
                  >
                    {p.form === 'milled' ? 'Milled' : 'Unmilled'}
                  </span>
                  <p className="num text-[17px] font-bold text-brand-700">{peso(p.price)}</p>
                  <p className="text-[11px] text-soil-400">per sack · {titleCase(p.crop)}</p>

                  <dl className="mt-1.5 space-y-0.5 border-t border-soil-200 pt-1.5 text-[11px]">
                    <div className="flex justify-between">
                      <dt className="text-soil-400">In stock</dt>
                      <dd className="num font-semibold">{sacks(p.quantity)}</dd>
                    </div>
                    {p.reserved > 0 && (
                      <div className="flex justify-between">
                        <dt className="text-soil-400">Reserved</dt>
                        <dd className="num font-semibold text-amber-600">{sacks(p.reserved)}</dd>
                      </div>
                    )}
                    <div className="flex justify-between">
                      <dt className="text-soil-400">Available</dt>
                      <dd className="num font-bold">{sacks(avail)}</dd>
                    </div>
                  </dl>

                  <div className="mt-2 grid grid-cols-2 gap-1.5">
                    <button
                      className="btn-sm border border-soil-200 hover:bg-soil-100"
                      onClick={() => setEditing(p)}
                    >
                      Edit stock
                    </button>
                    <button
                      onClick={async () => {
                        await supabase.from('products').delete().eq('id', p.id)
                        toast.success('Listing removed')
                        load()
                      }}
                      className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                    >
                      Remove
                    </button>
                  </div>
                </div>
              </article>
            )
          })}
        </div>
      )}

      {activeOrders.length > 0 && (
        <section className="no-print">
          <SectionHeading>
            Incoming orders
            <span className="num ml-2 text-soil-400">({activeOrders.length})</span>
          </SectionHeading>
          <DataTable
            minWidth="50rem"
            headers={[
              { label: 'Date' },
              { label: 'Product' },
              { label: 'Buyer' },
              { label: 'Sacks', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Stage' },
              { label: 'Payment' },
              { label: 'Contact', align: 'right' },
            ]}
          >
            {activeOrders.map((o) => (
              <tr key={o.id}>
                <td className="num px-4 py-3 text-soil-600">{shortDate(o.created_at)}</td>
                <td className="px-4 py-3 font-semibold">
                  {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                  {o.products?.variety ?? 'Product'}
                </td>
                <td className="px-4 py-3">
                  {o.buyer ? (
                    <span className="flex flex-wrap items-center gap-1.5">
                      <button
                        onClick={() => setViewingBuyer(o.buyer!)}
                        className="text-left font-semibold text-brand-700 hover:underline"
                      >
                        {o.buyer.name}
                      </button>
                      {(sukiCounts[o.buyer_id] ?? 0) >= 3 && <SukiBadge />}
                    </span>
                  ) : (
                    <span className="block">—</span>
                  )}
                  <span className="block max-w-[14rem] truncate text-[12px] text-soil-400">
                    {[o.buyer?.address, o.buyer?.city].filter(Boolean).join(', ') ||
                      'No address given'}
                  </span>
                </td>
                <td className="num px-4 py-3 text-right font-bold">{sacks(o.quantity)}</td>
                <td className="num px-4 py-3 text-right font-bold text-brand-700">
                  {peso(o.total_price)}
                </td>
                <td className="px-4 py-3">
                  <StageBadge stage={effectiveStage(o)} />
                </td>
                <td className="px-4 py-3">
                  {o.paid ? (
                    <Badge tone="green">Paid</Badge>
                  ) : (
                    <button
                      className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                      disabled={settling === o.id}
                      onClick={() => togglePaid(o)}
                    >
                      {settling === o.id ? '…' : 'Mark paid'}
                    </button>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  {o.buyer?.phone ? (
                    <span className="inline-flex gap-1.5">
                      <a
                        href={`tel:${o.buyer.phone}`}
                        className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                      >
                        Call
                      </a>
                      <a
                        href={`sms:${o.buyer.phone}`}
                        className="btn-sm border border-soil-200 hover:bg-soil-100"
                      >
                        Text
                      </a>
                    </span>
                  ) : (
                    <span className="text-[12px] text-soil-400">—</span>
                  )}
                </td>
              </tr>
            ))}
          </DataTable>
        </section>
      )}

      {finishedOrders.length > 0 && (
        <section className="no-print">
          <SectionHeading>
            Completed orders
            <span className="num ml-2 text-soil-400">({finishedOrders.length})</span>
          </SectionHeading>
          <DataTable
            minWidth="44rem"
            headers={[
              { label: 'Date' },
              { label: 'Product' },
              { label: 'Buyer' },
              { label: 'Sacks', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Result' },
            ]}
          >
            {finishedOrders.map((o) => (
              <tr key={o.id}>
                <td className="num px-4 py-3 text-soil-600">{shortDate(o.created_at)}</td>
                <td className="px-4 py-3 font-semibold">
                  {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                  {o.products?.variety ?? 'Product'}
                </td>
                <td className="px-4 py-3">
                  {o.buyer ? (
                    <span className="flex flex-wrap items-center gap-1.5">
                      <button
                        onClick={() => setViewingBuyer(o.buyer!)}
                        className="font-semibold text-brand-700 hover:underline"
                      >
                        {o.buyer.name}
                      </button>
                      {(sukiCounts[o.buyer_id] ?? 0) >= 3 && <SukiBadge />}
                    </span>
                  ) : (
                    '—'
                  )}
                </td>
                <td className="num px-4 py-3 text-right">{sacks(o.quantity)}</td>
                <td className="num px-4 py-3 text-right font-semibold">{peso(o.total_price)}</td>
                <td className="px-4 py-3">
                  <StageBadge stage={effectiveStage(o)} />
                </td>
              </tr>
            ))}
          </DataTable>
        </section>
      )}

      <Dialog
        open={viewingBuyer !== null}
        onClose={() => setViewingBuyer(null)}
        title={viewingBuyer?.name ?? 'Buyer'}
        description={
          viewingBuyer && (sukiCounts[viewingBuyer.id] ?? 0) >= 3
            ? `Suki · ${sukiCounts[viewingBuyer.id]} completed orders`
            : (viewingBuyer?.company ?? 'Buyer')
        }
        footer={
          <button className="btn-ghost" onClick={() => setViewingBuyer(null)}>
            Close
          </button>
        }
      >
        <div className="space-y-4">
          <BuyerContactCard buyer={viewingBuyer} />
          {viewingBuyer && <BuyerPurchases buyerId={viewingBuyer.id} />}
        </div>
      </Dialog>

      <EditStockDialog
        product={editing}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null)
          load()
        }}
      />

      <AddProductDialog
        open={open}
        onClose={() => setOpen(false)}
        farmId={farm?.id ?? ''}
        products={items}
        harvests={harvests}
        onSaved={() => {
          setOpen(false)
          load()
        }}
      />
    </div>
  )
}

function AddProductDialog({
  open,
  onClose,
  farmId,
  products,
  harvests,
  onSaved,
}: {
  open: boolean
  onClose(): void
  farmId: string
  products: Product[]
  harvests: Schedule[]
  onSaved(): void
}) {
  const [form, setForm] = useState({
    variety: '',
    crop: 'rice' as Crop,
    quantity: '',
    price: '',
    form: 'unmilled' as 'unmilled' | 'milled',
  })
  const [existing, setExisting] = useState<Product | null>(null)
  const [photo, setPhoto] = useState<File | null>(null)
  const [photoPreview, setPhotoPreview] = useState<string | null>(null)
  const [uploading, setUploading] = useState(false)

  useEffect(() => {
    if (!photo) {
      setPhotoPreview(null)
      return
    }
    const url = URL.createObjectURL(photo)
    setPhotoPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [photo])
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  const cropHarvests = harvests.filter((h) => h.crop === form.crop && (h.actual_sacks ?? 0) > 0)

  const harvestOptions = cropHarvests.map((h) => ({
    value: h.variety,
    label: h.variety,
  }))

  const chosenVariety = form.variety.trim()

  const matchedHarvest = cropHarvests.find(
    (h) => h.variety.trim().toLowerCase() === chosenVariety.toLowerCase(),
  )

  const alreadyListed = products
    .filter(
      (p) => p.crop === form.crop && p.variety.trim().toLowerCase() === chosenVariety.toLowerCase(),
    )
    .reduce((sum, p) => sum + p.quantity, 0)

  const maxSacks = matchedHarvest
    ? Math.max((matchedHarvest.actual_sacks ?? 0) - alreadyListed, 0)
    : null

  useEffect(() => {
    if (!chosenVariety) {
      setExisting(null)
      return
    }
    const match = products.find(
      (p) =>
        p.crop === form.crop && p.variety.trim().toLowerCase() === chosenVariety.toLowerCase(),
    )
    setExisting(match ?? null)
  }, [chosenVariety, form.crop, products])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      variety: form.variety ? null : 'Choose a harvested crop to list.',
      quantity: validateSacks(form.quantity, {
        min: 1,
        ...(maxSacks !== null ? { max: maxSacks } : {}),
      }),
      price: validateAmount(form.price, 'price'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)

    let photoUrl: string | null = null
    if (photo) {
      setUploading(true)
      const { data: sess } = await supabase.auth.getSession()
      const uid = sess.session?.user.id
      const ext = photo.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `${uid}/${Date.now()}.${ext}`
      const { error: upErr } = await supabase.storage
        .from('product-photos')
        .upload(path, photo, { upsert: true, contentType: photo.type })
      setUploading(false)
      if (upErr) {
        setBusy(false)
        toast.error(`Photo upload failed: ${upErr.message}`)
        return
      }
      photoUrl = supabase.storage.from('product-photos').getPublicUrl(path).data.publicUrl
    }

    const { data, error } = await supabase.rpc('add_or_merge_product', {
      p_farm_id: farmId,
      p_variety: chosenVariety,
      p_crop: form.crop,
      p_quantity: parseInt(form.quantity, 10),
      p_price: Number(form.price),
      p_form: form.form,
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    if (photoUrl && (data as any)?.id) {
      await supabase.from('products').update({ photo_url: photoUrl }).eq('id', (data as any).id)
    }

    toast.success(
      (data as any)?.merged
        ? `Added to the existing ${chosenVariety} listing`
        : 'Product listed',
    )
    setForm({ variety: '', crop: 'rice', quantity: '', price: '', form: 'unmilled' })
    setPhoto(null)
    onSaved()
  }


  const total =
    /^\d+$/.test(form.quantity) && form.price !== ''
      ? parseInt(form.quantity, 10) * Number(form.price)
      : null

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Add a product"
      description="Buyers order by the sack."
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            onClick={submit}
            disabled={busy || harvestOptions.length === 0}
          >
            {uploading ? 'Uploading photo…' : busy ? 'Listing…' : 'Add product'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        {harvestOptions.length === 0 && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              No harvested {form.crop} yet
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
              Record a harvest on the Calendar first. Once a planting is harvested, its variety
              appears here ready to list.
            </p>
          </div>
        )}

        <div>
          <label className="label">How is it being sold?</label>
          <div className="grid grid-cols-2 gap-2">
            {(['unmilled', 'milled'] as const).map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => set('form', f)}
                aria-pressed={form.form === f}
                className={`rounded-xl border-2 px-3 py-3 text-left transition ${
                  form.form === f
                    ? 'border-brand-600 bg-brand-50'
                    : 'border-soil-200 hover:bg-soil-50'
                }`}
              >
                <span className="block text-[14px] font-bold">
                  {f === 'milled' ? 'Milled' : 'Unmilled'}
                </span>
                <span className="block text-[12px] leading-snug text-soil-600">
                  {f === 'milled'
                    ? 'Ready to cook and sell by the sack'
                    : 'Straight from the harvest, not yet milled'}
                </span>
              </button>
            ))}
          </div>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => {
              set('crop', e.target.value)
              set('variety', '')
            }}
            options={CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` }))}
          />
          <Select
            label="Variety"
            value={form.variety}
            error={errors.variety}
            onChange={(e) => set('variety', e.target.value)}
            disabled={harvestOptions.length === 0}
            options={
              harvestOptions.length === 0
                ? [{ value: '', label: 'No harvested crops yet' }]
                : [{ value: '', label: 'Choose a variety…' }, ...harvestOptions]
            }
          />
        </div>

        <div>
          <SackInput
            label="Number of sacks"
            placeholder="0"
            max={maxSacks ?? undefined}
            value={form.quantity}
            error={errors.quantity}
            onChange={(e) => set('quantity', e.target.value)}
          />

          {matchedHarvest && (
            <dl className="mt-2 space-y-1 rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px]">
              <div className="flex justify-between gap-3">
                <dt className="text-soil-600">
                  Harvested {shortDate(matchedHarvest.harvested_at ?? matchedHarvest.harvest_date)}
                </dt>
                <dd className="num font-semibold">
                  {sacks(matchedHarvest.actual_sacks ?? 0)} sacks
                </dd>
              </div>
              {alreadyListed > 0 && (
                <div className="flex justify-between gap-3">
                  <dt className="text-soil-600">Already listed</dt>
                  <dd className="num font-semibold">{sacks(alreadyListed)} sacks</dd>
                </div>
              )}
              <div className="flex justify-between gap-3 border-t border-soil-200 pt-1">
                <dt className="font-semibold">Most you can sell</dt>
                <dd className="num font-bold text-brand-700">{sacks(maxSacks ?? 0)} sacks</dd>
              </div>
            </dl>
          )}
        </div>
        <PesoInput
          label="Price per sack"
          placeholder="0.00"
          value={form.price}
          error={errors.price}
          onChange={(e) => set('price', e.target.value)}
        />
        <div>
          <label className="label" htmlFor="prodphoto">
            Product photo
          </label>
          {photoPreview ? (
            <div className="overflow-hidden rounded-xl border border-soil-200">
              <img src={photoPreview} alt="Your product" className="max-h-48 w-full bg-soil-50 object-contain" />
              <div className="flex items-center justify-between gap-3 border-t border-soil-200 px-3 py-2">
                <span className="truncate text-[12px] text-soil-600">{photo?.name}</span>
                <button
                  type="button"
                  onClick={() => setPhoto(null)}
                  className="shrink-0 text-[13px] font-semibold text-red-600 hover:underline"
                >
                  Remove
                </button>
              </div>
            </div>
          ) : (
            <label
              htmlFor="prodphoto"
              className="flex cursor-pointer flex-col items-center gap-1 rounded-xl border-2 border-dashed
                         border-soil-200 px-4 py-6 text-center transition hover:bg-soil-50"
            >
              <span className="text-2xl" aria-hidden>
                📷
              </span>
              <span className="text-[13px] font-semibold">Attach a photo</span>
              <span className="text-[12px] text-soil-400">
                Optional, but buyers are far more likely to order with one
              </span>
            </label>
          )}
          <input
            id="prodphoto"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            capture="environment"
            className="sr-only"
            onChange={(e) => {
              const f = e.target.files?.[0]
              if (!f) return
              if (f.size > 5 * 1024 * 1024) {
                toast.error('That photo is over 5 MB. Try a smaller one.')
                return
              }
              setPhoto(f)
            }}
          />
        </div>

        {existing && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              You already list {existing.variety}
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
              These sacks will be added to that listing, taking it from{' '}
              <span className="num font-semibold">{sacks(existing.quantity)}</span> to{' '}
              <span className="num font-semibold">
                {sacks(existing.quantity + (parseInt(form.quantity || '0', 10) || 0))}
              </span>{' '}
              sacks, rather than creating a second entry.
            </p>
          </div>
        )}

        {total !== null && (
          <p className="rounded-xl bg-brand-50 px-4 py-3 text-sm font-semibold text-brand-900">
            Whole listing is worth <span className="num">{peso(total)}</span>
          </p>
        )}
      </form>
    </Dialog>
  )
}

function SukiBadge() {
  return (
    <span
      title="A regular customer — three or more completed orders"
      className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-amber-800"
    >
      <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
        <path d="M12 2l2.9 6.1 6.6.9-4.8 4.6 1.2 6.6L12 17.1 6.1 20.2l1.2-6.6L2.5 9l6.6-.9z" />
      </svg>
      Suki
    </span>
  )
}

function EditStockDialog({
  product,
  onClose,
  onSaved,
}: {
  product: Product | null
  onClose(): void
  onSaved(): void
}) {
  const [qty, setQty] = useState('')
  const [newPrice, setNewPrice] = useState('')
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (product) {
      setQty(String(product.quantity))
      setReason('')
      setError(null)
      setConfirming(false)
    }
  }, [product?.id])

  if (!product) return null

  const next = /^\d+$/.test(qty) ? parseInt(qty, 10) : null
  const diff = next === null ? 0 : next - product.quantity

  const major =
    next !== null &&
    (next === 0 || Math.abs(diff) >= Math.max(10, Math.ceil(product.quantity / 2)))

  async function save() {
    const err = validateSacks(qty, { min: 0 })
    setError(err)
    if (err) return
    if (newPrice === '' || Number(newPrice) < 0) {
      toast.error('Enter a valid price per sack.')
      return
    }

    if (major && !confirming) {
      setConfirming(true)
      return
    }

    setBusy(true)
    const { error: rpcError } = await supabase.rpc('update_product_listing', {
      p_product_id: product!.id,
      p_new_quantity: parseInt(qty, 10),
      p_new_price: Number(newPrice),
      p_reason: reason.trim() || (diff > 0 ? 'Restocked' : 'Stock corrected'),
    })
    setBusy(false)

    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success('Listing updated — buyers see this immediately')
    onSaved()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={`Edit listing — ${product.variety}`}
      description={`${sacks(product.quantity)} sacks at ${peso(product.price)} each`}
      footer={
        <>
          <button
            type="button"
            className="btn-ghost"
            onClick={() => (confirming ? setConfirming(false) : onClose())}
          >
            {confirming ? 'Go back' : 'Cancel'}
          </button>
          <button
            className={confirming ? 'btn-danger' : 'btn-primary'}
            onClick={save}
            disabled={busy || next === null}
          >
            {busy ? 'Saving…' : confirming ? 'Yes, save this change' : 'Save changes'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <SackInput
          label="New stock level"
          min={0}
          value={qty}
          error={error}
          hint={
            product.reserved > 0
              ? `${sacks(product.reserved)} sack(s) are reserved by open orders.`
              : 'Set to 0 to mark this product out of stock.'
          }
          onChange={(e) => {
            setQty(e.target.value)
            setError(null)
            setConfirming(false)
          }}
        />

        <PesoInput
          label="Price per sack"
          placeholder="0.00"
          value={newPrice}
          hint={
            Number(newPrice) !== Number(product.price)
              ? `Currently ${peso(product.price)} — buyers see the new price straight away`
              : undefined
          }
          onChange={(e) => setNewPrice(e.target.value)}
        />

        <Field
          label="Reason for the change"
          placeholder="e.g. New harvest added, spoilage, recount"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />

        {next !== null && diff !== 0 && (
          <dl className="space-y-1.5 rounded-lg bg-soil-50 px-4 py-3 text-[13px]">
            <div className="flex justify-between">
              <dt className="text-soil-600">Change</dt>
              <dd className={`num font-bold ${diff > 0 ? 'text-green-700' : 'text-red-600'}`}>
                {diff > 0 ? '+' : ''}
                {sacks(Math.abs(diff))} sacks
              </dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-soil-600">New weight</dt>
              <dd className="num font-semibold">{next * 25} kg</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-soil-600">Buyers will see</dt>
              <dd className="font-semibold">
                {next === 0 ? 'Out of stock' : next <= 5 ? 'Low stock' : 'Available'}
              </dd>
            </div>
          </dl>
        )}

        {confirming && (
          <div className="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              {next === 0 ? 'This will take the product off the market' : 'That is a large change'}
            </p>
            <p className="mt-1 text-[13px] leading-relaxed text-amber-800">
              {next === 0
                ? 'Buyers will see it as out of stock and cannot order it until you restock.'
                : `Stock goes from ${sacks(product.quantity)} to ${sacks(next!)} sacks. Check the number before saving.`}
            </p>
          </div>
        )}

        <p className="text-[12px] text-soil-400">
          This change is recorded with your name and the time, and appears in the stock history
          below the listings.
        </p>
      </div>
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Finance.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Empty, Field, PesoInput, Select, Spinner, Stat } from '@/components/ui'
import { Link } from 'react-router-dom'
import { CROP_COLOR, CROP_EMOJI, peso, pesoShort, shortDate, titleCase, todayISO } from '@/lib/format'
import { friendlyError, validateAmount } from '@/lib/validation'
import type { Transaction, TxnType } from '@/lib/types'

const INCOME_CATEGORIES = ['Crop Sales', 'Livestock Sales', 'Government Subsidy', 'Other Income']
const EXPENSE_CATEGORIES = [
  'Labor',
  'Seeds',
  'Fertilizer',
  'Pesticides',
  'Equipment',
  'Fuel',
  'Water',
  'Electricity',
  'Other',
]

export default function OwnerFinance() {
  const { farm } = useAuth()
  const [rows, setRows] = useState<Transaction[] | null>(null)
  const [dialog, setDialog] = useState<TxnType | null>(null)

  async function load() {
    if (!farm) return
    const { data } = await supabase
      .from('transactions')
      .select('*')
      .eq('farm_id', farm.id)
      .order('date', { ascending: false })
      .order('created_at', { ascending: false })
    setRows((data as Transaction[]) ?? [])

  }

  useEffect(() => {
    load()
  }, [farm?.id])

  if (!rows) return <Spinner label="Loading your books" />

  const income = rows.filter((r) => r.type === 'income').reduce((s, r) => s + Number(r.amount), 0)
  const expenses = rows.filter((r) => r.type === 'expense').reduce((s, r) => s + Number(r.amount), 0)
  const net = income - expenses

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Finance</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Sales from the buyer market and costs from each planting flow in here automatically.
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-3">
        <Stat label="Total sales" value={pesoShort(income)} accent="green" />
        <Stat label="Total expenses" value={pesoShort(expenses)} accent="red" />
        <Stat
          label="Net profit"
          value={pesoShort(net)}
          accent={net >= 0 ? 'green' : 'red'}
          sub={net >= 0 ? 'In the black' : 'Spending exceeds income'}
        />
      </div>

      <div className="grid gap-3 sm:grid-cols-[1fr_auto]">
        <div className="rounded-xl border border-soil-200 bg-white px-4 py-3.5">
          <p className="text-[13px] font-semibold text-soil-800">
            Costs are recorded on the crop they belong to
          </p>
          <p className="mt-0.5 text-[13px] leading-relaxed text-soil-600">
            Open a planting in the{' '}
            <Link to="/owner/calendar" className="font-semibold text-brand-700 hover:underline">
              Calendar
            </Link>{' '}
            and use Add cost, so seeds, fertilizer and labour count toward that crop's profit and
            are never entered twice.
          </p>
        </div>
        <div className="flex flex-col gap-2 self-start">
          <button className="btn-primary px-5 py-3" onClick={() => setDialog('income')}>
            Add other income
          </button>
          <button className="btn-ghost px-5 py-3" onClick={() => setDialog('expense')}>
            Add expense
          </button>
        </div>
      </div>

      {rows.length === 0 ? (
        <Empty
          title="No entries yet"
          body="Record what you earn and what you spend to see your net profit build up."
        />
      ) : (
        <ul className="card divide-y divide-soil-200/70">
          {rows.map((t) => (
            <li key={t.id} className="flex items-center justify-between gap-3 px-4 py-3.5">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={t.type === 'income' ? 'green' : 'red'}>{t.category}</Badge>
                  {t.crop && (
                    <span className={`chip ${CROP_COLOR[t.crop].chip}`}>
                      {CROP_EMOJI[t.crop]} {titleCase(t.crop)}
                    </span>
                  )}
                  <span className="text-[12px] text-soil-400">{shortDate(t.date)}</span>
                </div>
                {t.description && (
                  <p className="mt-1 truncate text-[13px] text-soil-600">{t.description}</p>
                )}
              </div>
              <span
                className={`num shrink-0 text-sm font-bold ${
                  t.type === 'income' ? 'text-green-700' : 'text-red-600'
                }`}
              >
                {t.type === 'income' ? '+' : '−'}
                {peso(t.amount)}
              </span>
            </li>
          ))}
        </ul>
      )}

      <TxnDialog
        type={dialog}
        farmId={farm?.id ?? ''}
        onClose={() => setDialog(null)}
        onSaved={() => {
          setDialog(null)
          load()
        }}
      />
    </div>
  )
}

function TxnDialog({
  type,
  farmId,
  onClose,
  onSaved,
}: {
  type: TxnType | null
  farmId: string
  onClose(): void
  onSaved(): void
}) {
  const isIncome = type !== 'expense'
  const categories = isIncome ? INCOME_CATEGORIES : EXPENSE_CATEGORIES

  const [form, setForm] = useState({
    category: categories[0],
    amount: '',
    description: '',
    date: todayISO(),
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (type) {
      setForm({
        category: (isIncome ? INCOME_CATEGORIES : EXPENSE_CATEGORIES)[0],
        amount: '',
        description: '',
        date: todayISO(),
      })
      setErrors({})
    }
  }, [type])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = { amount: validateAmount(form.amount, 'amount') }
    setErrors(next)
    if (next.amount) return

    setBusy(true)
    const { error } = await supabase.from('transactions').insert({
      farm_id: farmId,
      type,
      category: form.category,
      amount: Number(form.amount),
      description: form.description.trim(),
      date: form.date,
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(isIncome ? 'Income added' : 'Expense added')
    onSaved()
  }

  return (
    <Dialog
      open={type !== null}
      onClose={onClose}
      title={isIncome ? 'Add income' : 'Add expense'}
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className={isIncome ? 'btn-primary' : 'btn-danger'} onClick={submit} disabled={busy}>
            {busy ? 'Saving…' : isIncome ? 'Add income' : 'Add expense'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Category"
            value={form.category}
            onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
            options={categories.map((c) => ({ value: c, label: c }))}
          />
          <PesoInput
            label="Amount"
            placeholder="0.00"
            value={form.amount}
            error={errors.amount}
            onChange={(e) => setForm((f) => ({ ...f, amount: e.target.value }))}
          />
        </div>
        <div>
          <label className="label" htmlFor="txn-date">
            Date
          </label>
          <input
            id="txn-date"
            type="date"
            className="field num"
            value={form.date}
            onChange={(e) => setForm((f) => ({ ...f, date: e.target.value }))}
          />
        </div>
        <Field
          label="Description"
          placeholder="Optional note"
          value={form.description}
          onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
        />
      </form>
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Jobs.tsx' @'
import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  Dialog,
  Empty,
  Field,
  PesoInput,
  Select,
  Spinner,
  TextArea,
} from '@/components/ui'
import { CROP_EMOJI, peso, relativeDate, shortDate, titleCase,
  todayISO,
} from '@/lib/format'
import { displayPhone, friendlyError, validateAmount, validateRequired, validateWholeNumber } from '@/lib/validation'
import type { AppStatus, JobApplication, JobCrop, JobPost, JobType } from '@/lib/types'

const JOB_TYPES: JobType[] = ['seasonal', 'part-time', 'full-time']
const JOB_CROPS: JobCrop[] = ['rice', 'corn', 'watermelon', 'general']


export default function OwnerJobs() {
  const { profile, farm } = useAuth()
  const [tab, setTab] = useState<'posts' | 'apps'>('posts')
  const [posts, setPosts] = useState<JobPost[] | null>(null)
  const [apps, setApps] = useState<JobApplication[] | null>(null)
  const [dialog, setDialog] = useState(false)

  async function load() {
    if (!profile) return
    const { data: jobs } = await supabase
      .from('job_posts')
      .select('*')
      .eq('owner_id', profile.id)
      .order('created_at', { ascending: false })

    setPosts((jobs as JobPost[]) ?? [])

    const ids = (jobs ?? []).map((j) => j.id)
    if (!ids.length) {
      setApps([])
      return
    }
    const { data: applications } = await supabase
      .from('job_applications')
      .select('*, job_posts(*), profiles(*)')
      .in('job_id', ids)
      .order('applied_at', { ascending: false })

    const rows = (applications as unknown as JobApplication[]) ?? []

    const farmerIds = [...new Set(rows.map((r) => r.farmer_id))]
    if (farmerIds.length) {
      const { data: fps } = await supabase.from('farmer_profiles').select('*').in('id', farmerIds)
      const byId = new Map((fps ?? []).map((f: any) => [f.id, f]))
      rows.forEach((r) => {
        r.farmer_profiles = byId.get(r.farmer_id) ?? null
      })
    }

    setApps(rows)
  }

  useEffect(() => {
    load()
    if (!profile) return
    const channel = supabase
      .channel(`owner-jobs:${profile.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_applications' }, () => load())
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [profile?.id])

  if (!posts || !apps) return <Spinner label="Loading your job posts" />

  const pending = apps.filter((a) => a.status === 'pending').length

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Jobs</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            Post work and review who applies. Farmers see open posts straight away.
          </p>
        </div>
        <button className="btn-primary" onClick={() => setDialog(true)}>
          Post a job
        </button>
      </div>

      <div role="tablist" className="grid grid-cols-2 gap-1 rounded-xl bg-soil-100 p-1">
        <button
          role="tab"
          aria-selected={tab === 'posts'}
          onClick={() => setTab('posts')}
          className={`rounded-lg px-3 py-2.5 text-sm font-bold transition ${
            tab === 'posts' ? 'bg-white shadow-sm' : 'text-soil-600'
          }`}
        >
          My job posts
        </button>
        <button
          role="tab"
          aria-selected={tab === 'apps'}
          onClick={() => setTab('apps')}
          className={`rounded-lg px-3 py-2.5 text-sm font-bold transition ${
            tab === 'apps' ? 'bg-white shadow-sm' : 'text-soil-600'
          }`}
        >
          Applications
          {pending > 0 && (
            <span className="num ml-1.5 rounded-full bg-red-600 px-1.5 py-0.5 text-[10px] text-white">
              {pending}
            </span>
          )}
        </button>
      </div>

      {tab === 'posts' ? (
        <PostsTab posts={posts} apps={apps} onChanged={load} onAdd={() => setDialog(true)} />
      ) : (
        <ApplicationsTab posts={posts} apps={apps} onChanged={load} />
      )}

      <PostJobDialog
        open={dialog}
        onClose={() => setDialog(false)}
        farmId={farm?.id ?? ''}
        ownerId={profile?.id ?? ''}
        defaultLocation={[farm?.city, farm?.province].filter(Boolean).join(', ')}
        onSaved={() => {
          setDialog(false)
          load()
        }}
      />
    </div>
  )
}

function PostsTab({
  posts,
  apps,
  onChanged,
  onAdd,
}: {
  posts: JobPost[]
  apps: JobApplication[]
  onChanged(): void
  onAdd(): void
}) {
  const [confirming, setConfirming] = useState<JobPost | null>(null)
  const [deleting, setDeleting] = useState(false)

  async function remove() {
    if (!confirming) return
    setDeleting(true)
    const { error } = await supabase.rpc('delete_job_post', { p_job_id: confirming.id })
    setDeleting(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Job post deleted')
    setConfirming(null)
    onChanged()
  }

  if (posts.length === 0) {
    return (
      <Empty
        title="No job posts yet"
        body="Post the work you need doing — planting, harvesting, driving — and farmers can apply."
        action={
          <button className="btn-primary" onClick={onAdd}>
            Post a job
          </button>
        }
      />
    )
  }

  async function toggle(post: JobPost) {
    const next = post.status === 'closed' ? 'open' : 'closed'
    const { error } = await supabase.from('job_posts').update({ status: next }).eq('id', post.id)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(next === 'open' ? 'Job reopened' : 'Job closed')
    onChanged()
  }

  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {posts.map((p) => {
        const count = apps.filter((a) => a.job_id === p.id).length
        const remaining = Math.max(0, p.slots - p.filled_slots)
        return (
          <article key={p.id} className="card flex flex-col gap-3 p-4">
            <div className="flex items-start justify-between gap-3">
              <span className="text-2xl" aria-hidden>
                {CROP_EMOJI[p.crop]}
              </span>
              <Badge
                tone={p.status === 'open' ? 'green' : p.status === 'filled' ? 'blue' : 'grey'}
              >
                {titleCase(p.status)}
              </Badge>
            </div>

            <div>
              <h3 className="text-base font-bold leading-snug">{p.title}</h3>
              <p className="mt-0.5 text-[13px] text-soil-400">
                {p.location} · starts {shortDate(p.start_date)}
              </p>
            </div>

            <div className="flex flex-wrap gap-2">
              <Badge tone="brand">{p.type}</Badge>
              <Badge>
                <span className="num">{peso(p.wage)}</span>&nbsp;a day
              </Badge>
            </div>

            <div className="mt-auto flex items-end justify-between border-t border-soil-200/70 pt-3">
              <div>
                <p className="num text-lg font-bold">
                  {remaining}
                  <span className="text-sm font-semibold text-soil-400">/{p.slots}</span>
                </p>
                <p className="text-[12px] text-soil-400">slots left</p>
              </div>
              <div className="text-right">
                <p className="num text-lg font-bold">{count}</p>
                <p className="text-[12px] text-soil-400">
                  {count === 1 ? 'applicant' : 'applicants'}
                </p>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <button className="btn-ghost" onClick={() => toggle(p)}>
                {p.status === 'closed' ? 'Reopen post' : 'Close post'}
              </button>
              <button
                className="btn-ghost text-red-600 hover:bg-red-50"
                onClick={() => setConfirming(p)}
              >
                Delete
              </button>
            </div>
          </article>
        )
      })}

      <Dialog
        open={confirming !== null}
        onClose={() => setConfirming(null)}
        title="Delete this job post?"
        description={confirming?.title}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setConfirming(null)}>
              Keep post
            </button>
            <button className="btn-danger" onClick={remove} disabled={deleting}>
              {deleting ? 'Deleting…' : 'Delete post'}
            </button>
          </>
        }
      >
        <div className="space-y-3 text-[14px] leading-relaxed text-soil-800">
          <p>
            The post and its {apps.filter((a) => a.job_id === confirming?.id).length} application
            {apps.filter((a) => a.job_id === confirming?.id).length === 1 ? '' : 's'} will be
            removed. Everyone who applied is notified.
          </p>

          {confirming && confirming.filled_slots > 0 && (
            <p className="rounded-lg border border-amber-200 bg-amber-50 px-3.5 py-3 text-[13px] text-amber-900">
              You already hired {confirming.filled_slots}{' '}
              {confirming.filled_slots === 1 ? 'person' : 'people'} for this job. Their wages stay
              recorded in Finance — deleting the post does not change your expenses. Call them to
              explain before deleting.
            </p>
          )}

          <p className="text-[13px] text-soil-600">This cannot be undone.</p>
        </div>
      </Dialog>
    </div>
  )
}

function ApplicationsTab({
  posts,
  apps,
  onChanged,
}: {
  posts: JobPost[]
  apps: JobApplication[]
  onChanged(): void
}) {
  const [job, setJob] = useState('all')
  const [status, setStatus] = useState('all')
  const [busy, setBusy] = useState<string | null>(null)

  const filtered = useMemo(
    () =>
      apps.filter(
        (a) => (job === 'all' || a.job_id === job) && (status === 'all' || a.status === status),
      ),
    [apps, job, status],
  )

  const [rejecting, setRejecting] = useState<JobApplication | null>(null)
  const [reason, setReason] = useState('')

  async function decide(id: string, decision: AppStatus, note = '') {
    setBusy(id)
    const { error } = await supabase.rpc('decide_application', {
      p_application_id: id,
      p_decision: decision,
      p_note: note,
    })
    setBusy(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(decision === 'accepted' ? 'Applicant hired' : 'Application rejected')
    setRejecting(null)
    setReason('')
    onChanged()
  }

  return (
    <div className="space-y-4">
      <Dialog
        open={rejecting !== null}
        onClose={() => setRejecting(null)}
        title="Reject this application?"
        description={rejecting?.profiles?.name}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setRejecting(null)}>
              Go back
            </button>
            <button
              className="btn-danger"
              disabled={busy !== null || !reason.trim()}
              onClick={() => decide(rejecting!.id, 'rejected', reason.trim())}
            >
              {busy ? 'Saving…' : 'Reject application'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            The applicant is told why, so they know whether to apply again. A reason is required.
          </p>
          <TextArea
            label="Reason for rejecting"
            max={200}
            placeholder="e.g. the slots are already filled, or we need someone with harvest experience"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
      </Dialog>

      <div className="grid gap-3 sm:grid-cols-2">
        <Select
          label="Job post"
          value={job}
          onChange={(e) => setJob(e.target.value)}
          options={[
            { value: 'all', label: 'All job posts' },
            ...posts.map((p) => ({ value: p.id, label: p.title })),
          ]}
        />
        <Select
          label="Status"
          value={status}
          onChange={(e) => setStatus(e.target.value)}
          options={[
            { value: 'all', label: 'All statuses' },
            { value: 'pending', label: 'Pending' },
            { value: 'accepted', label: 'Accepted' },
            { value: 'rejected', label: 'Rejected' },
          ]}
        />
      </div>

      {filtered.length === 0 ? (
        <Empty
          title="No applications here"
          body={
            apps.length === 0
              ? 'When a farmer applies to one of your posts, they show up here.'
              : 'Nothing matches these filters. Try widening them.'
          }
        />
      ) : (
        <div className="grid gap-3 lg:grid-cols-2">
          {filtered.map((a) => {
            const fp = a.farmer_profiles
            return (
              <article key={a.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h3 className="text-base font-bold">{a.profiles?.name ?? 'Farmer'}</h3>
                    <p className="num text-[13px] text-soil-600">
                      {displayPhone(a.profiles?.phone)}
                    </p>
                  </div>
                  <Badge
                    tone={
                      a.status === 'accepted' ? 'green' : a.status === 'rejected' ? 'red' : 'amber'
                    }
                  >
                    {titleCase(a.status)}
                  </Badge>
                </div>

                <p className="text-[13px] font-semibold text-soil-600">
                  Applied for {a.job_posts?.title} · {relativeDate(a.applied_at)}
                </p>

                {a.message && (
                  <p className="rounded-xl bg-soil-50 px-3.5 py-3 text-[14px] leading-relaxed text-soil-800">
                    {a.message}
                  </p>
                )}

                <div className="flex flex-wrap gap-2">
                  {fp?.availability && (
                    <Badge tone={fp.availability === 'available' ? 'green' : 'grey'}>
                      {titleCase(fp.availability)}
                    </Badge>
                  )}
                  {typeof fp?.experience_years === 'number' && (
                    <Badge>
                      <span className="num">{fp.experience_years}</span>&nbsp;
                      {fp.experience_years === 1 ? 'year' : 'years'} experience
                    </Badge>
                  )}
                  {(fp?.skills ?? []).map((s) => (
                    <Badge key={s} tone="brand">
                      {s}
                    </Badge>
                  ))}
                </div>

                {a.profiles?.phone && (
                  <div className="flex gap-2 border-t border-soil-200/70 pt-3">
                    <a
                      href={`tel:${a.profiles.phone}`}
                      className="btn-ghost flex-1 py-2 text-[13px]"
                    >
                      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z" />
                      </svg>
                      Call
                    </a>
                    <a
                      href={`sms:${a.profiles.phone}`}
                      className="btn-ghost flex-1 py-2 text-[13px]"
                    >
                      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.9-.9L3 21l2-4.1A8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z" />
                      </svg>
                      Text
                    </a>
                  </div>
                )}

                {a.status === 'pending' && (
                  <div className="grid grid-cols-2 gap-2 border-t border-soil-200/70 pt-3">
                    <button
                      className="btn-primary"
                      disabled={busy === a.id}
                      onClick={() => decide(a.id, 'accepted')}
                    >
                      Accept
                    </button>
                    <button
                      className="btn-ghost"
                      disabled={busy === a.id}
                      onClick={() => {
                            setRejecting(a)
                            setReason('')
                          }}
                    >
                      Reject
                    </button>
                  </div>
                )}
              </article>
            )
          })}
        </div>
      )}
    </div>
  )
}

function PostJobDialog({
  open,
  onClose,
  farmId,
  ownerId,
  defaultLocation,
  onSaved,
}: {
  open: boolean
  onClose(): void
  farmId: string
  ownerId: string
  defaultLocation: string
  onSaved(): void
}) {
  const [form, setForm] = useState({
    title: '',
    description: '',
    crop: 'general' as JobCrop,
    type: 'seasonal' as JobType,
    wage: '',
    slots: '',
    location: defaultLocation,
    start_date: todayISO(),
    end_date: '',
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      title: validateRequired(form.title, 'Job title'),
      wage: validateAmount(form.wage, 'daily wage'),

      slots: validateWholeNumber(form.slots, 1, 'number of slots'),
      location: validateRequired(form.location, 'Location'),
      start_date: form.start_date ? null : 'Pick a start date.',
      end_date:
        form.end_date && form.end_date < form.start_date
          ? 'The end date cannot come before the start date.'
          : null,
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    const { error } = await supabase.from('job_posts').insert({
      farm_id: farmId,
      owner_id: ownerId,
      title: form.title.trim(),
      description: form.description.trim(),
      crop: form.crop,
      type: form.type,
      wage: Number(form.wage),
      slots: parseInt(form.slots, 10),
      location: form.location.trim(),
      start_date: form.start_date,
      end_date: form.end_date || null,
      status: 'open',
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Job posted')
    setForm((f) => ({ ...f, title: '', description: '', wage: '', slots: '' }))
    onSaved()
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Post a job"
      description="Open posts appear on the farmer job board immediately."
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Posting…' : 'Post job'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <Field
          label="Job title"
          placeholder="e.g. Rice harvest crew"
          value={form.title}
          error={errors.title}
          onChange={(e) => set('title', e.target.value)}
        />
        <TextArea
          label="Description"
          placeholder="What the work involves, hours, what to bring"
          value={form.description}
          onChange={(e) => set('description', e.target.value)}
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => set('crop', e.target.value)}
            options={JOB_CROPS.map((c) => ({
              value: c,
              label: `${CROP_EMOJI[c]} ${c === 'general' ? 'General farm work' : titleCase(c)}`,
            }))}
          />
          <Select
            label="Job type"
            value={form.type}
            onChange={(e) => set('type', e.target.value)}
            options={JOB_TYPES.map((t) => ({ value: t, label: titleCase(t) }))}
          />
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <PesoInput
            label="Daily wage"
            placeholder="0.00"
            value={form.wage}
            error={errors.wage}
            onChange={(e) => set('wage', e.target.value)}
          />
          <div>
            <label className="label" htmlFor="slots">
              Number of slots
            </label>
            <input
              id="slots"
              type="number"
              step="1"
              min="1"
              inputMode="numeric"
              placeholder="0"
              className={`field num ${errors.slots ? 'field-error' : ''}`}
              value={form.slots}
              onKeyDown={(e) => ['.', ',', 'e', 'E', '+', '-'].includes(e.key) && e.preventDefault()}
              onChange={(e) => set('slots', e.target.value)}
            />
            {errors.slots ? (
              <p className="err">{errors.slots}</p>
            ) : (
              <p className="mt-1.5 text-[13px] text-soil-400">How many workers you need</p>
            )}
          </div>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label className="label" htmlFor="sd">
              Start date
            </label>
            <input
              id="sd"
              type="date"
              className={`field num ${errors.start_date ? 'field-error' : ''}`}
              value={form.start_date}
              onChange={(e) => set('start_date', e.target.value)}
            />
            {errors.start_date && <p className="err">{errors.start_date}</p>}
          </div>
          <div>
            <label className="label" htmlFor="ed">
              End date
            </label>
            <input
              id="ed"
              type="date"
              className={`field num ${errors.end_date ? 'field-error' : ''}`}
              value={form.end_date}
              onChange={(e) => set('end_date', e.target.value)}
            />
            {errors.end_date ? (
              <p className="err">{errors.end_date}</p>
            ) : (
              <p className="mt-1.5 text-[13px] text-soil-400">Optional</p>
            )}
          </div>
        </div>

        <Field
          label="Location"
          placeholder="Barangay, city or municipality"
          value={form.location}
          error={errors.location}
          onChange={(e) => set('location', e.target.value)}
        />
      </form>
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Account.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { RatingBadge } from '@/components/Ratings'
import { Field, SectionHeading, Spinner } from '@/components/ui'
import { friendlyError, normalisePhone, validateName, validatePhone } from '@/lib/validation'

export default function OwnerAccount() {
  const { profile, farm, refresh } = useAuth()
  const [form, setForm] = useState<Record<string, string>>({})
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!profile) return
    setForm({
      name: profile.name ?? '',
      phone: profile.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile.phone ?? '',
      email: profile.email ?? '',
      farm_name: farm?.name ?? '',
      address: farm?.address ?? '',
      city: farm?.city ?? '',
      latitude: farm?.latitude != null ? String(farm.latitude) : '',
      longitude: farm?.longitude != null ? String(farm.longitude) : '',
      province: farm?.province ?? '',
      zip_code: farm?.zip_code ?? '',
    })
  }, [profile?.id, farm?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile || !farm) return

    const next = { name: validateName(form.name), phone: validatePhone(form.phone) }
    setErrors(next)
    if (next.name || next.phone) return

    const normalised = normalisePhone(form.phone)!

    if (normalised !== profile.phone && (await isPhoneTakenForRole(normalised, 'owner'))) {
      const msg = 'This number is already registered as a Farm Owner. Use a different number.'
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    setBusy(true)
    const [p, f] = await Promise.all([
      supabase
        .from('profiles')
        .update({
          name: form.name.trim(),
          phone: normalised,
          email: form.email.trim() || null,
        })
        .eq('id', profile.id),
      supabase
        .from('farms')
        .update({
          name: form.farm_name.trim() || 'My Farm',
          address: form.address.trim(),
          city: form.city.trim(),
        latitude: form.latitude ? Number(form.latitude) : null,
        longitude: form.longitude ? Number(form.longitude) : null,
          province: form.province.trim(),
          zip_code: form.zip_code.trim(),
        })
        .eq('id', farm.id),
    ])
    setBusy(false)

    const err = p.error ?? f.error
    if (err) {
      const msg = /profiles_phone_role_key/.test(err.message)
        ? 'This number is already registered as a Farm Owner. Use a different number.'
        : friendlyError(err)
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    toast.success('Account saved')
    await refresh()
  }

  if (!profile) return <Spinner />

  return (
    <div className="space-y-6">
      <h1 className="text-[22px] font-bold">Account</h1>

      <AccountHeader subtitle={farm?.name} />

      <form onSubmit={save} className="space-y-5" noValidate>
        <section>
          <SectionHeading>Your details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Full name" value={form.name ?? ''} error={errors.name} onChange={(e) => set('name', e.target.value)} />
            <Field
              label="Mobile number"
              type="tel"
              inputMode="tel"
              value={form.phone ?? ''}
              error={errors.phone}
              onChange={(e) => set('phone', e.target.value)}
            />
            <Field
              label="Email"
              type="email"
              placeholder="Needed for password resets"
              className="sm:col-span-2"
              value={form.email ?? ''}
              onChange={(e) => set('email', e.target.value)}
            />
          </div>
        </section>

        <section>
          <SectionHeading>Your farm</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Farm name" className="sm:col-span-2" value={form.farm_name ?? ''} onChange={(e) => set('farm_name', e.target.value)} />
            <Field label="Address" className="sm:col-span-2" value={form.address ?? ''} onChange={(e) => set('address', e.target.value)} />
            <Field label="City or municipality" value={form.city ?? ''} onChange={(e) => set('city', e.target.value)} />
            <Field label="Province" value={form.province ?? ''} onChange={(e) => set('province', e.target.value)} />
            <Field label="ZIP code" inputMode="numeric" value={form.zip_code ?? ''} onChange={(e) => set('zip_code', e.target.value)} />
          </div>
        </section>

        <button className="btn-primary w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </form>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Orders.tsx' @'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  DataTable,
  Dialog,
  Empty,
  SectionHeading,
  Spinner,
  Stat,
  TextArea,
  ViewToggle,
} from '@/components/ui'
import { BuyerContactCard } from '@/components/BuyerContactCard'
import { OrderTimeline, StageBadge } from '@/components/OrderTimeline'
import {
  CROP_EMOJI,
  ORDER_STAGES,
  STAGE_LABEL,
  effectiveStage,
  isFinishedOrder,
  peso,
  pesoShort,
  sacks,
  shortDate,
  stageIndex,
} from '@/lib/format'
import { displayPhone, friendlyError } from '@/lib/validation'
import type { Order, OrderEvent, OrderStage, Profile } from '@/lib/types'

type Row = Order & { buyer?: Profile | null }

const TABS: { key: string; label: string; match: (o: Order) => boolean }[] = [
  { key: 'action', label: 'Needs action', match: (o) => !isFinishedOrder(o) },
  { key: 'all', label: 'All', match: () => true },
  { key: 'placed', label: 'To Confirm', match: (o) => effectiveStage(o) === 'placed' },
  { key: 'confirmed', label: 'Order Confirmed', match: (o) => effectiveStage(o) === 'confirmed' },
  { key: 'shipped', label: 'Out for Delivery', match: (o) => effectiveStage(o) === 'shipped' },
  { key: 'unpaid', label: 'Unpaid', match: (o) => !o.paid && effectiveStage(o) !== 'cancelled' },
  { key: 'completed', label: 'Completed', match: (o) => effectiveStage(o) === 'completed' },
  { key: 'cancelled', label: 'Cancelled', match: (o) => effectiveStage(o) === 'cancelled' },
]

export default function OwnerOrders() {
  const { farm } = useAuth()
  const [rows, setRows] = useState<Row[] | null>(null)
  const [events, setEvents] = useState<Record<string, OrderEvent[]>>({})
  const [filter, setFilter] = useState<string>('action')
  const [acting, setActing] = useState<{ order: Row; stage: OrderStage } | null>(null)
  const [view, setView] = useState<'grid' | 'table'>('table')
  const [settling, setSettling] = useState<string | null>(null)
  const [sukiCounts, setSukiCounts] = useState<Record<string, number>>({})
  const [error, setError] = useState<string | null>(null)

  async function togglePaid(o: Row) {
    setSettling(o.id)
    const { error } = await supabase.rpc('set_order_paid', {
      p_order_id: o.id,
      p_paid: !o.paid,
    })
    setSettling(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(o.paid ? 'Payment undone' : 'Order marked as paid')
    load()
  }

  const load = useCallback(async () => {
    if (!farm) return
    const { data, error: qError } = await supabase
      .from('orders')
      .select('*, products!inner(variety, crop, price, farm_id), profiles!orders_buyer_id_fkey(*)')
      .eq('products.farm_id', farm.id)
      .order('created_at', { ascending: false })

    if (qError) {
      setError(qError.message)
      setRows([])
      return
    }
    setError(null)

    const list = ((data as any[]) ?? []).map((o) => ({ ...o, buyer: (o.profiles as Profile) ?? null }))
    setRows(list)

    const counts: Record<string, number> = {}
    for (const o of list) {
      if (o.stage === 'completed' && o.buyer_id) {
        counts[o.buyer_id] = (counts[o.buyer_id] ?? 0) + 1
      }
    }
    setSukiCounts(counts)

    if (list.length) {
      const { data: evs } = await supabase
        .from('order_events')
        .select('*')
        .in('order_id', list.map((o) => o.id))
        .order('created_at', { ascending: true })

      const grouped: Record<string, OrderEvent[]> = {}
      for (const e of (evs as OrderEvent[]) ?? []) {
        ;(grouped[e.order_id] ??= []).push(e)
      }
      setEvents(grouped)
    }
  }, [farm?.id])

  useEffect(() => {
    load()
    if (!farm) return

    const channel = supabase
      .channel(`owner-orders-${farm.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [farm?.id, load])

  const filtered = useMemo(() => {
    const tab = TABS.find((t) => t.key === filter) ?? TABS[0]
    return (rows ?? []).filter(tab.match)
  }, [rows, filter])

  const activeList = useMemo(() => filtered.filter((o) => !isFinishedOrder(o)), [filtered])
  const doneList = useMemo(() => filtered.filter((o) => isFinishedOrder(o)), [filtered])

  if (!rows) return <Spinner label="Loading your orders" />

  const open = rows.filter((o) => !isFinishedOrder(o)).length
  const earned = rows
    .filter((o) => effectiveStage(o) !== 'cancelled')
    .reduce((s, o) => s + Number(o.total_price), 0)

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Move each order along so the buyer can follow its progress.
        </p>
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700"
        >
          <p className="font-semibold">Orders could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
          <button onClick={load} className="mt-2 font-semibold underline">
            Try again
          </button>
        </div>
      )}

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="All orders" value={String(rows.length)} />
        <Stat label="Needs action" value={String(open)} accent={open ? 'red' : undefined} />
        <Stat label="Sales value" value={pesoShort(earned)} accent="green" />
      </div>

      <div className="flex items-end justify-between gap-3">
        <div className="-mx-4 min-w-0 flex-1 overflow-x-auto px-4 lg:mx-0 lg:px-0">
          <div role="tablist" className="scrollbar-none flex min-w-max gap-1 border-b border-soil-200">
            {TABS.map((t) => {
              const count = (rows ?? []).filter(t.match).length
              return (
                <button
                  key={t.key}
                  role="tab"
                  aria-selected={filter === t.key}
                  onClick={() => setFilter(t.key)}
                  className={`whitespace-nowrap border-b-2 px-4 py-2.5 text-[13px] font-semibold transition ${
                    filter === t.key
                      ? 'border-brand-600 text-brand-700'
                      : 'border-transparent text-soil-600 hover:text-soil-900'
                  }`}
                >
                  {t.label}
                  {count > 0 && <span className="num ml-1 text-brand-600">({count})</span>}
                </button>
              )
            })}
          </div>
        </div>
        <ViewToggle view={view} onChange={setView} />
      </div>

      {filtered.length === 0 ? (
        <Empty
          title="No orders here"
          body={
            rows.length === 0
              ? 'When a buyer orders from your market listings, it appears here.'
              : 'Nothing matches this filter.'
          }
        />
      ) : (
        <div className="space-y-6">
          {[
            { key: 'active', title: 'Incoming orders', list: activeList },
            { key: 'done', title: 'Completed orders', list: doneList },
          ]
            .filter((g) => g.list.length > 0)
            .map((group) => (
              <section key={group.key}>
                <SectionHeading>
                  {group.title}
                  <span className="num ml-2 text-soil-400">({group.list.length})</span>
                </SectionHeading>
                {view === 'table' ? (
                  <DataTable
                    minWidth="52rem"
                    headers={[
                      { label: 'Date' },
                      { label: 'Product' },
                      { label: 'Buyer' },
                      { label: 'Sacks', align: 'right' },
                      { label: 'Total', align: 'right' },
                      { label: 'Stage' },
                      { label: 'Payment' },
                      { label: 'Action', align: 'right' },
                    ]}
                  >
                    {group.list.map((o) => {
                      const st = effectiveStage(o)
                      const ni = stageIndex(st)
                      const next = ORDER_STAGES[ni + 1]?.stage
                      const canCancel = !['completed', 'cancelled', 'delivered'].includes(st)
                      return (
                        <tr key={o.id}>
                          <td className="num px-4 py-3 text-soil-600">
                            {shortDate(o.created_at)}
                          </td>
                          <td className="px-4 py-3 font-semibold">
                            {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                            {o.products?.variety ?? 'Product'}
                          </td>
                          <td className="px-4 py-3">
                            <span className="flex flex-wrap items-center gap-1.5">
                              <span className="text-soil-800">{o.buyer?.name ?? '—'}</span>
                              {(sukiCounts[o.buyer_id] ?? 0) >= 3 && (
                                <span
                                  title="A regular customer — three or more completed orders"
                                  className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-amber-800"
                                >
                                  <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                                    <path d="M12 2l2.9 6.1 6.6.9-4.8 4.6 1.2 6.6L12 17.1 6.1 20.2l1.2-6.6L2.5 9l6.6-.9z" />
                                  </svg>
                                  Suki
                                </span>
                              )}
                            </span>
                            {o.buyer?.phone && (
                              <a
                                href={`tel:${o.buyer.phone}`}
                                className="num block text-[12px] text-brand-700 underline"
                              >
                                {displayPhone(o.buyer.phone)}
                              </a>
                            )}
                          </td>
                          <td className="num px-4 py-3 text-right font-bold">
                            {sacks(o.quantity)}
                          </td>
                          <td className="num px-4 py-3 text-right font-bold text-brand-700">
                            {peso(o.total_price)}
                          </td>
                          <td className="px-4 py-3">
                            <StageBadge stage={st} />
                          </td>
                          <td className="px-4 py-3">
                            {st === 'cancelled' ? (
                              <span className="text-[12px] text-soil-400">—</span>
                            ) : o.paid ? (
                              <Badge tone="green">Paid</Badge>
                            ) : (
                              <button
                                className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                                disabled={settling === o.id}
                                onClick={() => togglePaid(o)}
                              >
                                {settling === o.id ? '…' : 'Mark paid'}
                              </button>
                            )}
                          </td>
                          <td className="px-4 py-3 text-right">
                            {next || canCancel ? (
                              <span className="inline-flex gap-1.5">
                                {next && (
                                  <button
                                    className="btn-sm bg-brand-600 text-white hover:bg-brand-700 disabled:opacity-40"
                                    disabled={next === 'completed' && !o.paid}
                                    title={
                                      next === 'completed' && !o.paid
                                        ? 'Mark the order as paid first'
                                        : undefined
                                    }
                                    onClick={() => setActing({ order: o, stage: next })}
                                  >
                                    {STAGE_LABEL[next]}
                                  </button>
                                )}
                                {canCancel && (
                                  <button
                                    className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                                    onClick={() => setActing({ order: o, stage: 'cancelled' })}
                                  >
                                    Cancel
                                  </button>
                                )}
                              </span>
                            ) : (
                              <span className="text-[12px] text-soil-400">Done</span>
                            )}
                          </td>
                        </tr>
                      )
                    })}
                  </DataTable>
                ) : (
                <div className="grid gap-3 lg:grid-cols-2">
                  {group.list.map((o) => {
            const stage = effectiveStage(o)
            const idx = stageIndex(stage)
            const nextStage = ORDER_STAGES[idx + 1]?.stage
            const cancellable = !['completed', 'cancelled'].includes(stage)

            return (
              <article key={o.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h2 className="text-[15px] font-bold">
                      {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                      {o.products?.variety ?? 'Product'}
                    </h2>
                    <p className="text-[12px] text-soil-400">
                      Ordered {shortDate(o.created_at)}
                    </p>
                  </div>
                  <StageBadge stage={stage} />
                </div>

                <dl className="space-y-1 text-[13px]">
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Quantity</dt>
                    <dd className="num font-semibold">{sacks(o.quantity)} sacks</dd>
                  </div>
                  <div className="flex justify-between border-t border-soil-200 pt-1">
                    <dt className="font-bold">Total</dt>
                    <dd className="num font-bold text-brand-700">{peso(o.total_price)}</dd>
                  </div>
                </dl>

                <BuyerContactCard buyer={o.buyer} />

                <details className="rounded-lg border border-soil-200">
                  <summary className="cursor-pointer px-3.5 py-2.5 text-[13px] font-semibold">
                    Progress
                  </summary>
                  <div className="border-t border-soil-200 px-3.5 py-3">
                    <OrderTimeline
                      stage={stage}
                      events={events[o.id] ?? []}
                      cancelReason={o.cancel_reason}
                    />
                  </div>
                </details>

                {(nextStage || cancellable) && (
                  <div className="grid grid-cols-2 gap-2 border-t border-soil-200 pt-3">
                    {nextStage ? (
                      <button
                        className="btn-primary py-2 text-[13px]"
                        onClick={() => setActing({ order: o, stage: nextStage })}
                      >
                        {STAGE_LABEL[nextStage]}
                      </button>
                    ) : (
                      <span />
                    )}
                    {cancellable && (
                      <button
                        className="btn-ghost py-2 text-[13px] text-red-600 hover:bg-red-50"
                        onClick={() => setActing({ order: o, stage: 'cancelled' })}
                      >
                        Cancel order
                      </button>
                    )}
                  </div>
                )}
                    </article>
                    )
                  })}
                </div>
                )}
              </section>
            ))}
        </div>
      )}

      <StageDialog
        acting={acting}
        onClose={() => setActing(null)}
        onDone={() => {
          setActing(null)
          load()
        }}
      />
    </div>
  )
}

function StageDialog({
  acting,
  onClose,
  onDone,
}: {
  acting: { order: Order; stage: OrderStage } | null
  onClose(): void
  onDone(): void
}) {
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (acting) setNote('')
  }, [acting?.order.id, acting?.stage])

  if (!acting) return null
  const cancelling = acting.stage === 'cancelled'

  async function confirm() {
    if (cancelling && !note.trim()) {
      toast.error('Give the buyer a reason for the cancellation.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('set_order_stage', {
      p_order_id: acting!.order.id,
      p_stage: acting!.stage,
      p_note: note.trim(),
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(cancelling ? 'Order cancelled — stock returned' : `Marked as ${STAGE_LABEL[acting!.stage]}`)
    onDone()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={cancelling ? 'Cancel this order?' : `Mark as ${STAGE_LABEL[acting.stage]}?`}
      description={acting.order.products?.variety}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Go back
          </button>
          <button
            className={cancelling ? 'btn-danger' : 'btn-primary'}
            onClick={confirm}
            disabled={busy}
          >
            {busy ? 'Saving…' : cancelling ? 'Cancel order' : 'Confirm'}
          </button>
        </>
      }
    >
      <div className="space-y-3">
        {cancelling ? (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-[13px] leading-relaxed text-amber-900">
            The {sacks(acting.order.quantity)} sacks go back into your stock, and a refund entry is
            added to your books so Finance stays accurate.
          </div>
        ) : (
          <p className="text-[14px] leading-relaxed text-soil-800">
            The buyer is notified straight away and sees this stage on their order timeline.
          </p>
        )}

        <TextArea
          label={cancelling ? 'Reason for the buyer' : 'Note for the buyer'}
          max={200}
          placeholder={cancelling ? 'e.g. Harvest was damaged by rain' : 'Optional'}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </div>
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\owner\Attendance.tsx' @'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  Dialog,
  Empty,
  Field,
  SectionHeading,
  Select,
  Spinner,
  Stat,
  TextArea,
} from '@/components/ui'
import {
  ATTENDANCE_LABEL,
  hours,
  peso,
  pesoShort,
  relativeDate,
  shortDate,
  toISODate,
} from '@/lib/format'
import { friendlyError, validateAmount } from '@/lib/validation'
import type { AttendanceRow } from '@/lib/types'


function clockTime(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
}

export default function OwnerAttendance() {
  const { profile, farm } = useAuth()
  const [rows, setRows] = useState<AttendanceRow[] | null>(null)
  const [month, setMonth] = useState(() => new Date().toISOString().slice(0, 7))
  const [paying, setPaying] = useState<string | null>(null)
  const [workerFilter, setWorkerFilter] = useState('all')
  const [staff, setStaff] = useState<{ id: string; name: string }[]>([])
  const [statusFilter, setStatusFilter] = useState('all')
  const [taskFilter, setTaskFilter] = useState('all')
  const [payFilter, setPayFilter] = useState('all')

  async function togglePaid(row: AttendanceRow, send: boolean) {
    setPaying(row.id)
    const { error } = await supabase.rpc('set_attendance_paid', {
      p_attendance_id: row.id,
      p_paid: send,
    })
    setPaying(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(
      send ? 'Marked as sent — waiting for the worker to confirm' : 'Payment cancelled',
    )
    load()
  }

  const load = useCallback(async () => {
    if (!farm || !profile) return

    const start = `${month}-01`
    const [y, m] = month.split('-').map(Number)
    const end = toISODate(new Date(y, m, 0))

    const { data } = await supabase
      .from('attendance')
      .select('*, profiles!attendance_farmer_id_fkey(*), job_posts(title)')
      .eq('farm_id', farm.id)
      .gte('work_date', start)
      .lte('work_date', end)
      .order('work_date', { ascending: false })

    setRows((data as unknown as AttendanceRow[]) ?? [])

    if (profile) {
      const { data: jobs } = await supabase
        .from('job_posts')
        .select('id')
        .eq('owner_id', profile.id)
      const ids = (jobs ?? []).map((j) => j.id)
      if (ids.length) {
        const { data: hired } = await supabase
          .from('job_applications')
          .select('farmer_id, profiles(id, name)')
          .in('job_id', ids)
          .eq('status', 'accepted')
        const seen = new Map<string, string>()
        for (const h of (hired as any[]) ?? []) {
          if (h.profiles?.id) seen.set(h.profiles.id, h.profiles.name)
        }
        setStaff([...seen].map(([id, name]) => ({ id, name })))
      } else {
        setStaff([])
      }
    }

  }, [farm?.id, profile?.id, month])

  useEffect(() => {
    load()
  }, [load])

  const tasks = useMemo(
    () => [...new Set((rows ?? []).map((r) => r.task).filter(Boolean))].sort(),
    [rows],
  )

  const shown = useMemo(
    () =>
      (rows ?? []).filter((r) => {
        if (workerFilter !== 'all' && r.farmer_id !== workerFilter) return false
        if (statusFilter !== 'all' && r.status !== statusFilter) return false
        if (taskFilter !== 'all' && r.task !== taskFilter) return false
        if (payFilter !== 'all' && r.payment_status !== payFilter) return false
        return true
      }),
    [rows, workerFilter, statusFilter, taskFilter, payFilter],
  )

  const totals = useMemo(() => {
    const list = shown
    return {
      hours: list.reduce((s, r) => s + Number(r.hours_worked), 0),
      pay: list.reduce((s, r) => s + Number(r.computed_pay), 0),
      unpaid: list
        .filter((r) => r.payment_status !== 'paid')
        .reduce((s, r) => s + Number(r.computed_pay), 0),
      absent: list.filter((r) => r.status === 'absent').length,
      days: list.length,
    }
  }, [shown])

  if (!rows) return <Spinner label="Loading the work log" />

  return (
    <div className="space-y-6">

      <div className="no-print flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Daily work log</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            Times your workers clocked in and out. Each completed day earns the agreed wage for the
          job, whatever the hours.
          </p>
        </div>

      </div>

      {staff.length > 0 && (
        <div className="no-print">
          <p className="mb-2 text-[13px] font-semibold text-soil-600">Hired workers</p>
          <div className="flex flex-wrap gap-2">
            <button
              onClick={() => setWorkerFilter('all')}
              aria-pressed={workerFilter === 'all'}
              className={`chip border px-3 py-1.5 text-[13px] transition ${
                workerFilter === 'all'
                  ? 'border-brand-600 bg-brand-600 text-white'
                  : 'border-soil-200 bg-white text-soil-700 hover:bg-soil-100'
              }`}
            >
              Everyone
            </button>

            {staff.map((w) => {
              const days = (rows ?? []).filter((r) => r.farmer_id === w.id).length
              const active = workerFilter === w.id
              return (
                <button
                  key={w.id}
                  onClick={() => setWorkerFilter(active ? 'all' : w.id)}
                  aria-pressed={active}
                  className={`chip border px-3 py-1.5 text-[13px] transition ${
                    active
                      ? 'border-brand-600 bg-brand-600 text-white'
                      : 'border-soil-200 bg-white text-soil-700 hover:bg-soil-100'
                  }`}
                >
                  {w.name}
                  {days > 0 && (
                    <span className={`num ml-1 ${active ? 'text-white/80' : 'text-soil-400'}`}>
                      {days}
                    </span>
                  )}
                </button>
              )
            })}
          </div>
        </div>
      )}

      <div className="no-print grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div>
          <label className="label" htmlFor="month">
            Month
          </label>
          <input
            id="month"
            type="month"
            className="field num"
            value={month}
            onChange={(e) => setMonth(e.target.value)}
          />
        </div>
        <Select
          label="Worker"
          value={workerFilter}
          onChange={(e) => setWorkerFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All workers' },
            ...staff.map((w) => ({ value: w.id, label: w.name })),
          ]}
        />
        <Select
          label="Task"
          value={taskFilter}
          onChange={(e) => setTaskFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All tasks' },
            ...tasks.map((t) => ({ value: t, label: t })),
          ]}
        />
        <Select
          label="Attendance"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All' },
            { value: 'present', label: 'Present' },
            { value: 'absent', label: 'Absent' },
            { value: 'half_day', label: 'Half day' },
            { value: 'leave', label: 'On leave' },
          ]}
        />
        <Select
          label="Payment"
          value={payFilter}
          onChange={(e) => setPayFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All' },
            { value: 'unpaid', label: 'Unpaid only' },
            { value: 'paid', label: 'Paid only' },
          ]}
        />
      </div>

      <div className="print-only mb-4">
        <h1 className="text-xl font-bold">{farm?.name ?? 'Farm'} — Daily Work Log</h1>
        <p className="text-[13px] text-soil-600">
          {new Date(`${month}-01`).toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
          {' · Standard day: '}
          {hours(farm?.standard_hours ?? 8)} hours
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Days recorded" value={String(totals.days)} />
        <Stat label="Total hours" value={hours(totals.hours)} />
        <Stat label="Absences" value={String(totals.absent)} accent={totals.absent ? 'red' : undefined} />
        <Stat label="Wages earned" value={pesoShort(totals.pay)} accent="green" />
        <Stat
          label="Still unpaid"
          value={pesoShort(totals.unpaid)}
          accent={totals.unpaid > 0 ? 'red' : undefined}
          sub={totals.unpaid > 0 ? 'Owed to workers' : 'All settled'}
        />
      </div>

      {shown.length === 0 ? (
        <Empty
          title="Nothing logged this month"
          body="Record a day for anyone you have hired. Their hours and pay build up here."
        />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[42rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Date</th>
                <th className="px-4 py-2.5 font-semibold">Worker</th>
                <th className="px-4 py-2.5 font-semibold">Task</th>
                <th className="px-4 py-2.5 font-semibold">Time in</th>
                <th className="px-4 py-2.5 font-semibold">Time out</th>
                <th className="px-4 py-2.5 font-semibold">Status</th>
                <th className="px-4 py-2.5 text-right font-semibold">Break</th>
                <th className="px-4 py-2.5 text-right font-semibold">Hours</th>
                <th className="px-4 py-2.5 text-right font-semibold">Daily wage</th>
                <th className="px-4 py-2.5 text-right font-semibold">Pay earned</th>
                <th className="px-4 py-2.5 text-center font-semibold">Payment</th>
                <th className="no-print px-4 py-2.5 text-right font-semibold">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {shown.map((r) => {
                return (
                  <tr key={r.id} className={r.status === 'absent' ? 'bg-red-50/60' : ''}>
                    <td className="num px-4 py-2.5">{shortDate(r.work_date)}</td>
                    <td className="px-4 py-2.5 font-semibold">{r.profiles?.name ?? '—'}</td>
                    <td className="px-4 py-2.5 text-soil-600">
                      {r.task || r.job_posts?.title || '—'}
                    </td>
                    <td className="num px-4 py-2.5">{clockTime(r.time_in)}</td>
                    <td className="num px-4 py-2.5">
                      {r.time_out ? (
                        clockTime(r.time_out)
                      ) : r.time_in ? (
                        <span className="text-amber-600">Still in</span>
                      ) : (
                        '—'
                      )}
                    </td>
                    <td className="px-4 py-2.5">
                      <Badge
                        tone={
                          r.status === 'present'
                            ? 'green'
                            : r.status === 'absent'
                              ? 'red'
                              : r.status === 'half_day'
                                ? 'amber'
                                : 'grey'
                        }
                      >
                        {ATTENDANCE_LABEL[r.status]}
                      </Badge>
                    </td>
                    <td className="num px-4 py-2.5 text-right text-soil-500">
                      {r.break_minutes > 0 ? `${Math.round(r.break_minutes)}m` : '—'}
                    </td>
                    <td className="num px-4 py-2.5 text-right font-semibold">
                      {hours(r.hours_worked)}
                    </td>
                    <td className="num px-4 py-2.5 text-right text-soil-600">
                      {peso(r.daily_wage)}
                    </td>
                    <td className="num px-4 py-2.5 text-right font-bold">
                      {peso(r.computed_pay)}
                      {r.status === 'half_day' && (
                        <span className="block text-[11px] font-medium text-amber-700">
                          Half day
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-2.5 text-center">
                      {Number(r.computed_pay) <= 0 ? (
                        <span className="text-[12px] text-soil-400">—</span>
                      ) : r.payment_status === 'paid' ? (
                        <Badge tone="green">Paid</Badge>
                      ) : r.payment_status === 'pending' ? (
                        <Badge tone="amber">Pending</Badge>
                      ) : (
                        <Badge tone="grey">Unpaid</Badge>
                      )}
                    </td>
                    <td className="no-print px-4 py-2.5 text-right">
                      {Number(r.computed_pay) <= 0 ? null : r.payment_status === 'paid' ? (
                        <span className="text-[12px] text-soil-400">
                          Confirmed {r.payment_confirmed_at ? relativeDate(r.payment_confirmed_at) : ''}
                        </span>
                      ) : r.payment_status === 'pending' ? (
                        <span className="inline-flex flex-col items-end gap-1">
                          <span className="text-[12px] text-amber-700">
                            Waiting for the worker to confirm
                          </span>
                          <button
                            disabled={paying === r.id}
                            onClick={() => togglePaid(r, false)}
                            className="btn-sm border border-soil-200 text-soil-600 hover:bg-soil-100"
                          >
                            {paying === r.id ? '…' : 'Cancel'}
                          </button>
                        </span>
                      ) : (
                        <button
                          disabled={paying === r.id}
                          onClick={() => togglePaid(r, true)}
                          className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                        >
                          {paying === r.id ? '…' : 'Mark paid'}
                        </button>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
            <tfoot className="border-t-2 border-soil-200 bg-soil-50 font-bold">
              <tr>
                <td className="px-4 py-2.5" colSpan={7}>
                  Total
                </td>
                <td className="num px-4 py-2.5 text-right">{hours(totals.hours)}</td>
                <td />
                <td className="num px-4 py-2.5 text-right">{peso(totals.pay)}</td>
                <td colSpan={2} />
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      <div className="print-only mt-10 grid grid-cols-2 gap-12 text-[13px]">
        <div>
          <div className="h-10 border-b border-soil-800" />
          <p className="mt-1">Prepared by</p>
        </div>
        <div>
          <div className="h-10 border-b border-soil-800" />
          <p className="mt-1">Received by</p>
        </div>
      </div>

    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\admin\Dashboard.tsx' @'
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Badge, DataTable, Dialog, Empty, SectionHeading, Spinner, Stat, TextArea } from '@/components/ui'
import { TopFarms } from '@/components/TopFarms'
import { pesoShort, relativeDate, shortDate } from '@/lib/format'
import { displayPhone, friendlyError } from '@/lib/validation'
import type { OwnerVerification } from '@/lib/types'

interface Stats {
  owners: number
  farmers: number
  buyers: number
  pending_reviews: number
  products: number
  out_of_stock: number
  orders: number
  open_orders: number
  revenue: number
}

export function AdminDashboard() {
  const [stats, setStats] = useState<Stats | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    ;(async () => {
      const { data, error: rpcError } = await supabase.rpc('admin_stats')
      if (rpcError) {
        setError(rpcError.message)
        return
      }
      setStats(data as Stats)
    })()
  }, [])

  if (error) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
        {error}
      </div>
    )
  }
  if (!stats) return <Spinner label="Loading system overview" />

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">System overview</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Everything across FARMS at a glance.
        </p>
      </div>

      {stats.pending_reviews > 0 && (
        <Link
          to="/admin/verifications"
          className="block rounded-xl border border-amber-300 bg-amber-50 px-4 py-3.5 transition hover:shadow-sm"
        >
          <p className="text-[14px] font-bold text-amber-900">
            {stats.pending_reviews} Farm Owner{stats.pending_reviews === 1 ? '' : 's'} waiting for
            verification
          </p>
          <p className="mt-0.5 text-[13px] text-amber-800">
            They cannot use their account until you review them. Tap to open.
          </p>
        </Link>
      )}

      <section>
        <SectionHeading>People</SectionHeading>
        <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="Farm owners" value={String(stats.owners)} />
          <Stat label="Farmers" value={String(stats.farmers)} />
          <Stat label="Buyers" value={String(stats.buyers)} />
          <Stat
            label="Awaiting review"
            value={String(stats.pending_reviews)}
            accent={stats.pending_reviews ? 'red' : undefined}
          />
        </div>
      </section>

      <section>
        <SectionHeading>Top selling farms</SectionHeading>
        <TopFarms limit={10} />
      </section>

      <section>
        <SectionHeading>Marketplace</SectionHeading>
        <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="Products listed" value={String(stats.products)} />
          <Stat
            label="Out of stock"
            value={String(stats.out_of_stock)}
            accent={stats.out_of_stock ? 'red' : undefined}
          />
          <Stat label="Orders placed" value={String(stats.orders)} sub={`${stats.open_orders} in progress`} />
          <Stat label="Total sales" value={pesoShort(stats.revenue)} accent="green" />
        </div>
      </section>
    </div>
  )
}

export function AdminVerifications() {
  const [rows, setRows] = useState<OwnerVerification[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [tab, setTab] = useState<'pending' | 'approved' | 'rejected'>('pending')
  const [acting, setActing] = useState<{ row: OwnerVerification; approve: boolean } | null>(null)
  const [viewing, setViewing] = useState<OwnerVerification | null>(null)

  const load = useCallback(async () => {
    const { data, error: qError } = await supabase
      .from('owner_verifications')
      .select('*, profiles!owner_verifications_profile_id_fkey(*)')
      .order('submitted_at', { ascending: false })

    if (qError) {
      setError(qError.message)
      setRows([])
      return
    }
    setError(null)
    setRows(
      ((data as any[]) ?? []).map((r) => ({
        ...r,
        profiles: r['profiles'] ?? null,
      })) as OwnerVerification[],
    )
  }, [])

  useEffect(() => {
    load()
    const channel = supabase
      .channel('admin-verifications')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'owner_verifications' }, () =>
        load(),
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  if (!rows) return <Spinner label="Loading verification requests" />

  const shown = rows.filter((r) => r.status === tab)
  const pending = rows.filter((r) => r.status === 'pending').length

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Farm Owner verification</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Check each applicant's identity and farm details before approving.
        </p>
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700"
        >
          <p className="font-semibold">Verification requests could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
          <button onClick={load} className="mt-2 font-semibold underline">
            Try again
          </button>
        </div>
      )}

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="Pending" value={String(pending)} accent={pending ? 'red' : undefined} />
        <Stat label="Approved" value={String(rows.filter((r) => r.status === 'approved').length)} />
        <Stat label="Rejected" value={String(rows.filter((r) => r.status === 'rejected').length)} />
      </div>

      <div role="tablist" className="grid grid-cols-3 gap-1 rounded-lg bg-soil-100 p-1">
        {(['pending', 'approved', 'rejected'] as const).map((t) => (
          <button
            key={t}
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            className={`rounded-md px-3 py-2 text-[13px] font-semibold capitalize transition ${
              tab === t ? 'bg-white shadow-sm' : 'text-soil-600'
            }`}
          >
            {t}
            {t === 'pending' && pending > 0 && (
              <span className="num ml-1.5 rounded-full bg-red-600 px-1.5 py-0.5 text-[10px] text-white">
                {pending}
              </span>
            )}
          </button>
        ))}
      </div>

      {shown.length === 0 ? (
        <Empty
          title={`Nothing ${tab}`}
          body={
            tab === 'pending'
              ? 'New Farm Owner applications appear here for review.'
              : `No ${tab} applications yet.`
          }
        />
      ) : (
        <DataTable
          minWidth="56rem"
          headers={[
            { label: 'Applicant' },
            { label: 'ID' },
            { label: 'Farm' },
            { label: 'Location' },
            { label: 'Submitted' },
            { label: 'Status' },
            { label: '', align: 'right' },
          ]}
        >
          {shown.map((r) => (
            <tr key={r.id} className="align-top">
              <td className="px-4 py-3">
                <span className="block font-semibold">{r.full_name || r.profiles?.name}</span>
                <span className="num block text-[12px] text-soil-400">
                  {displayPhone(r.profiles?.phone)}
                </span>
              </td>
              <td className="px-4 py-3">
                <span className="block text-[12px] text-soil-600">{r.id_type}</span>
                {r.id_photo_path ? (
                  <button
                    onClick={() => setViewing(r)}
                    className="mt-0.5 text-[12px] font-semibold text-brand-700 underline"
                  >
                    View photo
                  </button>
                ) : (
                  <span className="text-[12px] text-soil-400">No photo</span>
                )}
              </td>
              <td className="px-4 py-3">
                <span className="block font-semibold">{r.farm_name || '—'}</span>
                {r.farm_size_ha != null && (
                  <span className="num block text-[12px] text-soil-400">{r.farm_size_ha} ha</span>
                )}
              </td>
              <td className="px-4 py-3 text-soil-600">
                <span className="block">{r.barangay || '—'}</span>
                <span className="block text-[12px] text-soil-400">{r.farm_address || ''}</span>
              </td>
              <td className="num px-4 py-3 text-soil-600">{shortDate(r.submitted_at)}</td>
              <td className="px-4 py-3">
                <Badge
                  tone={r.status === 'approved' ? 'green' : r.status === 'rejected' ? 'red' : 'amber'}
                >
                  {r.status}
                </Badge>
                {r.review_notes && (
                  <span className="mt-1 block max-w-[12rem] text-[11px] leading-snug text-soil-400">
                    {r.review_notes}
                  </span>
                )}
              </td>
              <td className="px-4 py-3 text-right">
                {r.status === 'pending' ? (
                  <span className="inline-flex gap-1.5">
                    <button
                      className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                      onClick={() => setActing({ row: r, approve: true })}
                    >
                      Approve
                    </button>
                    <button
                      className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                      onClick={() => setActing({ row: r, approve: false })}
                    >
                      Reject
                    </button>
                  </span>
                ) : (
                  <span className="text-[12px] text-soil-400">
                    {r.reviewed_at ? relativeDate(r.reviewed_at) : '—'}
                  </span>
                )}
              </td>
            </tr>
          ))}
        </DataTable>
      )}

      <IdPhotoDialog record={viewing} onClose={() => setViewing(null)} />

      <ReviewDialog
        acting={acting}
        onClose={() => setActing(null)}
        onDone={() => {
          setActing(null)
          load()
        }}
      />
    </div>
  )
}

function IdPhotoDialog({
  record,
  onClose,
}: {
  record: OwnerVerification | null
  onClose(): void
}) {
  const [url, setUrl] = useState<string | null>(null)
  const [selfieUrl, setSelfieUrl] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    setUrl(null)
    setSelfieUrl(null)
    setFailed(false)
    if (record?.id_photo_path) {
      supabase.storage
        .from('verification-ids')
        .createSignedUrl(record.id_photo_path, 600)
        .then(({ data, error }) => {
          if (error || !data?.signedUrl) setFailed(true)
          else setUrl(data.signedUrl)
        })
    }
    if (record?.selfie_path) {
      supabase.storage
        .from('verification-ids')
        .createSignedUrl(record.selfie_path, 600)
        .then(({ data }) => {
          if (data?.signedUrl) setSelfieUrl(data.signedUrl)
        })
    }
  }, [record?.id])

  if (!record) return null

  return (
    <Dialog
      open
      onClose={onClose}
      title="Identity document"
      description={`${record.full_name || record.profiles?.name} · ${record.id_type}`}
      footer={
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      }
    >
      {failed ? (
        <p className="rounded-lg bg-red-50 px-4 py-3 text-[13px] text-red-700">
          The photo could not be loaded. It may have been removed.
        </p>
      ) : url || selfieUrl ? (
        <div className="space-y-4">
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-3.5 py-3">
            <p className="text-[13px] font-bold text-amber-900">Check before approving</p>
            <ul className="mt-1 list-disc space-y-0.5 pl-4 text-[13px] leading-relaxed text-amber-800">
              <li>Is the ID a real government ID, not a photo of a screen or a printout?</li>
              <li>Does the face on the ID match the face in the selfie?</li>
              <li>Do the name and date of birth on the ID match what they typed?</li>
              <li>Is the ID unexpired and readable?</li>
            </ul>
          </div>

          {url && (
            <div>
              <p className="mb-1.5 text-[12px] font-semibold uppercase tracking-wide text-soil-400">
                Identity document
              </p>
              <img
                src={url}
                alt={`ID document for ${record.full_name}`}
                className="w-full rounded-lg border border-soil-200 bg-soil-50 object-contain"
              />
            </div>
          )}

          {selfieUrl ? (
            <div>
              <p className="mb-1.5 text-[12px] font-semibold uppercase tracking-wide text-soil-400">
                Selfie with ID
              </p>
              <img
                src={selfieUrl}
                alt={`Selfie for ${record.full_name}`}
                className="w-full rounded-lg border border-soil-200 bg-soil-50 object-contain"
              />
            </div>
          ) : (
            <p className="rounded-lg bg-soil-50 px-3.5 py-3 text-[13px] text-soil-600">
              No selfie was submitted. This account was created before selfies were required.
            </p>
          )}
        </div>
      ) : (
        <Spinner label="Loading the photos" />
      )}
    </Dialog>
  )
}

function ReviewDialog({
  acting,
  onClose,
  onDone,
}: {
  acting: { row: OwnerVerification; approve: boolean } | null
  onClose(): void
  onDone(): void
}) {
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (acting) setNotes('')
  }, [acting?.row.id])

  if (!acting) return null
  const { row, approve } = acting

  async function confirm() {
    if (!approve && !notes.trim()) {
      toast.error('Give a reason so the applicant can correct it.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('review_owner_verification', {
      p_verification_id: row.id,
      p_decision: approve ? 'approved' : 'rejected',
      p_notes: notes.trim(),
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(approve ? 'Farm Owner approved' : 'Application rejected')
    onDone()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={approve ? 'Approve this Farm Owner?' : 'Reject this application?'}
      description={row.full_name || row.profiles?.name}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Go back
          </button>
          <button
            className={approve ? 'btn-primary' : 'btn-danger'}
            onClick={confirm}
            disabled={busy}
          >
            {busy ? 'Saving…' : approve ? 'Approve' : 'Reject'}
          </button>
        </>
      }
    >
      <div className="space-y-3">
        <p className="text-[14px] leading-relaxed text-soil-800">
          {approve
            ? 'They gain full access to Farm Owner functions, and their farm record is created automatically.'
            : 'They keep their account but stay locked out of Farm Owner functions. They can correct their details and apply again.'}
        </p>
        <TextArea
          label={approve ? 'Note (optional)' : 'Reason for rejection'}
          max={200}
          placeholder={approve ? 'Optional' : 'e.g. ID number does not match the name given'}
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
        />
      </div>
    </Dialog>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="shrink-0 text-soil-600">{label}</dt>
      <dd className="truncate text-right font-semibold">{value}</dd>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\admin\Manage.tsx' @'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Badge, Empty, Search, Select, Spinner, Stat } from '@/components/ui'
import { StageBadge } from '@/components/OrderTimeline'
import {
  CROP_EMOJI,
  ORDER_STAGES,
  ROLE_LABEL,
  effectiveStage,
  isFinishedOrder,
  STAGE_LABEL,
  peso,
  pesoShort,
  sacks,
  shortDate,
  titleCase,
} from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { Order, Product, Profile, Role } from '@/lib/types'

export function AdminUsers() {
  const [rows, setRows] = useState<Profile[] | null>(null)
  const [query, setQuery] = useState('')
  const [role, setRole] = useState<'all' | Role>('all')

  useEffect(() => {
    ;(async () => {
      const { data } = await supabase
        .from('profiles')
        .select('*')
        .order('created_at', { ascending: false })
      setRows((data as Profile[]) ?? [])
    })()
  }, [])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return (rows ?? []).filter((p) => {
      if (role !== 'all' && p.role !== role) return false
      if (!q) return true
      return (
        p.name.toLowerCase().includes(q) ||
        p.phone.includes(q) ||
        (p.company ?? '').toLowerCase().includes(q)
      )
    })
  }, [rows, query, role])

  if (!rows) return <Spinner label="Loading users" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Users</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every account on the system. One phone number can hold one account per role.
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        {(['owner', 'farmer', 'buyer', 'admin'] as Role[]).map((r) => (
          <Stat
            key={r}
            label={ROLE_LABEL[r]}
            value={String(rows.filter((p) => p.role === r).length)}
          />
        ))}
      </div>

      <div className="grid gap-3 sm:grid-cols-[1fr_12rem]">
        <Search value={query} onChange={setQuery} placeholder="Search name, phone or company" />
        <Select
          label=""
          value={role}
          onChange={(e) => setRole(e.target.value as typeof role)}
          options={[
            { value: 'all', label: 'All roles' },
            ...(['owner', 'farmer', 'buyer', 'admin'] as Role[]).map((r) => ({
              value: r,
              label: ROLE_LABEL[r],
            })),
          ]}
        />
      </div>

      {filtered.length === 0 ? (
        <Empty title="No users match" body="Try a different search or role." />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[36rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Name</th>
                <th className="px-4 py-2.5 font-semibold">Role</th>
                <th className="px-4 py-2.5 font-semibold">Phone</th>
                <th className="px-4 py-2.5 font-semibold">Joined</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {filtered.map((p) => (
                <tr key={p.id}>
                  <td className="px-4 py-2.5 font-semibold">
                    {p.name || '—'}
                    {p.company && (
                      <span className="block text-[12px] font-normal text-soil-400">
                        {p.company}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2.5">
                    <Badge tone={p.role === 'admin' ? 'red' : 'brand'}>{ROLE_LABEL[p.role]}</Badge>
                  </td>
                  <td className="num px-4 py-2.5">{displayPhone(p.phone)}</td>
                  <td className="num px-4 py-2.5 text-soil-600">{shortDate(p.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

export function AdminCatalog() {
  const [rows, setRows] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('*, farms(name, city, province)')
      .order('created_at', { ascending: false })
    setRows((data as unknown as Product[]) ?? [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return rows ?? []
    return (rows ?? []).filter(
      (p) =>
        p.variety.toLowerCase().includes(q) ||
        p.crop.toLowerCase().includes(q) ||
        (p.farms?.name ?? '').toLowerCase().includes(q),
    )
  }, [rows, query])

  if (!rows) return <Spinner label="Loading products" />

  const out = rows.filter((p) => p.quantity === 0).length

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Products &amp; stock</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every listing across all farms. Stock is managed by each farm owner.
        </p>
      </div>

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="Listings" value={String(rows.length)} />
        <Stat label="Out of stock" value={String(out)} accent={out ? 'red' : undefined} />
        <Stat
          label="Stock value"
          value={pesoShort(rows.reduce((s, p) => s + p.quantity * Number(p.price), 0))}
          accent="green"
        />
      </div>

      <Search value={query} onChange={setQuery} placeholder="Search variety, crop or farm" />

      {filtered.length === 0 ? (
        <Empty title="No products match" body="Try a different search." />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[42rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Product</th>
                <th className="px-4 py-2.5 font-semibold">Farm</th>
                <th className="px-4 py-2.5 text-right font-semibold">Stock</th>
                <th className="px-4 py-2.5 text-right font-semibold">Price</th>
                <th className="px-4 py-2.5 font-semibold">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {filtered.map((p) => (
                <tr key={p.id} className={p.quantity === 0 ? 'bg-red-50/50' : ''}>
                  <td className="px-4 py-2.5 font-semibold">
                    {CROP_EMOJI[p.crop]} {p.variety}
                  </td>
                  <td className="px-4 py-2.5 text-soil-600">{p.farms?.name ?? '—'}</td>
                  <td className="num px-4 py-2.5 text-right font-bold">{sacks(p.quantity)}</td>
                  <td className="num px-4 py-2.5 text-right">{peso(p.price)}</td>
                  <td className="px-4 py-2.5">
                    <Badge
                      tone={p.quantity === 0 ? 'red' : p.quantity <= 5 ? 'amber' : 'green'}
                    >
                      {p.quantity === 0 ? 'Out of stock' : p.quantity <= 5 ? 'Low' : 'Available'}
                    </Badge>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

    </div>
  )
}

export function AdminOrders() {
  const [rows, setRows] = useState<Order[] | null>(null)
  const [stage, setStage] = useState('all')

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, products(*, farms(name)), profiles!orders_buyer_id_fkey(*)')
      .order('created_at', { ascending: false })
    setRows((data as unknown as Order[]) ?? [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const filtered = useMemo(
    () => (stage === 'all' ? (rows ?? []) : (rows ?? []).filter((o) => effectiveStage(o) === stage)),
    [rows, stage],
  )

  if (!rows) return <Spinner label="Loading orders" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">Every order placed across all farms.</p>
      </div>

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="All orders" value={String(rows.length)} />
        <Stat
          label="In progress"
          value={String(rows.filter((o) => !isFinishedOrder(o)).length)}
        />
        <Stat
          label="Sales value"
          value={pesoShort(
            rows.filter((o) => effectiveStage(o) !== 'cancelled').reduce((s, o) => s + Number(o.total_price), 0),
          )}
          accent="green"
        />
      </div>

      <div className="max-w-xs">
        <Select
          label="Stage"
          value={stage}
          onChange={(e) => setStage(e.target.value)}
          options={[
            { value: 'all', label: 'All stages' },
            ...ORDER_STAGES.map((s) => ({ value: s.stage, label: s.label })),
            { value: 'cancelled', label: 'Cancelled' },
          ]}
        />
      </div>

      {filtered.length === 0 ? (
        <Empty title="No orders here" body="Nothing matches this filter." />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[46rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Date</th>
                <th className="px-4 py-2.5 font-semibold">Product</th>
                <th className="px-4 py-2.5 font-semibold">Farm</th>
                <th className="px-4 py-2.5 font-semibold">Buyer</th>
                <th className="px-4 py-2.5 text-right font-semibold">Sacks</th>
                <th className="px-4 py-2.5 text-right font-semibold">Total</th>
                <th className="px-4 py-2.5 font-semibold">Stage</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {filtered.map((o) => (
                <tr key={o.id}>
                  <td className="num px-4 py-2.5 text-soil-600">{shortDate(o.created_at)}</td>
                  <td className="px-4 py-2.5 font-semibold">{o.products?.variety ?? '—'}</td>
                  <td className="px-4 py-2.5 text-soil-600">
                    {(o.products as any)?.farms?.name ?? '—'}
                  </td>
                  <td className="px-4 py-2.5 text-soil-600">{o.profiles?.name ?? '—'}</td>
                  <td className="num px-4 py-2.5 text-right font-bold">{sacks(o.quantity)}</td>
                  <td className="num px-4 py-2.5 text-right">{peso(o.total_price)}</td>
                  <td className="px-4 py-2.5">
                    <StageBadge stage={effectiveStage(o)} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\admin\Requests.tsx' @'
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, DataTable, Dialog, Empty, Spinner, Stat, TextArea } from '@/components/ui'
import { ROLE_LABEL, relativeDate, shortDate } from '@/lib/format'
import { displayPhone, friendlyError } from '@/lib/validation'
import type { Profile, VerificationStatus } from '@/lib/types'

interface AdminRequest {
  id: string
  user_id: string
  requester_id: string
  full_name: string
  phone: string
  reason: string
  status: VerificationStatus
  review_notes: string | null
  reviewed_at: string | null
  created_at: string
}

export function AdminRequests() {
  const { profile } = useAuth()
  const [rows, setRows] = useState<AdminRequest[] | null>(null)
  const [admins, setAdmins] = useState<Profile[]>([])
  const [error, setError] = useState<string | null>(null)
  const [acting, setActing] = useState<{ row: AdminRequest; approve: boolean } | null>(null)
  const [revoking, setRevoking] = useState<Profile | null>(null)
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const [{ data, error: qError }, { data: ad }] = await Promise.all([
      supabase.from('admin_requests').select('*').order('created_at', { ascending: false }),
      supabase.from('profiles').select('*').eq('role', 'admin').order('created_at'),
    ])

    if (qError) {
      setError(qError.message)
      setRows([])
    } else {
      setError(null)
      setRows((data as AdminRequest[]) ?? [])
    }
    setAdmins((ad as Profile[]) ?? [])
  }, [])

  useEffect(() => {
    load()
    const channel = supabase
      .channel('admin-requests')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'admin_requests' }, () =>
        load(),
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  async function decide() {
    if (!acting) return
    if (!acting.approve && !notes.trim()) {
      toast.error('Give a reason so they know why.')
      return
    }
    setBusy(true)
    const { error: rpcError } = await supabase.rpc('review_admin_request', {
      p_request_id: acting.row.id,
      p_decision: acting.approve ? 'approved' : 'rejected',
      p_notes: notes.trim(),
    })
    setBusy(false)
    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success(acting.approve ? 'Administrator access granted' : 'Request declined')
    setActing(null)
    setNotes('')
    load()
  }

  async function revoke() {
    if (!revoking) return
    setBusy(true)
    const { error: rpcError } = await supabase.rpc('revoke_admin', { p_profile_id: revoking.id })
    setBusy(false)
    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success('Administrator access removed')
    setRevoking(null)
    load()
  }

  if (!rows) return <Spinner label="Loading requests" />

  const pending = rows.filter((r) => r.status === 'pending')

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Administrators</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Anyone asking for administrator access appears here. Only an existing administrator can
          approve them.
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
          <p className="font-semibold">Requests could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
        </div>
      )}

      <div className="stagger grid grid-cols-2 gap-3">
        <Stat label="Administrators" value={String(admins.length)} />
        <Stat
          label="Pending requests"
          value={String(pending.length)}
          accent={pending.length ? 'red' : undefined}
        />
      </div>

      <section>
        <h2 className="mb-3 text-[15px] font-bold">Current administrators</h2>
        <DataTable
          minWidth="34rem"
          headers={[
            { label: 'Name' },
            { label: 'Phone' },
            { label: 'Since' },
            { label: '', align: 'right' },
          ]}
        >
          {admins.map((a) => (
            <tr key={a.id}>
              <td className="px-4 py-3 font-semibold">
                {a.name}
                {a.id === profile?.id && (
                  <span className="ml-1.5 text-[11px] font-bold uppercase text-brand-700">You</span>
                )}
              </td>
              <td className="num px-4 py-3 text-soil-600">{displayPhone(a.phone)}</td>
              <td className="num px-4 py-3 text-soil-600">{shortDate(a.created_at)}</td>
              <td className="px-4 py-3 text-right">
                {a.id === profile?.id || admins.length <= 1 ? (
                  <span className="text-[12px] text-soil-400">—</span>
                ) : (
                  <button
                    className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                    onClick={() => setRevoking(a)}
                  >
                    Remove
                  </button>
                )}
              </td>
            </tr>
          ))}
        </DataTable>
      </section>

      <section>
        <h2 className="mb-3 text-[15px] font-bold">Access requests</h2>
        {rows.length === 0 ? (
          <Empty
            title="No requests"
            body="When someone asks for administrator access, their request appears here for review."
          />
        ) : (
          <DataTable
            minWidth="46rem"
            headers={[
              { label: 'Person' },
              { label: 'Reason' },
              { label: 'Requested' },
              { label: 'Status' },
              { label: '', align: 'right' },
            ]}
          >
            {rows.map((r) => (
              <tr key={r.id} className="align-top">
                <td className="px-4 py-3">
                  <span className="block font-semibold">{r.full_name || 'Unnamed'}</span>
                  <span className="num block text-[12px] text-soil-400">
                    {displayPhone(r.phone)}
                  </span>
                </td>
                <td className="max-w-[20rem] px-4 py-3 text-soil-600">{r.reason || '—'}</td>
                <td className="num px-4 py-3 text-soil-600">{relativeDate(r.created_at)}</td>
                <td className="px-4 py-3">
                  <Badge
                    tone={
                      r.status === 'approved' ? 'green' : r.status === 'rejected' ? 'red' : 'amber'
                    }
                  >
                    {r.status}
                  </Badge>
                  {r.review_notes && (
                    <span className="mt-1 block max-w-[12rem] text-[11px] leading-snug text-soil-400">
                      {r.review_notes}
                    </span>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  {r.status === 'pending' ? (
                    <span className="inline-flex gap-1.5">
                      <button
                        className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                        onClick={() => {
                          setActing({ row: r, approve: true })
                          setNotes('')
                        }}
                      >
                        Approve
                      </button>
                      <button
                        className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                        onClick={() => {
                          setActing({ row: r, approve: false })
                          setNotes('')
                        }}
                      >
                        Decline
                      </button>
                    </span>
                  ) : (
                    <span className="text-[12px] text-soil-400">
                      {r.reviewed_at ? relativeDate(r.reviewed_at) : '—'}
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </DataTable>
        )}
      </section>

      <Dialog
        open={acting !== null}
        onClose={() => setActing(null)}
        title={acting?.approve ? 'Grant administrator access?' : 'Decline this request?'}
        description={acting?.row.full_name}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setActing(null)}>
              Go back
            </button>
            <button
              className={acting?.approve ? 'btn-primary' : 'btn-danger'}
              onClick={decide}
              disabled={busy}
            >
              {busy ? 'Saving…' : acting?.approve ? 'Grant access' : 'Decline'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            {acting?.approve
              ? 'They will be able to verify accounts, view every user, product and order, and approve future administrators. Only grant this to someone who needs it.'
              : 'They keep their existing account and can ask again later.'}
          </p>
          <TextArea
            label={acting?.approve ? 'Note (optional)' : 'Reason for declining'}
            max={200}
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
        </div>
      </Dialog>

      <Dialog
        open={revoking !== null}
        onClose={() => setRevoking(null)}
        title="Remove administrator access?"
        description={revoking?.name}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setRevoking(null)}>
              Keep access
            </button>
            <button className="btn-danger" onClick={revoke} disabled={busy}>
              {busy ? 'Removing…' : 'Remove access'}
            </button>
          </>
        }
      >
        <p className="text-[14px] leading-relaxed text-soil-800">
          They lose the admin panel immediately. Any other accounts they hold as a farm owner,
          farmer or buyer are unaffected.
        </p>
      </Dialog>
    </div>
  )
}

export function RequestAdminAccess() {
  const { profile } = useAuth()
  const [existing, setExisting] = useState<AdminRequest | null>(null)
  const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('admin_requests')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    setExisting((data as AdminRequest) ?? null)
    setLoading(false)
  }, [])

  useEffect(() => {
    load()
  }, [load])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (reason.trim().length < 10) {
      toast.error('Explain briefly why you need administrator access.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('request_admin_access', { p_reason: reason.trim() })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Request sent for review')
    setReason('')
    load()
  }

  if (loading) return <Spinner label="Checking your request" />

  return (
    <div className="mx-auto max-w-xl animate-fade-up">
      <div className="card p-6 sm:p-8">
        <h1 className="text-[20px] font-bold">Request administrator access</h1>
        <p className="mt-1.5 text-[14px] leading-relaxed text-soil-600">
          You are signed in as {ROLE_LABEL[profile?.role ?? 'buyer']}. An existing administrator
          reviews every request, so nobody can grant themselves access.
        </p>

        {existing?.status === 'pending' ? (
          <div className="mt-5 rounded-xl border border-amber-200 bg-amber-50 px-4 py-4">
            <p className="text-[14px] font-bold text-amber-900">Your request is under review</p>
            <p className="mt-1 text-[13px] leading-relaxed text-amber-800">
              Sent {relativeDate(existing.created_at)}. You will be notified once an administrator
              decides.
            </p>
          </div>
        ) : (
          <>
            {existing?.status === 'rejected' && (
              <div className="mt-5 rounded-xl border border-red-200 bg-red-50 px-4 py-3">
                <p className="text-[13px] font-semibold text-red-800">
                  Your last request was declined
                </p>
                {existing.review_notes && (
                  <p className="mt-0.5 text-[13px] text-red-700">{existing.review_notes}</p>
                )}
              </div>
            )}

            <form onSubmit={submit} className="mt-5 space-y-4">
              <TextArea
                label="Why do you need administrator access?"
                max={300}
                placeholder="e.g. I am the second barangay agriculture officer and need to verify farm owners."
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
              <button className="btn-primary w-full" disabled={busy}>
                {busy ? 'Sending…' : 'Send request'}
              </button>
            </form>
          </>
        )}

        <p className="mt-5 text-center text-[12px] text-soil-400">
          <Link to="/" className="font-semibold text-brand-700 hover:underline">
            Back to FARMS
          </Link>
        </p>
      </div>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\farmer\Jobs.tsx' @'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Empty, Search, Spinner, TextArea } from '@/components/ui'
import { CROP_EMOJI, peso, shortDate, titleCase } from '@/lib/format'
import { friendlyError } from '@/lib/validation'
import type { JobApplication, JobPost, JobType } from '@/lib/types'

const FILTERS: { value: 'all' | JobType; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'seasonal', label: 'Seasonal' },
  { value: 'part-time', label: 'Part-time' },
  { value: 'full-time', label: 'Full-time' },
]

export default function FarmerJobs() {
  const { profile } = useAuth()
  const [jobs, setJobs] = useState<JobPost[] | null>(null)
  const [mine, setMine] = useState<Map<string, JobApplication>>(new Map())
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<'all' | JobType>('all')
  const [details, setDetails] = useState<JobPost | null>(null)
  const [applyTo, setApplyTo] = useState<JobPost | null>(null)

  const load = useCallback(async () => {
    const [{ data: posts }, { data: apps }] = await Promise.all([
      supabase
        .from('job_posts')
        .select('*, farms(name, city, province)')
        .order('created_at', { ascending: false }),
      profile
        ? supabase.from('job_applications').select('*').eq('farmer_id', profile.id)
        : Promise.resolve({ data: [] as JobApplication[] }),
    ])

    setJobs((posts as unknown as JobPost[]) ?? [])
    setMine(new Map(((apps as JobApplication[]) ?? []).map((a) => [a.job_id, a])))
  }, [profile?.id])

  useEffect(() => {
    load()

    const channel = supabase
      .channel('farmer-job-board')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_posts' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  const filtered = useMemo(() => {
    if (!jobs) return []
    const q = query.trim().toLowerCase()
    return jobs.filter((j) => {
      if (filter !== 'all' && j.type !== filter) return false
      if (!q) return true
      return (
        j.title.toLowerCase().includes(q) ||
        j.crop.toLowerCase().includes(q) ||
        j.location.toLowerCase().includes(q) ||
        (j.farms?.name ?? '').toLowerCase().includes(q)
      )
    })
  }, [jobs, query, filter])

  if (!jobs) return <Spinner label="Loading the job board" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Find jobs</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Farm work across the country. New posts appear here as farms publish them.
        </p>
      </div>

      <Search value={query} onChange={setQuery} placeholder="Search title, crop or location" />

      <div className="flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <button
            key={f.value}
            onClick={() => setFilter(f.value)}
            aria-pressed={filter === f.value}
            className={`chip border transition ${
              filter === f.value
                ? 'border-brand-700 bg-brand-700 text-white'
                : 'border-soil-200 bg-white text-soil-600 hover:bg-soil-100'
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      {filtered.length === 0 ? (
        <Empty
          title="No jobs match"
          body="Try a different crop, a nearby town, or clear the filters to see everything."
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((j) => {
            const app = mine.get(j.id)
            const openForApplications = j.status === 'open'
            const remaining = Math.max(0, j.slots - j.filled_slots)

            return (
              <article
                key={j.id}
                className={`card flex flex-col gap-3 p-4 ${!openForApplications ? 'opacity-60' : ''}`}
              >
                <div className="flex items-start justify-between gap-3">
                  <span className="text-2xl" aria-hidden>
                    {CROP_EMOJI[j.crop]}
                  </span>
                  {openForApplications ? (
                    <Badge tone="brand">{j.type}</Badge>
                  ) : (
                    <Badge tone="grey">No longer accepting</Badge>
                  )}
                </div>

                <div>
                  <h3 className="text-base font-bold leading-snug">{j.title}</h3>
                  <p className="mt-0.5 text-[13px] text-soil-600">{j.farms?.name ?? 'Farm'}</p>
                  <p className="text-[13px] text-soil-400">{j.location}</p>
                </div>

                {j.description && (
                  <p className="line-clamp-2 text-[13px] leading-relaxed text-soil-600">
                    {j.description}
                  </p>
                )}

                <div className="mt-auto flex items-end justify-between border-t border-soil-200/70 pt-3">
                  <div>
                    <p className="num text-lg font-bold text-brand-700">{peso(j.wage)}</p>
                    <p className="text-[12px] text-soil-400">per day</p>
                  </div>
                  <div className="text-right">
                    <p className="num text-lg font-bold">{remaining}</p>
                    <p className="text-[12px] text-soil-400">
                      {remaining === 1 ? 'slot left' : 'slots left'}
                    </p>
                  </div>
                </div>

                <p className="text-[12px] text-soil-400">Starts {shortDate(j.start_date)}</p>

                <div className="grid grid-cols-2 gap-2">
                  <button className="btn-ghost" onClick={() => setDetails(j)}>
                    View details
                  </button>
                  {app?.status === 'accepted' ? (
                    <span className="btn bg-green-100 text-green-800">Hired ✓</span>
                  ) : app ? (
                    <button className="btn bg-soil-100 text-soil-400" disabled>
                      Applied ✓
                    </button>
                  ) : openForApplications && remaining > 0 ? (
                    <button className="btn-primary" onClick={() => setApplyTo(j)}>
                      Apply now
                    </button>
                  ) : (
                    <button className="btn bg-soil-100 text-soil-400" disabled>
                      Closed
                    </button>
                  )}
                </div>
              </article>
            )
          })}
        </div>
      )}

      <Dialog
        open={details !== null}
        onClose={() => setDetails(null)}
        title={details?.title ?? ''}
        description={details?.farms?.name ?? undefined}
      >
        {details && (
          <div className="space-y-4">
            <div className="flex flex-wrap gap-2">
              <Badge tone="brand">{details.type}</Badge>
              <Badge>
                {CROP_EMOJI[details.crop]}&nbsp;
                {details.crop === 'general' ? 'General farm work' : titleCase(details.crop)}
              </Badge>
              <Badge tone={details.status === 'open' ? 'green' : 'grey'}>
                {titleCase(details.status)}
              </Badge>
            </div>

            <p className="whitespace-pre-line text-[14px] leading-relaxed text-soil-800">
              {details.description || 'The farm did not add a description for this job.'}
            </p>

            <dl className="grid grid-cols-2 gap-3 border-t border-soil-200/70 pt-4 text-sm">
              <Row label="Daily wage" value={peso(details.wage)} />
              <Row
                label="Slots left"
                value={String(Math.max(0, details.slots - details.filled_slots))}
              />
              <Row label="Location" value={details.location} />
              <Row label="Starts" value={shortDate(details.start_date)} />
              {details.end_date && <Row label="Ends" value={shortDate(details.end_date)} />}
            </dl>
          </div>
        )}
      </Dialog>

      <ApplyDialog
        job={applyTo}
        farmerId={profile?.id ?? ''}
        onClose={() => setApplyTo(null)}
        onApplied={() => {
          setApplyTo(null)
          load()
        }}
      />
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-[12px] font-bold uppercase tracking-wide text-soil-400">{label}</dt>
      <dd className="num mt-0.5 font-semibold">{value}</dd>
    </div>
  )
}

function ApplyDialog({
  job,
  farmerId,
  onClose,
  onApplied,
}: {
  job: JobPost | null
  farmerId: string
  onClose(): void
  onApplied(): void
}) {
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (job) setMessage('')
  }, [job?.id])

  async function submit() {
    if (!job) return
    setBusy(true)
    const { error } = await supabase.from('job_applications').insert({
      job_id: job.id,
      farmer_id: farmerId,
      message: message.trim() || null,
      status: 'pending',
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Application sent')
    onApplied()
  }

  return (
    <Dialog
      open={job !== null}
      onClose={onClose}
      title="Apply for this job"
      description={job ? `${job.title} · ${job.farms?.name ?? 'Farm'}` : undefined}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Sending…' : 'Send application'}
          </button>
        </>
      }
    >
      <TextArea
        label="Message to the farm"
        placeholder="Tell them about your experience with this kind of work."
        max={300}
        value={message}
        onChange={(e) => setMessage(e.target.value)}
      />
      <p className="mt-2 text-[13px] text-soil-400">
        Optional, but a short note helps. The farm can also see your skills and availability from
        your account.
      </p>
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\farmer\Applications.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/validation'
import { useAuth } from '@/context/AuthContext'
import { Badge, Empty, Spinner } from '@/components/ui'
import { CROP_EMOJI, peso, shortDate, titleCase } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { JobApplication } from '@/lib/types'

interface Row extends JobApplication {
  farm?: { name: string; owner_phone: string | null } | null
}

export default function FarmerApplications() {
  const { profile } = useAuth()
  const [rows, setRows] = useState<Row[] | null>(null)
  const [cancelling, setCancelling] = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    if (!profile) return
    let alive = true

    ;(async () => {
      const { data } = await supabase
        .from('job_applications')
        .select('*, job_posts(*, farms(name, city, province, owner_id))')
        .eq('farmer_id', profile.id)
        .order('applied_at', { ascending: false })

      const list = (data as unknown as Row[]) ?? []

      const ownerIds = [
        ...new Set(
          list
            .filter((r) => r.status === 'accepted')
            .map((r) => (r.job_posts?.farms as any)?.owner_id)
            .filter(Boolean),
        ),
      ]
      let contacts = new Map<string, string>()
      if (ownerIds.length) {
        const { data: owners } = await supabase
          .from('profiles')
          .select('id, phone')
          .in('id', ownerIds)
        contacts = new Map((owners ?? []).map((o: any) => [o.id, o.phone]))
      }

      list.forEach((r) => {
        const farms = r.job_posts?.farms as any
        r.farm = farms
          ? { name: farms.name, owner_phone: contacts.get(farms.owner_id) ?? null }
          : null
      })

      if (alive) setRows(list)
    })()

    return () => {
      alive = false
    }
  }, [profile?.id, reloadKey])

  async function cancel(id: string) {
    setCancelling(id)
    const { error } = await supabase.rpc('cancel_application', { p_application_id: id })
    setCancelling(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Application withdrawn')
    setReloadKey((k) => k + 1)
  }

  if (!rows) return <Spinner label="Loading your applications" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">My applications</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every job you have applied for, and where each one stands.
        </p>
      </div>

      {rows.length === 0 ? (
        <Empty
          title="You have not applied anywhere yet"
          body="Browse the job board and send your first application — a short message about your experience goes a long way."
        />
      ) : (
        <div className="grid gap-3 lg:grid-cols-2">
          {rows.map((a) => {
            const job = a.job_posts
            return (
              <article key={a.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h2 className="text-base font-bold leading-snug">
                      {job?.crop ? `${CROP_EMOJI[job.crop]} ` : ''}
                      {job?.title ?? 'Job'}
                    </h2>
                    <p className="text-[13px] text-soil-600">{a.farm?.name ?? 'Farm'}</p>
                  </div>
                  <Badge
                    tone={
                      a.status === 'accepted' ? 'green' : a.status === 'rejected' ? 'red' : 'amber'
                    }
                  >
                    {titleCase(a.status)}
                  </Badge>
                </div>

                <p className="text-[12px] text-soil-400">Applied {shortDate(a.applied_at)}</p>

                {a.message && (
                  <p className="rounded-xl bg-soil-50 px-3.5 py-3 text-[14px] leading-relaxed text-soil-800">
                    {a.message}
                  </p>
                )}

                {job && (
                  <div className="flex flex-wrap gap-2">
                    <Badge tone="brand">{job.type}</Badge>
                    <Badge>
                      <span className="num">{peso(job.wage)}</span>&nbsp;a day
                    </Badge>
                    <Badge>Starts {shortDate(job.start_date)}</Badge>
                  </div>
                )}

                {a.status === 'accepted' && (
                  <div className="rounded-xl border border-green-200 bg-green-50 px-4 py-3">
                    <p className="text-sm font-bold text-green-900">
                      🎉 You got the job — congratulations!
                    </p>
                    <p className="mt-1 text-[13px] leading-relaxed text-green-800">
                      Contact {a.farm?.name ?? 'the farm'} to agree your start time.
                    </p>
                    {a.farm?.owner_phone && (
                      <a
                        href={`tel:${a.farm.owner_phone}`}
                        className="num mt-1.5 inline-block text-sm font-bold text-green-900 underline"
                      >
                        {displayPhone(a.farm.owner_phone)}
                      </a>
                    )}
                  </div>
                )}

                {a.status === 'pending' && (
                  <button
                    className="btn-ghost w-full py-2 text-[13px] text-red-600 hover:bg-red-50"
                    disabled={cancelling === a.id}
                    onClick={() => cancel(a.id)}
                  >
                    {cancelling === a.id ? 'Withdrawing…' : 'Cancel application'}
                  </button>
                )}

                {a.status === 'rejected' && (
                  <div className="rounded-xl border border-soil-200 bg-soil-50 px-4 py-3">
                    {a.message && a.message.includes('Reason:') && (
                      <p className="mb-2 text-[13px] font-semibold text-soil-800">
                        {a.message.slice(a.message.lastIndexOf('Reason:'))}
                      </p>
                    )}
                    <p className="text-[13px] leading-relaxed text-soil-600">
                      Plenty of farms are hiring — keep applying, and add your skills to your
                      account so they know what you can do.
                    </p>
                  </div>
                )}
              </article>
            )
          })}
        </div>
      )}
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\farmer\Account.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Badge, Field, SectionHeading, Spinner, TextArea } from '@/components/ui'
import { titleCase } from '@/lib/format'
import {
  friendlyError,
  normalisePhone,
  validateName,
  validatePhone,
  validateWholeNumber,
} from '@/lib/validation'
import type { Availability, FarmerProfile } from '@/lib/types'

const SUGGESTED = ['Rice Harvesting', 'Planting', 'Irrigation', 'Machinery', 'Driving']
const STATES: Availability[] = ['available', 'busy', 'unavailable']

export default function FarmerAccount() {
  const { profile, refresh } = useAuth()
  const [fp, setFp] = useState<FarmerProfile | null>(null)
  const [form, setForm] = useState<Record<string, string>>({})
  const [skills, setSkills] = useState<string[]>([])
  const [skillDraft, setSkillDraft] = useState('')
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!profile) return
    ;(async () => {
      let { data } = await supabase.from('farmer_profiles').select('*').eq('id', profile.id).maybeSingle()
      if (!data) {
        const { data: created } = await supabase
          .from('farmer_profiles')
          .insert({ id: profile.id, availability: 'available' })
          .select()
          .single()
        data = created
      }
      const row = data as FarmerProfile
      setFp(row)
      setSkills(row?.skills ?? [])
      setForm({
        name: profile.name ?? '',
        phone: profile.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile.phone ?? '',
        email: profile.email ?? '',
        province: row?.province ?? '',
        city: row?.city ?? '',
        experience_years: String(row?.experience_years ?? 0),
        bio: row?.bio ?? '',
      })
    })()
  }, [profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function setAvailability(next: Availability) {
    if (!profile) return
    setFp((p) => (p ? { ...p, availability: next } : p))
    const { error } = await supabase
      .from('farmer_profiles')
      .update({ availability: next })
      .eq('id', profile.id)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(`You are now ${next}`)
  }

  function addSkill(value: string) {
    const s = value.trim()
    if (!s || skills.includes(s)) return
    setSkills((prev) => [...prev, s])
    setSkillDraft('')
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    const next = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      experience_years: validateWholeNumber(form.experience_years, 0, 'number of years'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    const normalised = normalisePhone(form.phone)!

    if (normalised !== profile.phone && (await isPhoneTakenForRole(normalised, 'farmer'))) {
      const msg = 'This number is already registered as a Farmer. Use a different number.'
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    setBusy(true)
    const [p, f] = await Promise.all([
      supabase
        .from('profiles')
        .update({
          name: form.name.trim(),
          phone: normalised,
          email: form.email.trim() || null,
        })
        .eq('id', profile.id),
      supabase
        .from('farmer_profiles')
        .update({
          province: form.province.trim(),
          city: form.city.trim(),
          experience_years: parseInt(form.experience_years, 10),
          bio: form.bio.trim(),
          skills,
        })
        .eq('id', profile.id),
    ])
    setBusy(false)

    const err = p.error ?? f.error
    if (err) {
      const msg = /profiles_phone_role_key/.test(err.message)
        ? 'This number is already registered as a Farmer. Use a different number.'
        : friendlyError(err)
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    toast.success('Account saved')
    await refresh()
  }

  if (!profile || !fp) return <Spinner />

  return (
    <div className="space-y-6">
      <h1 className="text-[22px] font-bold">Account</h1>

      <AccountHeader
        extra={
          <span className="mt-1.5 inline-block">
            <Badge tone={fp.availability === 'available' ? 'green' : 'grey'}>
              {titleCase(fp.availability)}
            </Badge>
          </span>
        }
      />

      <section>
        <SectionHeading>Availability</SectionHeading>
        <div className="card grid grid-cols-3 gap-2 p-2">
          {STATES.map((s) => (
            <button
              key={s}
              onClick={() => setAvailability(s)}
              aria-pressed={fp.availability === s}
              className={`rounded-xl px-3 py-2.5 text-sm font-bold transition ${
                fp.availability === s
                  ? 'bg-brand-700 text-white'
                  : 'text-soil-600 hover:bg-soil-100'
              }`}
            >
              {titleCase(s)}
            </button>
          ))}
        </div>
        <p className="mt-2 text-[13px] text-soil-400">
          Farms see this on your applications. It saves the moment you tap it.
        </p>
      </section>

      <form onSubmit={save} className="space-y-5" noValidate>
        <section>
          <SectionHeading>Your details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Full name" value={form.name ?? ''} error={errors.name} onChange={(e) => set('name', e.target.value)} />
            <Field
              label="Mobile number"
              type="tel"
              inputMode="tel"
              value={form.phone ?? ''}
              error={errors.phone}
              onChange={(e) => set('phone', e.target.value)}
            />
            <Field
              label="Email"
              type="email"
              placeholder="Needed for password resets"
              className="sm:col-span-2"
              value={form.email ?? ''}
              onChange={(e) => set('email', e.target.value)}
            />
            <Field label="Province" value={form.province ?? ''} onChange={(e) => set('province', e.target.value)} />
            <Field label="City or municipality" value={form.city ?? ''} onChange={(e) => set('city', e.target.value)} />
          </div>
        </section>

        <section>
          <SectionHeading>What you can do</SectionHeading>
          <div className="card space-y-4 p-5">
            <div>
              <label className="label" htmlFor="skill">
                Skills
              </label>
              <div className="flex gap-2">
                <input
                  id="skill"
                  className="field"
                  placeholder="Add a skill"
                  value={skillDraft}
                  onChange={(e) => setSkillDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault()
                      addSkill(skillDraft)
                    }
                  }}
                />
                <button type="button" className="btn-ghost shrink-0" onClick={() => addSkill(skillDraft)}>
                  Add
                </button>
              </div>

              {skills.length > 0 && (
                <div className="mt-3 flex flex-wrap gap-2">
                  {skills.map((s) => (
                    <span key={s} className="chip bg-brand-100 text-brand-900">
                      {s}
                      <button
                        type="button"
                        onClick={() => setSkills((prev) => prev.filter((x) => x !== s))}
                        aria-label={`Remove ${s}`}
                        className="ml-0.5 text-brand-700 hover:text-red-600"
                      >
                        ✕
                      </button>
                    </span>
                  ))}
                </div>
              )}

              <div className="mt-3 flex flex-wrap gap-2">
                {SUGGESTED.filter((s) => !skills.includes(s)).map((s) => (
                  <button
                    key={s}
                    type="button"
                    onClick={() => addSkill(s)}
                    className="chip border border-dashed border-soil-200 text-soil-400 hover:border-brand-600 hover:text-brand-700"
                  >
                    + {s}
                  </button>
                ))}
              </div>
            </div>

            <div>
              <label className="label" htmlFor="exp">
                Years of experience
              </label>
              <input
                id="exp"
                type="number"
                step="1"
                min="0"
                inputMode="numeric"
                className={`field num ${errors.experience_years ? 'field-error' : ''}`}
                value={form.experience_years ?? ''}
                onKeyDown={(e) => ['.', ',', 'e', 'E', '+', '-'].includes(e.key) && e.preventDefault()}
                onChange={(e) => set('experience_years', e.target.value)}
              />
              {errors.experience_years && <p className="err">{errors.experience_years}</p>}
            </div>

            <TextArea
              label="About you"
              max={200}
              placeholder="A sentence or two about the work you do best."
              value={form.bio ?? ''}
              onChange={(e) => set('bio', e.target.value)}
            />
          </div>
        </section>

        <button className="btn-primary w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </form>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\farmer\Logs.tsx' @'
import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Empty, SectionHeading, Spinner, Stat } from '@/components/ui'
import { hours, shortDate,
  todayISO, peso } from '@/lib/format'
import { friendlyError } from '@/lib/validation'
import type { AttendanceRow } from '@/lib/types'

interface ActiveJob {
  job_id: string
  job_title: string
  farm_id: string
  farm_name: string
  wage: number
  start_time: string
  end_time: string
  clocked: boolean
}


function toMinutes(t: string | null | undefined): number | null {
  if (!t) return null
  const [h, m] = t.split(':').map(Number)
  if (Number.isNaN(h)) return null
  return h * 60 + (m || 0)
}

function clockLabel(t: string | null | undefined): string {
  const mins = toMinutes(t)
  if (mins === null) return ''
  const h = Math.floor(mins / 60)
  const m = mins % 60
  const period = h >= 12 ? 'PM' : 'AM'
  const hour = h % 12 === 0 ? 12 : h % 12
  return `${hour}:${String(m).padStart(2, '0')} ${period}`
}


interface OpenShift {
  id: string
  time_in: string
  work_date: string
  farm: string
  job: string | null
  wage: number
  start_time: string | null
  end_time: string | null
  break_started_at: string | null
  break_minutes: number
}

function clock(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
}

function elapsed(from: string, to: Date, minusMinutes = 0): string {
  const ms = to.getTime() - new Date(from).getTime() - minusMinutes * 60000
  if (ms < 0) return '00:00:00'
  const h = Math.floor(ms / 3600000)
  const m = Math.floor((ms % 3600000) / 60000)
  const sec = Math.floor((ms % 60000) / 1000)
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`
}

export default function FarmerLogs() {
  const [shift, setShift] = useState<OpenShift | null>(null)
  const [jobs, setJobs] = useState<ActiveJob[]>([])
  const [jobId, setJobId] = useState('')
  const [today, setToday] = useState<AttendanceRow[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [now, setNow] = useState(new Date())

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_open_shift')
    setShift((data as OpenShift | null) ?? null)

    const { data: js } = await supabase.rpc('my_active_jobs')
    const list = (js as ActiveJob[]) ?? []
    setJobs(list)
    setJobId((prev) => {
      if (prev && list.some((j) => j.job_id === prev && !j.clocked)) return prev
      return list.find((j) => !j.clocked)?.job_id ?? list[0]?.job_id ?? ''
    })

    const { data: rows } = await supabase
      .from('attendance')
      .select('*')
      .eq('work_date', todayISO())
      .order('time_in', { ascending: false })
    setToday((rows as AttendanceRow[]) ?? [])
    setLoading(false)
  }, [])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 1000)
    return () => clearInterval(t)
  }, [])

  async function timeIn() {
    if (!jobId) {
      toast.error('Choose the farm you are working at.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('farmer_time_in', { p_job_id: jobId })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Timed in. Have a good shift.')
    load()
  }

  async function pause() {
    setBusy(true)
    const { error } = await supabase.rpc('farmer_pause_shift')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Break started')
    load()
  }

  async function resume() {
    setBusy(true)
    const { error } = await supabase.rpc('farmer_resume_shift')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Back to work')
    load()
  }

  async function timeOut() {
    setBusy(true)
    const { error } = await supabase.rpc('farmer_time_out')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Timed out. Your hours have been recorded.')
    load()
  }

  if (loading) return <Spinner label="Checking your shift" />

  const finishedToday = today.filter((r) => r.time_out)

  const onBreak = !!shift?.break_started_at
  const liveBreak = onBreak
    ? (now.getTime() - new Date(shift!.break_started_at!).getTime()) / 60000
    : 0
  const totalBreak = Math.floor((shift?.break_minutes ?? 0) + liveBreak)
  const workedMinutes = totalBreak

  const selected = jobs.find((j) => j.job_id === jobId) ?? null

  const canTimeIn = true
  const canTimeOut = true

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Time clock</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Tap in when you start and out when you finish. You are paid the agreed wage for the job
          once the day is done.
        </p>
      </div>

      <div className="card p-6 text-center">
        <p className="text-[12px] font-semibold uppercase tracking-wide text-soil-400">
          {new Date().toLocaleDateString('en-PH', {
            weekday: 'long',
            day: 'numeric',
            month: 'long',
          })}
        </p>

        {shift ? (
          <>
            <p
              className={`num mt-3 text-[42px] font-bold leading-none ${
                onBreak ? 'text-amber-600' : 'text-brand-700'
              }`}
            >
              {elapsed(shift.time_in, now, workedMinutes)}
            </p>

            {onBreak && (
              <p className="mt-1 inline-flex items-center gap-1.5 rounded-full bg-amber-100 px-3 py-1 text-[12px] font-bold uppercase tracking-wide text-amber-800">
                On break
              </p>
            )}
            <p className="mt-1.5 text-[13px] text-soil-600">
              Timed in at <span className="num font-semibold">{clock(shift.time_in)}</span>
            </p>
            <p className="mt-0.5 text-[13px] text-soil-400">
              {shift.job ?? 'Work'} · {shift.farm}
            </p>

            {totalBreak > 0 && (
              <p className="mt-1 text-[12px] text-soil-500">
                Break time so far: <span className="num font-semibold">{totalBreak} min</span>
              </p>
            )}

            <div className="mx-auto mt-5 flex w-full max-w-sm flex-col gap-2 sm:flex-row">
              {onBreak ? (
                <button
                  className="btn-primary flex-1 py-3.5 text-[16px]"
                  onClick={resume}
                  disabled={busy}
                >
                  {busy ? 'Saving…' : 'Resume Work'}
                </button>
              ) : (
                <button
                  className="btn-ghost flex-1 py-3.5 text-[16px]"
                  onClick={pause}
                  disabled={busy}
                >
                  {busy ? 'Saving…' : 'Pause'}
                </button>
              )}

              <button
                className="btn-danger flex-1 py-3.5 text-[16px] disabled:opacity-40"
                onClick={timeOut}
                disabled={busy || !canTimeOut}
              >
                {busy ? 'Recording…' : 'Time Out'}
              </button>
            </div>


          </>
        ) : (
          <>
            <p className="num mt-3 text-[42px] font-bold leading-none">
              {now.toLocaleTimeString('en-PH', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true,
              })}
            </p>
            <p className="mt-1.5 text-[13px] text-soil-600">
              {finishedToday.length > 0
                ? 'You have finished your shift for today.'
                : 'You are not timed in yet.'}
            </p>

            {jobs.length === 0 ? (
              <p className="mx-auto mt-5 max-w-sm rounded-lg bg-amber-50 px-4 py-3 text-[13px] leading-relaxed text-amber-900">
                You are not hired for any job yet. Apply on the Find Jobs page, and once a farm
                accepts you the time clock opens here.
              </p>
            ) : (
              <>
                <div className="mx-auto mt-5 max-w-sm text-left">
                  <label className="label" htmlFor="jobpick">
                    Which farm are you working at?
                  </label>
                  <div className="relative">
                    <select
                      id="jobpick"
                      className="field appearance-none bg-white pr-10"
                      value={jobId}
                      onChange={(e) => setJobId(e.target.value)}
                    >
                      {jobs.map((j) => (
                        <option key={j.job_id} value={j.job_id} disabled={j.clocked}>
                          {j.farm_name} — {j.job_title}
                          {j.clocked ? ' (done today)' : ` · ${peso(j.wage)}/day`}
                        </option>
                      ))}
                    </select>
                    <svg
                      aria-hidden
                      className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-soil-400"
                      width="16" height="16" viewBox="0 0 24 24" fill="none"
                      stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
                    >
                      <path d="m6 9 6 6 6-6" />
                    </svg>
                  </div>
                </div>

                <button
                  className="btn-primary mx-auto mt-4 w-full py-3.5 text-[16px] disabled:opacity-40 sm:w-72"
                  onClick={timeIn}
                  disabled={busy || !jobId || jobs.every((j) => j.clocked) || !canTimeIn}
                >
                  {busy ? 'Recording…' : 'Time In'}
                </button>

                {jobs.every((j) => j.clocked) && (
                  <p className="mt-2 text-[12px] text-soil-400">
                    You have finished every shift for today. Come back tomorrow.
                  </p>
                )}
              </>
            )}
          </>
        )}
      </div>

      <section>
        <SectionHeading>Today</SectionHeading>
        {today.length === 0 ? (
          <Empty title="Nothing recorded today" body="Tap Time In above to start your shift." />
        ) : (
          <div className="stagger grid grid-cols-3 gap-3">
            <Stat label="Time in" value={clock(today[0].time_in)} />
            <Stat label="Time out" value={clock(today[0].time_out)} />
            <Stat
              label="Hours"
              value={today[0].time_out ? hours(today[0].hours_worked) : 'Running'}
              accent={today[0].time_out ? 'green' : undefined}
            />
          </div>
        )}
      </section>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\farmer\History.tsx' @'
import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/validation'
import { Badge, DataTable, Dialog, Empty, Spinner, Stat } from '@/components/ui'
import { ATTENDANCE_LABEL, hours, peso, pesoShort, shortDate,
  toISODate,
  todayISO,
} from '@/lib/format'
import type { AttendanceRow } from '@/lib/types'

function clock(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
}

export default function FarmerHistory() {
  const [rows, setRows] = useState<AttendanceRow[] | null>(null)
  const [month, setMonth] = useState(() => todayISO().slice(0, 7))
  const [confirming, setConfirming] = useState<string | null>(null)
  const [pendingRow, setPendingRow] = useState<AttendanceRow | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  async function confirmPayment() {
    if (!pendingRow) return
    setConfirming(pendingRow.id)
    const { error } = await supabase.rpc('farmer_confirm_payment', {
      p_attendance_id: pendingRow.id,
    })
    setConfirming(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Payment confirmed')
    setPendingRow(null)
    setReloadKey((k) => k + 1)
  }

  useEffect(() => {
    ;(async () => {
      setRows(null)
      const [y, m] = month.split('-').map(Number)
      const start = `${month}-01`
      const end = toISODate(new Date(y, m, 0))

      const { data } = await supabase
        .from('attendance')
        .select('*, farms(name)')
        .gte('work_date', start)
        .lte('work_date', end)
        .order('work_date', { ascending: false })

      setRows((data as unknown as AttendanceRow[]) ?? [])
    })()
  }, [month, reloadKey])

  const totals = useMemo(() => {
    const list = rows ?? []
    return {
      days: list.length,
      hours: list.reduce((s, r) => s + Number(r.hours_worked), 0),
      earned: list.reduce((s, r) => s + Number(r.computed_pay), 0),
      unpaid: list
        .filter((r) => r.payment_status !== 'paid')
        .reduce((s, r) => s + Number(r.computed_pay), 0),
    }
  }, [rows])

  if (!rows) return <Spinner label="Loading your work history" />

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">My work history</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every shift you have recorded, with the hours and pay for each.
        </p>
      </div>

      <div className="max-w-xs">
        <label className="label" htmlFor="hm">
          Month
        </label>
        <input
          id="hm"
          type="month"
          className="field num"
          value={month}
          onChange={(e) => setMonth(e.target.value)}
        />
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Days worked" value={String(totals.days)} />
        <Stat label="Total hours" value={hours(totals.hours)} />
        <Stat label="Total earned" value={pesoShort(totals.earned)} accent="green" />
        <Stat
          label="Not yet paid"
          value={pesoShort(totals.unpaid)}
          accent={totals.unpaid > 0 ? 'red' : undefined}
          sub={totals.unpaid > 0 ? 'Still owed to you' : 'All settled'}
        />
      </div>

      {rows.length === 0 ? (
        <Empty
          title="Nothing recorded this month"
          body="Use the Time Clock page to time in when you start work."
        />
      ) : (
        <DataTable
          minWidth="46rem"
          headers={[
            { label: 'Date' },
            { label: 'Farm' },
            { label: 'Time in' },
            { label: 'Time out' },
            { label: 'Break', align: 'right' },
            { label: 'Hours', align: 'right' },
            { label: 'Pay', align: 'right' },
            { label: 'Payment' },
            { label: '', align: 'right' },
          ]}
        >
          {rows.map((r) => (
            <tr key={r.id}>
              <td className="num px-4 py-3">{shortDate(r.work_date)}</td>
              <td className="px-4 py-3 text-soil-600">
                {(r as any).farms?.name ?? '—'}
              </td>
              <td className="num px-4 py-3">{clock(r.time_in)}</td>
              <td className="num px-4 py-3">
                {r.time_out ? (
                  clock(r.time_out)
                ) : (
                  <span className="text-amber-600">Still in</span>
                )}
              </td>
              <td className="num px-4 py-3 text-right text-soil-500">
                {r.break_minutes > 0 ? `${Math.round(r.break_minutes)}m` : '—'}
              </td>
              <td className="num px-4 py-3 text-right font-semibold">{hours(r.hours_worked)}</td>
              <td className="num px-4 py-3 text-right font-bold">{peso(r.computed_pay)}</td>
              <td className="px-4 py-3">
                <span className="flex flex-wrap gap-1">
                  <Badge
                    tone={
                      r.status === 'present'
                        ? 'green'
                        : r.status === 'absent'
                          ? 'red'
                          : r.status === 'half_day'
                            ? 'amber'
                            : 'grey'
                    }
                  >
                    {ATTENDANCE_LABEL[r.status]}
                  </Badge>
                  {Number(r.computed_pay) > 0 && (
                    <Badge
                      tone={
                        r.payment_status === 'paid'
                          ? 'green'
                          : r.payment_status === 'pending'
                            ? 'amber'
                            : 'grey'
                      }
                    >
                      {r.payment_status === 'paid'
                        ? 'Received'
                        : r.payment_status === 'pending'
                          ? 'Sent to you'
                          : 'Not yet paid'}
                    </Badge>
                  )}
                </span>
              </td>
              <td className="px-4 py-3 text-right">
                {r.payment_status === 'pending' ? (
                  <button
                    className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                    disabled={confirming === r.id}
                    onClick={() => setPendingRow(r)}
                  >
                    {confirming === r.id ? '…' : 'Payment received'}
                  </button>
                ) : r.payment_status === 'paid' ? (
                  <span className="text-[12px] text-soil-400">
                    {r.payment_confirmed_at ? shortDate(r.payment_confirmed_at) : 'Confirmed'}
                  </span>
                ) : (
                  <span className="text-[12px] text-soil-400">—</span>
                )}
              </td>
            </tr>
          ))}
        </DataTable>
      )}

      <Dialog
        open={pendingRow !== null}
        onClose={() => setPendingRow(null)}
        title="Confirm you received this payment?"
        description={pendingRow ? shortDate(pendingRow.work_date) : undefined}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setPendingRow(null)}>
              Not yet
            </button>
            <button
              className="btn-primary"
              onClick={confirmPayment}
              disabled={confirming !== null}
            >
              {confirming ? 'Confirming…' : 'Yes, I received it'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            Confirm only once the money is actually in your hands. This cannot be undone, and it is
            the record both you and the farm owner rely on.
          </p>
          {pendingRow && (
            <p className="rounded-lg bg-brand-50 px-4 py-3 text-center">
              <span className="block text-[12px] font-semibold uppercase tracking-wide text-brand-900/70">
                Amount
              </span>
              <span className="num block text-[22px] font-bold text-brand-900">
                {peso(pendingRow.computed_pay)}
              </span>
            </p>
          )}
        </div>
      </Dialog>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\buyer\Market.tsx' @'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  DataTable,
  Dialog,
  Empty,
  PesoInput,
  SackInput,
  Search,
  Select,
  Spinner,
  ViewToggle,
} from '@/components/ui'
import { TopFarms } from '@/components/TopFarms'
import { FarmProfileDialog } from '@/components/FarmProfileDialog'
import {
  CROPS,
  CROP_EMOJI,
  KG_PER_SACK,
  availableSacks,
  peso,
  sacks,
  titleCase,
  toSacks,
  weightNote,
} from '@/lib/format'
import { friendlyError, validateSacks } from '@/lib/validation'
import type { Product } from '@/lib/types'

export default function BuyerMarket() {
  const { profile } = useAuth()
  const [items, setItems] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')
  const [buying, setBuying] = useState<Product | null>(null)
  const [crop, setCrop] = useState('all')
  const [availability, setAvailability] = useState('all')
  const [farmFilter, setFarmFilter] = useState('all')
  const [sort, setSort] = useState('newest')
  const [maxPrice, setMaxPrice] = useState('')
  const [filtersOpen, setFiltersOpen] = useState(false)
  const [view, setView] = useState<'grid' | 'table'>('grid')
  const [viewingFarm, setViewingFarm] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('*, farms(name, city, province)')
      .order('quantity', { ascending: false })
      .order('created_at', { ascending: false })
    setItems((data as unknown as Product[]) ?? [])
  }, [])

  useEffect(() => {
    load()

    const channel = supabase
      .channel('buyer-market')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  const farmNames = useMemo(
    () => [...new Set((items ?? []).map((p) => p.farms?.name).filter(Boolean) as string[])].sort(),
    [items],
  )

  const filtered = useMemo(() => {
    if (!items) return []
    const q = query.trim().toLowerCase()
    const cap = maxPrice === '' ? null : Number(maxPrice)

    const list = items.filter((p) => {
      if (q) {
        const hit =
          p.variety.toLowerCase().includes(q) ||
          p.crop.toLowerCase().includes(q) ||
          (p.farms?.name ?? '').toLowerCase().includes(q)
        if (!hit) return false
      }
      if (crop !== 'all' && p.crop !== crop) return false
      if (farmFilter !== 'all' && p.farms?.name !== farmFilter) return false
      const avail = availableSacks(p)
      if (avail <= 0 && availability !== 'out') return false
      if (availability === 'in' && avail <= 0) return false
      if (availability === 'low' && (avail === 0 || avail > 5)) return false
      if (availability === 'out' && avail > 0) return false
      if (cap !== null && Number(p.price) > cap) return false
      return true
    })

    const sorted = [...list]
    if (sort === 'price_low') sorted.sort((a, b) => Number(a.price) - Number(b.price))
    else if (sort === 'price_high') sorted.sort((a, b) => Number(b.price) - Number(a.price))
    else if (sort === 'stock') sorted.sort((a, b) => b.quantity - a.quantity)
    else sorted.sort((a, b) => +new Date(b.created_at) - +new Date(a.created_at))

    return sorted.sort(
      (a, b) => (availableSacks(a) === 0 ? 1 : 0) - (availableSacks(b) === 0 ? 1 : 0),
    )
  }, [items, query, crop, availability, farmFilter, sort, maxPrice])

  const activeFilters =
    (crop !== 'all' ? 1 : 0) +
    (availability !== 'all' ? 1 : 0) +
    (farmFilter !== 'all' ? 1 : 0) +
    (maxPrice !== '' ? 1 : 0)

  function clearFilters() {
    setCrop('all')
    setAvailability('all')
    setFarmFilter('all')
    setMaxPrice('')
    setSort('newest')
  }

  if (!items) return <Spinner label="Loading the market" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Market</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Fresh from Philippine farms, sold by the sack. One sack is {KG_PER_SACK} kg.
        </p>
      </div>

      {profile && (!profile.address || !profile.city) && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3">
          <p className="text-[13px] font-semibold text-amber-900">
            Add your delivery address
          </p>
          <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
            Farm owners use it to find you and arrange delivery.{' '}
            <Link to="/buyer/account" className="font-semibold underline">
              Complete your account
            </Link>
          </p>
        </div>
      )}

      <div className="space-y-3">
        <div className="flex gap-2">
          <div className="flex-1">
            <Search value={query} onChange={setQuery} placeholder="Search variety, crop or farm" />
          </div>
          <ViewToggle view={view} onChange={setView} />
          <button
            onClick={() => setFiltersOpen((v) => !v)}
            aria-expanded={filtersOpen}
            className={`btn shrink-0 px-3.5 ${
              activeFilters > 0 ? 'bg-brand-600 text-white' : 'btn-ghost'
            }`}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M22 3H2l8 9.5V19l4 2v-8.5z" />
            </svg>
            Filter
            {activeFilters > 0 && (
              <span className="num rounded-full bg-white/25 px-1.5 text-[11px]">{activeFilters}</span>
            )}
          </button>
        </div>

        {filtersOpen && (
          <div className="card space-y-3 p-4">
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <Select
                label="Crop"
                value={crop}
                onChange={(e) => setCrop(e.target.value)}
                options={[
                  { value: 'all', label: 'All crops' },
                  ...CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` })),
                ]}
              />
              <Select
                label="Availability"
                value={availability}
                onChange={(e) => setAvailability(e.target.value)}
                options={[
                  { value: 'all', label: 'Any' },
                  { value: 'in', label: 'In stock' },
                  { value: 'low', label: 'Low stock' },
                  { value: 'out', label: 'Out of stock' },
                ]}
              />
              <Select
                label="Farm"
                value={farmFilter}
                onChange={(e) => setFarmFilter(e.target.value)}
                options={[
                  { value: 'all', label: 'All farms' },
                  ...farmNames.map((n) => ({ value: n, label: n })),
                ]}
              />
              <Select
                label="Sort by"
                value={sort}
                onChange={(e) => setSort(e.target.value)}
                options={[
                  { value: 'newest', label: 'Newest first' },
                  { value: 'price_low', label: 'Price: low to high' },
                  { value: 'price_high', label: 'Price: high to low' },
                  { value: 'stock', label: 'Most stock' },
                ]}
              />
              <PesoInput
                label="Highest price per sack"
                placeholder="Any"
                className="sm:col-span-2"
                value={maxPrice}
                onChange={(e) => setMaxPrice(e.target.value)}
              />
            </div>

            <div className="flex items-center justify-between gap-3 border-t border-soil-200 pt-3">
              <p className="text-[13px] text-soil-600">
                <span className="num font-bold">{filtered.length}</span>{' '}
                {filtered.length === 1 ? 'product' : 'products'}
              </p>
              {activeFilters > 0 && (
                <button
                  onClick={clearFilters}
                  className="text-[13px] font-semibold text-brand-700 hover:underline"
                >
                  Clear filters
                </button>
              )}
            </div>
          </div>
        )}
      </div>

      <details className="card group">
        <summary className="flex cursor-pointer items-center justify-between px-4 py-3 text-[14px] font-semibold">
          <span>🏆 Top selling farms this week</span>
          <svg
            className="text-soil-400 transition group-open:rotate-180"
            width="16" height="16" viewBox="0 0 24 24" fill="none"
            stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"
          >
            <path d="m6 9 6 6 6-6" />
          </svg>
        </summary>
        <div className="border-t border-soil-200 p-4">
          <TopFarms limit={5} showPeriodPicker={false} />
        </div>
      </details>

      {filtered.length === 0 ? (
        <Empty
          title={query ? 'Nothing matches that search' : 'Nothing for sale right now'}
          body={
            query
              ? 'Try a crop name like rice, corn or watermelon.'
              : 'Farms list their harvest here as it comes in. Check back shortly.'
          }
        />
      ) : view === 'table' ? (
        <DataTable
          minWidth="46rem"
          headers={[
            { label: 'Product' },
            { label: 'Farm' },
            { label: 'Available', align: 'right' },
            { label: 'Price per sack', align: 'right' },
            { label: 'Status' },
            { label: '', align: 'right' },
          ]}
        >
          {filtered.map((p) => (
            <tr key={p.id} className={availableSacks(p) === 0 ? 'bg-soil-50/60' : ''}>
              <td className="px-4 py-3">
                <span className="block font-semibold">
                  {CROP_EMOJI[p.crop]} {p.variety}
                </span>
                <span className="block text-[12px] text-soil-400">{titleCase(p.crop)}</span>
              </td>
              <td className="px-4 py-3 text-soil-600">
                <button
                  onClick={() => p.farm_id && setViewingFarm(p.farm_id)}
                  className="block font-semibold text-brand-700 hover:underline"
                >
                  {p.farms?.name ?? 'Farm'}
                </button>
                {p.farms?.city && (
                  <span className="block text-[12px] text-soil-400">{p.farms.city}</span>
                )}
              </td>
              <td className="num px-4 py-3 text-right">
                {availableSacks(p) === 0 ? (
                  <span className="text-soil-400">—</span>
                ) : (
                  <>
                    <span className="block font-bold">{sacks(availableSacks(p))} sacks</span>
                    <span className="block text-[12px] text-soil-400">
                      {availableSacks(p) * KG_PER_SACK} kg
                    </span>
                  </>
                )}
              </td>
              <td className="num px-4 py-3 text-right font-bold text-brand-700">
                {peso(p.price)}
              </td>
              <td className="px-4 py-3">
                <span
                  className={`chip ${
                    availableSacks(p) === 0
                      ? 'bg-soil-200 text-soil-600'
                      : availableSacks(p) <= 5
                        ? 'bg-amber-100 text-amber-700'
                        : 'bg-green-100 text-green-700'
                  }`}
                >
                  {availableSacks(p) === 0
                    ? 'Out of stock'
                    : availableSacks(p) <= 5
                      ? 'Low stock'
                      : 'In stock'}
                </span>
              </td>
              <td className="px-4 py-3 text-right">
                <button
                  className={`btn-sm ${
                    p.quantity === 0
                      ? 'cursor-not-allowed bg-soil-100 text-soil-400'
                      : 'bg-brand-600 text-white hover:bg-brand-700'
                  }`}
                  disabled={availableSacks(p) === 0}
                  onClick={() => setBuying(p)}
                >
                  {availableSacks(p) === 0 ? 'Unavailable' : 'Buy'}
                </button>
              </td>
            </tr>
          ))}
        </DataTable>
      ) : (
        <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
          {filtered.map((p) => {
            const avail = availableSacks(p)
            const out = avail === 0
            const low = !out && avail <= 5
            return (
              <article
                key={p.id}
                className="group relative flex flex-col overflow-hidden rounded-lg border border-soil-200
                           bg-white transition hover:shadow-md"
              >
                <div className="relative flex aspect-square items-center justify-center overflow-hidden bg-brand-50">
                  {p.photo_url ? (
                    <img
                      src={p.photo_url}
                      alt={p.variety}
                      loading="lazy"
                      className={`h-full w-full object-cover ${out ? 'grayscale opacity-50' : ''}`}
                    />
                  ) : (
                    <span className={`text-6xl ${out ? 'grayscale opacity-40' : ''}`} aria-hidden>
                      {CROP_EMOJI[p.crop]}
                    </span>
                  )}
                  {out && (
                    <span className="absolute inset-0 flex items-center justify-center bg-soil-900/55">
                      <span className="rounded-full bg-white/95 px-3 py-1.5 text-[12px] font-bold text-soil-800">
                        Out of stock
                      </span>
                    </span>
                  )}
                  {low && (
                    <span className="absolute left-0 top-2 rounded-r bg-amber-500 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white">
                      Only {sacks(avail)} left
                    </span>
                  )}
                  <span className="absolute bottom-0 left-0 bg-brand-700/90 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white">
                    {titleCase(p.crop)}
                  </span>
                </div>

                <div className="flex flex-1 flex-col gap-1 p-2.5">
                  <h2 className="line-clamp-2 text-[13px] leading-snug text-soil-800">
                    {p.variety}
                  </h2>

                  <p className="num text-[17px] font-bold text-brand-700">{peso(p.price)}</p>
                  <p className="text-[11px] text-soil-400">per sack · {KG_PER_SACK} kg</p>

                  <div className="mt-auto space-y-1 pt-1.5">
                    <p className="num text-[11px] text-soil-600">
                      {out ? 'No stock' : `${sacks(avail)} sacks available`}
                    </p>
                    <p className="flex items-center gap-0.5 truncate text-[11px] text-soil-400">
                      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4">
                        <path d="M12 21s7-6.3 7-11a7 7 0 1 0-14 0c0 4.7 7 11 7 11z" />
                        <circle cx="12" cy="10" r="2.4" />
                      </svg>
                      <button
                        onClick={(ev) => {
                          ev.stopPropagation()
                          if (p.farm_id) setViewingFarm(p.farm_id)
                        }}
                        className="truncate hover:text-brand-700 hover:underline"
                      >
                        {p.farms?.name || p.farms?.city || 'Farm'}
                      </button>
                    </p>
                  </div>

                  <button
                    className={`btn-sm mt-1.5 w-full justify-center py-2 ${
                      out
                        ? 'cursor-not-allowed bg-soil-100 text-soil-400'
                        : 'bg-brand-600 text-white hover:bg-brand-700'
                    }`}
                    disabled={out}
                    onClick={() => setBuying(p)}
                  >
                    {out ? 'Unavailable' : 'Buy Now'}
                  </button>
                </div>
              </article>
            )
          })}
        </div>
      )}

      <FarmProfileDialog farmId={viewingFarm} onClose={() => setViewingFarm(null)} />

      <BuyDialog
        product={buying}
        onClose={() => setBuying(null)}
        onBought={() => {
          setBuying(null)
          load()
        }}
      />
    </div>
  )
}

function BuyDialog({
  product,
  onClose,
  onBought,
}: {
  product: Product | null
  onClose(): void
  onBought(): void
}) {
  const [qty, setQty] = useState('1')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (product) {
      setQty('1')
      setError(null)
    }
  }, [product?.id])

  if (!product) return <Dialog open={false} onClose={onClose} title="">{null}</Dialog>

  const stock = availableSacks(product)
  const asked = /^\d+$/.test(qty) ? toSacks(qty) : null
  const tooMany = asked !== null && asked > stock
  const valid = asked !== null && asked >= 1 && asked <= stock
  const total = valid ? asked * Number(product.price) : 0

  async function confirm() {
    const err = validateSacks(qty, { min: 1, max: availableSacks(product!) })
    setError(err)
    if (err) return

    setBusy(true)

    const { error: rpcError } = await supabase.rpc('purchase_product', {
      p_product_id: product!.id,
      p_quantity: parseInt(qty, 10),
    })
    setBusy(false)

    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success(`Ordered ${sacks(qty)} ${toSacks(qty) === 1 ? 'sack' : 'sacks'}`)
    onBought()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={`Buy ${product.variety}`}
      description={`${product.farms?.name ?? 'Farm'} · ${peso(product.price)} per sack`}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={confirm} disabled={busy || !valid}>
            {busy ? 'Placing order…' : 'Confirm order'}
          </button>
        </>
      }
    >
      <div className="space-y-4">

        <div className="flex items-center justify-between gap-3 rounded-lg bg-brand-50 px-4 py-3">
          <span className="text-[13px] font-semibold text-brand-900">Available now</span>
          <span className="num text-[15px] font-bold text-brand-900">
            {sacks(stock)} sacks
          </span>
        </div>

        <SackInput
          label="How many sacks"
          min={1}
          max={stock}
          value={qty}
          error={error}
          hint={`Up to ${sacks(stock)} · 1 sack = ${KG_PER_SACK} kg`}
          onChange={(e) => {
            setQty(e.target.value)
            setError(null)
          }}
        />

        {tooMany && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3">
            <p className="text-[13px] font-bold text-red-800">
              Only {sacks(stock)} sacks are available
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-red-700">
              You asked for {sacks(asked!)}. Lower your quantity to continue.
            </p>
            <button
              type="button"
              onClick={() => {
                setQty(String(stock))
                setError(null)
              }}
              className="mt-1.5 text-[13px] font-bold text-red-800 underline"
            >
              Order all {sacks(stock)} instead
            </button>
          </div>
        )}

        <dl className="space-y-2 rounded-xl bg-soil-50 px-4 py-3.5 text-sm">
          <div className="flex justify-between">
            <dt className="text-soil-600">Sacks</dt>
            <dd className="num font-semibold">{valid ? sacks(qty) : '—'}</dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-soil-600">Total weight</dt>
            <dd className="num font-semibold">
              {valid ? `${(toSacks(qty) * KG_PER_SACK).toLocaleString('en-PH')} kg` : '—'}
            </dd>
          </div>
          <div className="flex justify-between border-t border-soil-200 pt-2">
            <dt className="font-bold">Total price</dt>
            <dd className="num text-base font-bold text-brand-700">{valid ? peso(total) : '—'}</dd>
          </div>
        </dl>
      </div>
    </Dialog>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\buyer\Orders.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { RateDialog } from '@/components/Ratings'
import { friendlyError } from '@/lib/validation'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Empty, Spinner, Stat, TextArea } from '@/components/ui'
import { OrderTimeline, StageBadge } from '@/components/OrderTimeline'
import {
  CROP_EMOJI,
  effectiveStage,
  peso,
  pesoShort,
  sacks,
  shortDate,
  titleCase,
  weightNote,
} from '@/lib/format'
import type { Order, OrderEvent } from '@/lib/types'

export default function BuyerOrders() {
  const { profile } = useAuth()
  const [orders, setOrders] = useState<Order[] | null>(null)
  const [events, setEvents] = useState<Record<string, OrderEvent[]>>({})
  const [tab, setTab] = useState<string>('all')
  const [cancelling, setCancelling] = useState<Order | null>(null)
  const [rating, setRating] = useState<Order | null>(null)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)

  async function confirmCancel() {
    if (!cancelling) return
    setBusy(true)
    const { error } = await supabase.rpc('buyer_cancel_order', {
      p_order_id: cancelling.id,
      p_reason: reason.trim(),
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Order cancelled')
    setCancelling(null)
    setReason('')

    const { data } = await supabase
      .from('orders')
      .select('*, products(*, farms(name, city, province))')
      .eq('buyer_id', profile!.id)
      .order('created_at', { ascending: false })
    setOrders((data as unknown as Order[]) ?? [])
  }

  useEffect(() => {
    if (!profile) return
    ;(async () => {
      const { data } = await supabase
        .from('orders')
        .select('*, products(*, farms(name, city, province))')
        .eq('buyer_id', profile.id)
        .order('created_at', { ascending: false })
      const list = (data as unknown as Order[]) ?? []
      setOrders(list)

      if (list.length) {
        const { data: evs } = await supabase
          .from('order_events')
          .select('*')
          .in('order_id', list.map((o) => o.id))
          .order('created_at', { ascending: true })

        const grouped: Record<string, OrderEvent[]> = {}
        for (const e of (evs as OrderEvent[]) ?? []) {
          ;(grouped[e.order_id] ??= []).push(e)
        }
        setEvents(grouped)
      }
    })()

    const channel = supabase
      .channel(`buyer-orders-${profile?.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => {
        supabase
          .from('orders')
          .select('*, products(*, farms(name, city, province))')
          .eq('buyer_id', profile!.id)
          .order('created_at', { ascending: false })
          .then(({ data }) => setOrders((data as unknown as Order[]) ?? []))
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [profile?.id])

  if (!orders) return <Spinner label="Loading your orders" />

  const TABS: { key: string; label: string; match: (o: Order) => boolean }[] = [
    { key: 'all', label: 'All', match: () => true },
    {
      key: 'placed',
      label: 'To Confirm',
      match: (o) => effectiveStage(o) === 'placed',
    },
    {
      key: 'confirmed',
      label: 'Order Confirmed',
      match: (o) => effectiveStage(o) === 'confirmed',
    },
    {
      key: 'shipped',
      label: 'Out for Delivery',
      match: (o) => effectiveStage(o) === 'shipped',
    },
    { key: 'completed', label: 'Completed', match: (o) => effectiveStage(o) === 'completed' },
    { key: 'cancelled', label: 'Cancelled', match: (o) => effectiveStage(o) === 'cancelled' },
  ]

  const activeTab = TABS.find((t) => t.key === tab) ?? TABS[0]
  const shown = orders.filter(activeTab.match)

  const spent = orders
    .filter((o) => o.status !== 'cancelled')
    .reduce((s, o) => s + Number(o.total_price), 0)

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">Everything you have bought through FARMS.</p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3">
        <Stat label="Total orders" value={String(orders.length)} />
        <Stat label="Total spent" value={pesoShort(spent)} accent="green" />
      </div>

      <div className="-mx-4 overflow-x-auto px-4 lg:mx-0 lg:px-0">
        <div
          role="tablist"
          className="flex min-w-max gap-1 border-b border-soil-200"
        >
          {TABS.map((t) => {
            const count = orders.filter(t.match).length
            return (
              <button
                key={t.key}
                role="tab"
                aria-selected={tab === t.key}
                onClick={() => setTab(t.key)}
                className={`whitespace-nowrap border-b-2 px-4 py-2.5 text-[13px] font-semibold transition ${
                  tab === t.key
                    ? 'border-brand-600 text-brand-700'
                    : 'border-transparent text-soil-600 hover:text-soil-900'
                }`}
              >
                {t.label}
                {count > 0 && t.key !== 'all' && (
                  <span className="num ml-1 text-brand-600">({count})</span>
                )}
              </button>
            )
          })}
        </div>
      </div>

      {shown.length === 0 ? (
        <Empty
          title={tab === 'all' ? 'No orders yet' : `Nothing under ${activeTab.label}`}
          body={
            tab === 'all'
              ? 'Head to the market to buy rice, corn or watermelon straight from the farm.'
              : 'Orders move through each stage as the farm updates them.'
          }
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {shown.map((o) => {
            const p = o.products
            return (
              <article key={o.id} className="card flex flex-col gap-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <span className="text-2xl" aria-hidden>
                    {p?.crop ? CROP_EMOJI[p.crop] : '📦'}
                  </span>
                  <StageBadge stage={effectiveStage(o)} />
                </div>

                <div>
                  <h2 className="text-base font-bold leading-snug">{p?.variety ?? 'Product'}</h2>
                  <p className="text-[13px] text-soil-600">{p?.farms?.name ?? 'Farm'}</p>
                  <p className="text-[12px] text-soil-400">{shortDate(o.created_at)}</p>
                </div>

                <dl className="mt-auto space-y-1.5 border-t border-soil-200/70 pt-3 text-sm">
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Quantity</dt>
                    <dd className="num font-semibold">{sacks(o.quantity)} sacks</dd>
                  </div>
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Weight</dt>
                    <dd className="num font-semibold">{weightNote(o.quantity).split('= ')[1]}</dd>
                  </div>
                  {p && (
                    <div className="flex justify-between">
                      <dt className="text-soil-600">Price per sack</dt>
                      <dd className="num font-semibold">{peso(p.price)}</dd>
                    </div>
                  )}
                  <div className="flex justify-between border-t border-soil-200/70 pt-1.5">
                    <dt className="font-bold">Total</dt>
                    <dd className="num font-bold text-brand-700">{peso(o.total_price)}</dd>
                  </div>
                </dl>

                <div className="border-t border-soil-200 pt-3">
                  <OrderTimeline
                    stage={effectiveStage(o)}
                    events={events[o.id] ?? []}
                    cancelReason={o.cancel_reason}
                  />
                </div>

                {effectiveStage(o) === 'completed' && (
                  <button
                    className="btn-ghost w-full py-2 text-[13px]"
                    onClick={() => setRating(o)}
                  >
                    ⭐ Rate this seller
                  </button>
                )}

                {['placed', 'confirmed'].includes(effectiveStage(o)) && (
                  <button
                    className="btn-ghost w-full py-2 text-[13px] text-red-600 hover:bg-red-50"
                    onClick={() => {
                      setCancelling(o)
                      setReason('')
                    }}
                  >
                    Cancel order
                  </button>
                )}
              </article>
            )
          })}
        </div>
      )}
      <RateDialog
        open={rating !== null}
        onClose={() => setRating(null)}
        title="Rate this seller"
        description={rating?.products?.farms?.name ?? undefined}
        onSubmit={async (stars, comment) =>
          await supabase.rpc('rate_order', {
            p_order_id: rating!.id,
            p_stars: stars,
            p_comment: comment,
          })
        }
      />

      <Dialog
        open={cancelling !== null}
        onClose={() => setCancelling(null)}
        title="Cancel this order?"
        description={cancelling?.products?.variety}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setCancelling(null)}>
              Keep order
            </button>
            <button className="btn-danger" onClick={confirmCancel} disabled={busy}>
              {busy ? 'Cancelling…' : 'Cancel order'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            The sacks go back on sale and the farm is told. You can only cancel before the farm
            starts preparing your order.
          </p>
          <TextArea
            label="Reason (optional)"
            max={200}
            placeholder="Let the farm know why"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
      </Dialog>
    </div>
  )
}

'@
$script:count++

Write-ProjectFile 'src\pages\buyer\Account.tsx' @'
import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Field, SectionHeading, Spinner } from '@/components/ui'
import {
  friendlyError,
  normalisePhone,
  validateName,
  validatePhone,
  validateRequired,
} from '@/lib/validation'

export default function BuyerAccount() {
  const { profile, refresh } = useAuth()
  const [form, setForm] = useState<Record<string, string>>({})
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!profile) return
    setForm({
      name: profile.name ?? '',
      phone: profile.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile.phone ?? '',
      email: profile.email ?? '',
      company: profile.company ?? '',
      address: profile.address ?? '',
      city: profile.city ?? '',
      zip_code: profile.zip_code ?? '',
    })
  }, [profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    const next = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      address: validateRequired(form.address, 'Delivery address'),
      city: validateRequired(form.city, 'City or municipality'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    const normalised = normalisePhone(form.phone)!

    if (normalised !== profile.phone && (await isPhoneTakenForRole(normalised, 'buyer'))) {
      const msg = 'This number is already registered as a Buyer. Use a different number.'
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    setBusy(true)
    const { error } = await supabase
      .from('profiles')
      .update({
        name: form.name.trim(),
        phone: normalised,
        email: form.email.trim() || null,
        company: form.company.trim() || null,
        address: form.address.trim(),
        city: form.city.trim(),
        zip_code: form.zip_code.trim(),
      })
      .eq('id', profile.id)
    setBusy(false)

    if (error) {
      const msg = /profiles_phone_role_key/.test(error.message)
        ? 'This number is already registered as a Buyer. Use a different number.'
        : friendlyError(error)
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    toast.success('Account saved')
    await refresh()
  }

  if (!profile) return <Spinner />

  return (
    <div className="space-y-6">
      <h1 className="text-[22px] font-bold">Account</h1>

      <AccountHeader subtitle={profile.company ?? 'Buyer'} />

      <form onSubmit={save} className="space-y-5" noValidate>
        <section>
          <SectionHeading>Your details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Full name" value={form.name ?? ''} error={errors.name} onChange={(e) => set('name', e.target.value)} />
            <Field
              label="Mobile number"
              type="tel"
              inputMode="tel"
              value={form.phone ?? ''}
              error={errors.phone}
              onChange={(e) => set('phone', e.target.value)}
            />
            <Field
              label="Email"
              type="email"
              placeholder="Needed for password resets"
              className="sm:col-span-2"
              value={form.email ?? ''}
              onChange={(e) => set('email', e.target.value)}
            />
          </div>
        </section>

        <section>
          <SectionHeading>Delivery details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Company name" className="sm:col-span-2" value={form.company ?? ''} onChange={(e) => set('company', e.target.value)} />
            <Field
              label="Delivery address"
              className="sm:col-span-2"
              placeholder="Purok / street, barangay"
              hint="Farm owners see this on a map when you order."
              value={form.address ?? ''}
              error={errors.address}
              onChange={(e) => set('address', e.target.value)}
            />
            <Field
              label="City or municipality"
              value={form.city ?? ''}
              error={errors.city}
              onChange={(e) => set('city', e.target.value)}
            />
            <Field label="ZIP code" inputMode="numeric" value={form.zip_code ?? ''} onChange={(e) => set('zip_code', e.target.value)} />
          </div>
        </section>

        <button className="btn-primary w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </form>
    </div>
  )
}

'@
$script:count++


Write-Host ''
Write-Host ('Done. ' + $script:count + ' files written.') -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT STEPS' -ForegroundColor Cyan
Write-Host '  1. npm install'
Write-Host '  2. Run the SQL files in supabase\ in order, in the Supabase SQL Editor'
Write-Host '  3. npm run dev'
Write-Host ''
