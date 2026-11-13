-- ============================================================================
--  FARMS — MIGRATION 42
--  Fruit per vine is set per variety. A small-fruited watermelon can carry more
--  fruit on a vine than a large-fruited one, so one figure for every variety
--  was too blunt.
--
--  SUGAR BABY (small fruit, about 4 kg)  3 fruit per vine at healthy growth.
--     University of Georgia extension gives two to three fruit per plant under
--     average conditions, and a North Carolina State trial recorded up to 3.7
--     fruit per plant on its best entry. Three is the healthy-plant target.
--
--  ALL OTHER WATERMELON (medium fruit)    2 fruit per vine, unchanged.
--     Inside the 1.5 to 2.5 harvestable fruit per plant that growers average.
--
--  A large-fruited variety would carry fewer, so a profile with 1 to 2 fruit per
--  vine and a heavier fruit can be added to crop_yields when one is grown here.
--
--  These are targets for healthy plants. Fruit per vine falls as plants are
--  packed closer, and field averages sit below the target.
--
--  Run migration-41.sql first. Safe to run more than once.
-- ============================================================================

update public.crop_yields set
  fruits_per_plant = 3.0,
  kg_per_kg_seed   = 66000
 where crop = 'watermelon' and variety = 'Sugar Baby';

-- Plantings still growing are re-estimated against the new figure.
update public.schedules s
   set expected_sacks = (public.estimate_harvest(s.crop, s.variety, s.seed_kg) ->> 'expected_sacks')::int
 where s.crop = 'watermelon'
   and s.status not in ('harvested', 'cancelled');

notify pgrst, 'reload schema';
