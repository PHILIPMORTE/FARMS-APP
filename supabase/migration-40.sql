-- ============================================================================
--  FARMS — MIGRATION 40
--  The harvest estimate for watermelon and corn is the TARGET: the number of
--  pieces the planting should bear when the plants are at their healthiest.
--
--  Earlier the count was reduced by an allowance for culls (80% for watermelon,
--  90% for corn). That allowance was an assumption with no published source, and
--  it made the figure lower than the healthy-plant target the estimate is meant
--  to show. It is removed, so:
--
--      target pieces = plants x fruit per plant at healthy growth
--
--  WATERMELON  2 fruit per vine, the upper end of the 1.5 to 2 full-size fruit a
--              vine bears on commercial farms. Average fruit 4 kg, so a healthy
--              hectare of 5,000 vines reaches 40 t, the top of the 20 to 40 t per
--              hectare given for the Philippines.
--  CORN        1 marketable ear per plant. A plant may set two ears, but only one
--              is normally marketable, so one is the target.
--
--  The figures stay in crop_yields and can be corrected without changing code.
--
--  Run migration-39.sql first. Safe to run more than once.
-- ============================================================================

update public.crop_yields set
  fruits_per_plant    = 2.0,
  marketable_fraction = 1.0,
  avg_fruit_kg        = 4.0,
  kg_per_kg_seed      = 44000
 where crop = 'watermelon';

update public.crop_yields set
  fruits_per_plant    = 1.0,
  marketable_fraction = 1.0,
  avg_fruit_kg        = 0.25,
  kg_per_kg_seed      = 666.5
 where crop = 'corn';

-- Plantings still growing are re-estimated against the target. Harvested and
-- cancelled plantings stay exactly as recorded.
update public.schedules s
   set expected_sacks = (public.estimate_harvest(s.crop, s.variety, s.seed_kg) ->> 'expected_sacks')::int
 where s.crop in ('corn', 'watermelon')
   and s.status not in ('harvested', 'cancelled');

notify pgrst, 'reload schema';
