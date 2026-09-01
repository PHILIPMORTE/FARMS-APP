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
