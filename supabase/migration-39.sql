-- ============================================================================
--  FARMS — MIGRATION 39
--  Only rice is counted in sacks. Corn is counted in ears and watermelon in
--  fruit, both as pieces, and both are estimated from the plants that grow
--  rather than from a weight of grain per kilogram of seed.
--
--  CORN MODEL
--    seed weight -> land (at the published seed rate per hectare)
--                -> plants (at the published planting distance)
--                -> marketable ears (one per plant, less culls)
--                -> weight (average ear weight)
--
--  The figures come from the Department of Agriculture corn production guide
--  and Philippine growing guides. They live in crop_yields, so they can be
--  corrected against local practice without changing any code.
--
--  Run migration-38.sql first. Safe to run more than once.
-- ============================================================================

alter table public.crop_yields
  add column if not exists plants_per_hectare numeric(10,0),
  add column if not exists spacing_note text;

-- ---------------------------------------------------------------------------
-- CORN
-- Rows 75 cm apart with 25 cm between plants is 0.1875 m2 per plant, which is
-- 53,333 plants per hectare, inside the 50,000 to 60,000 the guides recommend.
-- Seed rate is 20 kg per hectare. One marketable ear is taken from each plant
-- (a plant may set two, but only one is normally marketable), with 10% allowed
-- for plants lost and ears culled. An ear is taken as 0.25 kg.
-- Green (fresh) corn is ready sooner than corn left to dry, so the days to
-- harvest are those for ears sold fresh.
-- ---------------------------------------------------------------------------
update public.crop_yields set
  plants_per_hectare  = 53333,
  fruits_per_plant    = 1.0,
  marketable_fraction = 0.90,
  avg_fruit_kg        = 0.25,
  kg_seed_per_hectare = 20,
  kg_per_kg_seed      = 600,
  spacing_note        = 'rows 75 cm apart with 25 cm between plants'
 where crop = 'corn';

update public.crop_yields set days_to_harvest = 85 where crop = 'corn' and variety in ('', 'White Corn');
update public.crop_yields set days_to_harvest = 75 where crop = 'corn' and variety = 'Sweet Corn';
update public.crop_yields set days_to_harvest = 90 where crop = 'corn' and variety = 'Yellow Corn';

update public.crop_yields set
  spacing_note = 'hills of 4 seeds, 2 m² each, one vine kept per hill'
 where crop = 'watermelon';

-- ---------------------------------------------------------------------------
-- THE UNIT: rice by the sack, everything else by the piece
-- ---------------------------------------------------------------------------
create or replace function public.unit_word(p_crop crop_type, p_n numeric default 2)
returns text language sql immutable
as $$
  select case
           when p_crop = 'rice' then case when p_n = 1 then 'sack' else 'sacks' end
           else case when p_n = 1 then 'piece' else 'pieces' end
         end;
$$;

-- ---------------------------------------------------------------------------
-- LAND NEEDED
-- ---------------------------------------------------------------------------
create or replace function public.land_needed(p_crop crop_type, p_variety text, p_seed_kg numeric)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  r       crop_yields%rowtype;
  v_ha    numeric;
  v_seeds numeric;
  v_hills numeric;
  v_plants numeric;
begin
  select * into r from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));
  if not found then
    select * into r from crop_yields where crop = p_crop and variety = '';
  end if;

  -- Hill-planted crops (watermelon): land follows from the hills sown.
  if r.seeds_per_gram is not null then
    v_seeds  := coalesce(p_seed_kg, 0) * 1000 * r.seeds_per_gram;
    v_hills  := floor(v_seeds / r.seeds_per_hill);
    v_plants := floor(v_hills * r.plants_per_hill);
    return json_build_object(
      'hectares', round(v_hills * r.hill_area_m2 / 10000, 4),
      'sqm',      round(v_hills * r.hill_area_m2, 2),
      'kg_per_hectare', r.kg_seed_per_hectare,
      'seeds', floor(v_seeds), 'hills', v_hills, 'plants', v_plants,
      'caption', to_char(v_hills, 'FM999,999,999') || ' ' || coalesce(r.spacing_note, 'hills')
    );
  end if;

  if coalesce(r.kg_seed_per_hectare, 0) <= 0 then
    return json_build_object('hectares', 0, 'sqm', 0, 'kg_per_hectare', 0);
  end if;

  v_ha := coalesce(p_seed_kg, 0) / r.kg_seed_per_hectare;

  -- Row crops counted in plants (corn): plants follow from the land.
  if r.plants_per_hectare is not null then
    v_plants := floor(v_ha * r.plants_per_hectare);
    return json_build_object(
      'hectares', round(v_ha, 4), 'sqm', round(v_ha * 10000, 2),
      'kg_per_hectare', r.kg_seed_per_hectare, 'plants', v_plants,
      'caption', to_char(v_plants, 'FM999,999,999') || ' plants, ' ||
                 coalesce(r.spacing_note, 'in rows')
    );
  end if;

  return json_build_object(
    'hectares', round(v_ha, 4), 'sqm', round(v_ha * 10000, 2),
    'kg_per_hectare', r.kg_seed_per_hectare
  );
