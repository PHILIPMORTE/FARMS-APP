-- ============================================================================
--  FARMS — MIGRATION 51
--  Watermelon is SOLD by the kilo (the Market, orders, prices). It is still
--  COUNTED in pieces (fruit) on the Calendar when it is harvested.
--
--  A farm owner counts the fruit in the field, then weighs the harvest and sells
--  it by weight, so the two units are not the same number and must not be mixed.
--
--  What this migration changes
--    1. Adds sale_word() and sale_phrase(): "40 kg" for watermelon, and the usual
--       "3 sacks" / "5 pieces" for rice and corn.
--    2. The messages sent when something is SOLD (an order placed, an order
--       moved along, a GCash reference sent, stock added to a listing) now say
--       "kg" for watermelon. Harvest messages still say pieces.
--    3. Listing watermelon on the Market no longer adds a row to the inventory
--       log. That log counts what was harvested (in fruit); a listing in kilos
--       would have been added to it as if it were fruit.
--    4. Recording a harvest with a price no longer auto-lists watermelon, for the
--       same reason: fruit cannot be turned into kilos without weighing it. The
--       owner lists it from the Market with the weighed kilos.
--
--  Nothing is deleted and no numbers are changed. Rice and corn behave exactly
--  as before. A watermelon listing made before this change keeps its number,
--  which now reads as kilos: edit its stock and price, or remove it.
--
--  Run after migration-50.sql. Safe to run more than once.
-- ============================================================================

-- 1. WORDS FOR WHAT IS SOLD --------------------------------------------------
create or replace function public.sale_word(p_crop crop_type, p_n numeric default 2)
returns text language sql immutable
as $$
  select case
           when p_crop = 'watermelon' then 'kg'
           else public.unit_word(p_crop, p_n)
         end;
$$;

create or replace function public.sale_phrase(p_crop crop_type, p_n numeric)
returns text language sql immutable
as $$
  select trim_scale(p_n)::text || ' ' || public.sale_word(p_crop, p_n);
$$;

grant execute on function public.sale_word(crop_type, numeric) to authenticated;
grant execute on function public.sale_phrase(crop_type, numeric) to authenticated;

-- 2-4. USE THEM WHERE SOMETHING IS SOLD --------------------------------------
-- Each function is read as it exists in the database right now, changed in the
-- few places named above, and saved again. Doing it this way keeps whatever the
-- earlier migrations put in them. If a function is not in the shape expected,
-- the whole migration stops with a message and nothing is changed.
do $patch$
declare
  v_name text;
  v_def  text;
  v_new  text;
  v_seen int;
begin
  -- sale messages: "ordered 5 kg of Sweet Beauty"
  foreach v_name in array array['purchase_product', 'set_order_stage', 'submit_gcash_reference'] loop
    v_seen := 0;
    for v_def in
      select pg_get_functiondef(p.oid)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name
    loop
      v_seen := v_seen + 1;
      v_new := replace(v_def, 'unit_phrase(', 'sale_phrase(');
      if v_new <> v_def then execute v_new; end if;
    end loop;
    if v_seen = 0 then
      raise exception 'Function public.% was not found. Run the earlier migrations first.', v_name;
    end if;
  end loop;

  -- listing stock: sale message, and no inventory row for watermelon
  v_seen := 0;
  for v_def in
    select pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'add_or_merge_product'
  loop
    v_seen := v_seen + 1;
    v_new := replace(v_def, 'unit_phrase(', 'sale_phrase(');
    if position('p_crop <> ''watermelon''' in v_new) = 0 then
      if position('insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);' in v_new) = 0 then
        raise exception 'add_or_merge_product is not in the expected shape; nothing was changed.';
      end if;
      v_new := replace(
        v_new,
        'insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty);',
        'if p_crop <> ''watermelon'' then insert into inventory (farm_id, crop, quantity) values (p_farm_id, p_crop, v_qty); end if;'
      );
    end if;
    if v_new <> v_def then execute v_new; end if;
  end loop;
  if v_seen = 0 then
    raise exception 'Function public.add_or_merge_product was not found. Run the earlier migrations first.';
  end if;

  -- recording a harvest with a price: never list watermelon from a fruit count
  v_seen := 0;
  for v_def in
    select pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'harvest_schedule'
  loop
    v_seen := v_seen + 1;
    v_new := v_def;
    if position('v_sched.crop <> ''watermelon''' in v_new) = 0 then
      if position('if p_price is not null and p_price > 0 then' in v_new) = 0 then
        raise exception 'harvest_schedule is not in the expected shape; nothing was changed.';
      end if;
      v_new := replace(
        v_new,
        'if p_price is not null and p_price > 0 then',
        'if p_price is not null and p_price > 0 and v_sched.crop <> ''watermelon'' then'
      );
    end if;
    if v_new <> v_def then execute v_new; end if;
  end loop;
  if v_seen = 0 then
    raise exception 'Function public.harvest_schedule was not found. Run the earlier migrations first.';
  end if;
end $patch$;

notify pgrst, 'reload schema';
