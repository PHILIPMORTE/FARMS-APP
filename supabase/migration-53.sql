-- ============================================================================
--  FARMS — MIGRATION 53
--  Watermelon is counted in PIECES again, and each piece is taken as 1 kg.
--
--  Migration 51 made the Market count watermelon in kilos. That is replaced by a
--  simpler rule: a watermelon is a piece, a piece is 1 kg, so the Market lists
--  watermelon by the number of pieces taken from the harvest inventory, and the
--  price is written per kg. The app does the wording; the numbers in the database
--  are pieces, the same as on the Calendar.
--
--  This migration undoes what migration 51 changed in the database:
--    1. Messages about a watermelon order or listing say "pieces" again, not "kg".
--    2. Listing watermelon adds to the inventory log again, like corn does.
--    3. Recording a harvest with a price can list watermelon again.
--
--  It is safe whether or not migration 51 was run, and safe to run more than once.
--  Nothing is deleted and no numbers are changed. A watermelon listing made while
--  the Market counted kilos keeps its number, which now reads as pieces (the same
--  number, because a piece is 1 kg).
--
--  Run after migration-52.sql.
-- ============================================================================

-- 1. sale_word() goes back to the crop's own unit, so every message says pieces.
create or replace function public.sale_word(p_crop crop_type, p_n numeric default 2)
returns text language sql immutable
as $$
  select public.unit_word(p_crop, p_n);
$$;

grant execute on function public.sale_word(crop_type, numeric) to authenticated;

-- 2-3. Put the functions back the way they were before migration 51.
do $patch$
declare
  v_name text;
  v_def  text;
  v_new  text;
begin
  foreach v_name in array array[
    'purchase_product', 'set_order_stage', 'submit_gcash_reference',
    'add_or_merge_product', 'harvest_schedule'
  ] loop
    for v_def in
      select pg_get_functiondef(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name
    loop
      v_new := replace(v_def, 'sale_phrase(', 'unit_phrase(');

      -- listing stock adds to the inventory log for every crop again
      v_new := replace(
        v_new,
        'if p_crop <> ''watermelon'' then insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty); end if;',
        'insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);'
      );

      -- a harvest recorded with a price can list watermelon again
      v_new := replace(
        v_new,
        'if p_price is not null and p_price > 0 and v_sched.crop <> ''watermelon'' then',
        'if p_price is not null and p_price > 0 then'
      );

      if v_new <> v_def then execute v_new; end if;
    end loop;
  end loop;
end $patch$;

notify pgrst, 'reload schema';