end $$;

grant execute on function public.land_needed(crop_type, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- HARVEST ESTIMATE
-- expected_sacks keeps its name so older code keeps working; it holds the count
-- in the crop's own unit. 'unit' says which.
-- ---------------------------------------------------------------------------
create or replace function public.estimate_harvest(
  p_crop crop_type,
  p_variety text,
  p_seed_kg numeric
)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  r        crop_yields%rowtype;
  v_kg     numeric;
  v_seeds  numeric;
  v_hills  numeric;
  v_plants numeric;
  v_pieces numeric;
  v_ha     numeric;
begin
  select * into r from crop_yields
   where crop = p_crop and lower(trim(variety)) = lower(trim(coalesce(p_variety,'')));
  if not found then
    select * into r from crop_yields where crop = p_crop and variety = '';
  end if;

  if r.fruits_per_plant is not null
     and (r.seeds_per_gram is not null or r.plants_per_hectare is not null) then

    if r.seeds_per_gram is not null then
      v_seeds  := coalesce(p_seed_kg, 0) * 1000 * r.seeds_per_gram;
      v_hills  := floor(v_seeds / r.seeds_per_hill);
      v_plants := floor(v_hills * r.plants_per_hill);
    else
      v_ha     := coalesce(p_seed_kg, 0) / nullif(r.kg_seed_per_hectare, 0);
      v_plants := floor(coalesce(v_ha, 0) * r.plants_per_hectare);
    end if;

    v_pieces := floor(v_plants * r.fruits_per_plant * r.marketable_fraction);
    v_kg     := v_pieces * r.avg_fruit_kg;

    return json_build_object(
      'unit', 'piece',
      'days_to_harvest', coalesce(r.days_to_harvest, 85),
      'expected_kg', round(v_kg, 2),
      'expected_sacks', v_pieces::int,
      'expected_units', v_pieces::int,
      'expected_pieces', v_pieces::int,
      'plants', v_plants,
      'hills', v_hills,
      'seeds', case when v_seeds is null then null else floor(v_seeds) end,
      'fruits_per_plant', r.fruits_per_plant,
      'marketable_fraction', r.marketable_fraction,
      'avg_fruit_kg', r.avg_fruit_kg,
      'kg_per_kg_seed', r.kg_per_kg_seed
    );
  end if;

  v_kg := coalesce(p_seed_kg, 0) * coalesce(r.kg_per_kg_seed, 0);
  return json_build_object(
    'unit', 'sack',
    'kg_per_kg_seed', coalesce(r.kg_per_kg_seed, 0),
    'days_to_harvest', coalesce(r.days_to_harvest, 100),
    'expected_kg', round(v_kg, 2),
    'expected_sacks', floor(v_kg / 25)::int,
    'expected_units', floor(v_kg / 25)::int
  );
end $$;

grant execute on function public.estimate_harvest(crop_type, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Plantings still growing are re-estimated with the new model. Harvested and
-- cancelled plantings stay exactly as recorded.
-- ---------------------------------------------------------------------------
update public.schedules s
   set expected_sacks = (public.estimate_harvest(s.crop, s.variety, s.seed_kg) ->> 'expected_sacks')::int
 where s.crop in ('corn', 'watermelon')
   and s.status not in ('harvested', 'cancelled');

notify pgrst, 'reload schema';
