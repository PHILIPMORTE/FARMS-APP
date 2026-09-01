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
