-- ============================================================================
--  FARMS — MIGRATION 52
--  A saved delivery address can be named anything, not only Home, Work or Other.
--
--  The address form now asks "Name this address" when a buyer picks Other, so
--  the saved label is what they typed (Mom's house, Farm stall) and the order
--  list never shows just "Other". The database only accepted those three words,
--  so this widens it to any name of 2 to 30 characters.
--
--  Addresses already saved keep their labels. Home, Work and Other still work.
--
--  Run after migration-51.sql. Safe to run more than once.
-- ============================================================================

alter table public.buyer_addresses
  drop constraint if exists buyer_addresses_label_valid;

alter table public.buyer_addresses
  add constraint buyer_addresses_label_valid
  check (char_length(btrim(label)) between 2 and 30);

-- The saving function is read as it is in the database right now, its label check
-- is changed, and it is saved again. If it is not in the expected shape, the
-- migration stops with a message and nothing is changed.
do $patch$
declare
  v_def  text;
  v_new  text;
  v_seen int := 0;
begin
  for v_def in
    select pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'save_buyer_address'
  loop
    v_seen := v_seen + 1;
    v_new := v_def;

    if position('char_length(v_label)' in v_new) = 0 then
      if position('if v_label not in (''Home'', ''Work'', ''Other'') then' in v_new) = 0
         or position('raise exception ''Choose Home, Work or Other.'';' in v_new) = 0 then
        raise exception 'save_buyer_address is not in the expected shape; nothing was changed.';
      end if;
      v_new := replace(
        v_new,
        'if v_label not in (''Home'', ''Work'', ''Other'') then',
        'if char_length(v_label) < 2 or char_length(v_label) > 30 then'
      );
      v_new := replace(
        v_new,
        'raise exception ''Choose Home, Work or Other.'';',
        'raise exception ''Name this address in 2 to 30 characters, like Home, Work or Farm stall.'';'
      );
    end if;

    if v_new <> v_def then execute v_new; end if;
  end loop;

  if v_seen = 0 then
    raise exception 'Function public.save_buyer_address was not found. Run migration-50.sql first.';
  end if;
end $patch$;

notify pgrst, 'reload schema';
