-- ============================================================================
--  FARMS — MIGRATION 34
--  The barangay hall, used as the default map centre so every map opens on
--  Pagatban rather than somewhere in the ocean.
--
--  Coordinates taken from the Pagatban Barangay Hall marker.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

insert into public.app_settings (key, value) values
  ('barangay_lat',  '9.37642872'),
  ('barangay_lng',  '122.74101968'),
  ('barangay_name', 'Pagatban, Bayawan City, Negros Oriental')
on conflict (key) do update set value = excluded.value;

-- Readable by anyone signed in: it is a public landmark, not a secret.
create or replace function public.barangay_centre()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'lat',  (select value::numeric from app_settings where key = 'barangay_lat'),
    'lng',  (select value::numeric from app_settings where key = 'barangay_lng'),
    'name', (select value from app_settings where key = 'barangay_name')
  );
$$;

grant execute on function public.barangay_centre() to authenticated;

notify pgrst, 'reload schema';
