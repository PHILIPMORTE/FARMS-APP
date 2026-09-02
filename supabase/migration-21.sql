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
