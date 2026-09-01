-- ============================================================================
--  FARMS — MIGRATION 10
--  Overtime pay and profile pictures.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- OVERTIME
-- Pay was capped at one standard day however many hours were worked. A farm
-- owner may legitimately want longer shifts paid in full, so the cap is gone:
-- pay is now strictly proportional to hours.
-- ---------------------------------------------------------------------------
create or replace function public.compute_attendance_pay()
returns trigger language plpgsql as $$
declare
  v_standard numeric(5,2);
  v_hours    numeric(6,2);
begin
  select coalesce(standard_hours, 8) into v_standard from farms where id = new.farm_id;
  if v_standard is null or v_standard <= 0 then v_standard := 8; end if;

  if new.time_in is not null and new.time_out is not null then
    v_hours := round(extract(epoch from (new.time_out - new.time_in)) / 3600.0, 2);
    if v_hours < 0 then v_hours := 0; end if;
    if v_hours > 24 then v_hours := 24; end if;
    new.hours_worked := v_hours;
    if new.status = 'absent' or new.status = 'leave' then
      new.status := 'present';
    end if;
  end if;

  if new.status = 'absent' or new.status = 'leave' then
    new.hours_worked := 0;
    new.computed_pay := 0;
  elsif new.status = 'half_day' then
    if new.hours_worked = 0 then new.hours_worked := round(v_standard / 2, 2); end if;
    new.computed_pay := round(new.daily_wage * 0.5, 2);
  else
    new.computed_pay := round(new.daily_wage * (new.hours_worked / v_standard), 2);
  end if;

  return new;
end $$;

-- ---------------------------------------------------------------------------
-- PROFILE PICTURES
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 3145728,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists av_read on storage.objects;
create policy av_read on storage.objects for select
  using (bucket_id = 'avatars');

drop policy if exists av_write on storage.objects;
create policy av_write on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists av_update on storage.objects;
create policy av_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists av_delete on storage.objects;
create policy av_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.profiles
  add column if not exists avatar_url text;

notify pgrst, 'reload schema';
