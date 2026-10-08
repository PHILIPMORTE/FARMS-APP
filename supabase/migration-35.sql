-- ============================================================================
--  FARMS — MIGRATION 35
--  Traced boundaries of the eight puroks of Barangay Pagatban.
--
--  Each boundary is stored as a list of [longitude, latitude] corner points.
--  purok_at() tests a map pin against these boundaries first, and falls back
--  to the nearest centre point when the pin lies outside every purok.
--
--  Run migration-33.sql first. Safe to run more than once.
-- ============================================================================

update public.puroks
   set latitude = 9.3725500,
       longitude = 122.7461167,
       boundary = '[[122.7444,9.3737],[122.7441,9.372],[122.7457,9.3712],[122.7475,9.3718],[122.7482,9.373],[122.7468,9.3736],[122.7444,9.3737]]'::jsonb
 where barangay = 'Pagatban' and number = 1;

update public.puroks
   set latitude = 9.3743500,
       longitude = 122.7457000,
       boundary = '[[122.7442,9.3751],[122.7444,9.3737],[122.7468,9.3736],[122.7474,9.375],[122.7442,9.3751]]'::jsonb
 where barangay = 'Pagatban' and number = 2;

update public.puroks
   set latitude = 9.3740000,
       longitude = 122.7477750,
       boundary = '[[122.7474,9.375],[122.7468,9.3736],[122.7482,9.373],[122.7487,9.3744],[122.7474,9.375]]'::jsonb
 where barangay = 'Pagatban' and number = 3;

update public.puroks
   set latitude = 9.3753500,
       longitude = 122.7480250,
       boundary = '[[122.747,9.3763],[122.7474,9.375],[122.7487,9.3744],[122.749,9.3757],[122.747,9.3763]]'::jsonb
 where barangay = 'Pagatban' and number = 4;

update public.puroks
   set latitude = 9.3757500,
       longitude = 122.7456500,
       boundary = '[[122.744,9.3766],[122.7442,9.3751],[122.7474,9.375],[122.747,9.3763],[122.744,9.3766]]'::jsonb
 where barangay = 'Pagatban' and number = 5;

update public.puroks
   set latitude = 9.3756600,
       longitude = 122.7428400,
       boundary = '[[122.7415,9.3768],[122.7415,9.3752],[122.743,9.3746],[122.7442,9.3751],[122.744,9.3766],[122.7415,9.3768]]'::jsonb
 where barangay = 'Pagatban' and number = 6;

update public.puroks
   set latitude = 9.3729000,
       longitude = 122.7426333,
       boundary = '[[122.7414,9.3741],[122.7412,9.3727],[122.7422,9.3716],[122.7441,9.372],[122.7444,9.3737],[122.7425,9.3733],[122.7414,9.3741]]'::jsonb
 where barangay = 'Pagatban' and number = 7;

update public.puroks
   set latitude = 9.3743333,
       longitude = 122.7428333,
       boundary = '[[122.7415,9.3752],[122.7414,9.3741],[122.7425,9.3733],[122.7444,9.3737],[122.7442,9.3751],[122.743,9.3746],[122.7415,9.3752]]'::jsonb
 where barangay = 'Pagatban' and number = 8;

-- Confirm every purok now carries a boundary.
select number,
       name,
       latitude,
       longitude,
       jsonb_array_length(boundary) as corner_points,
       case when boundary is null then 'NOT TRACED' else 'traced' end as state
  from public.puroks
 where barangay = 'Pagatban'
 order by number;

notify pgrst, 'reload schema';
