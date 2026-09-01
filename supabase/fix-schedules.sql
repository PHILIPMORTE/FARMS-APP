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
