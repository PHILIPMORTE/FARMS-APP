-- ============================================================================
--  FARMS — MIGRATION 5
--  ID photo storage, product merging, HR fields and payroll.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-ids', 'verification-ids', false, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists vid_insert on storage.objects;
create policy vid_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-ids'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists vid_update on storage.objects;
create policy vid_update on storage.objects for update to authenticated
  using (bucket_id = 'verification-ids'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists vid_select on storage.objects;
create policy vid_select on storage.objects for select to authenticated
  using (bucket_id = 'verification-ids'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

drop policy if exists vid_delete on storage.objects;
create policy vid_delete on storage.objects for delete to authenticated
  using (bucket_id = 'verification-ids'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.owner_verifications
  alter column id_number drop not null;

alter table public.owner_verifications
  add column if not exists id_photo_path text;

create or replace function public.add_or_merge_product(
  p_farm_id uuid,
  p_variety text,
  p_crop crop_type,
  p_quantity int,
  p_price numeric
)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_existing products%rowtype;
  v_qty      int := floor(p_quantity)::int;
  v_me       uuid := public.my_profile_id('owner');
  v_id       uuid;
  v_merged   boolean := false;
begin
  if not public.owns_farm(p_farm_id) then
    raise exception 'You can only add products to your own farm.';
  end if;
  if v_qty < 1 then
    raise exception 'Enter at least 1 sack.';
  end if;

  select * into v_existing
    from products
   where farm_id = p_farm_id
     and crop = p_crop
     and lower(trim(variety)) = lower(trim(p_variety))
   order by created_at
   limit 1
   for update;

  if found then
    update products
       set quantity = v_existing.quantity + v_qty,
           price    = p_price,
           status   = 'available'
     where id = v_existing.id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_existing.id, p_farm_id, v_me, v_existing.quantity,
            v_existing.quantity + v_qty,
            'Added ' || v_qty || ' sack(s) to the existing listing', 'manual');

    v_id := v_existing.id;
    v_merged := true;
  else
    insert into products (farm_id, variety, crop, quantity, price, status)
    values (p_farm_id, trim(p_variety), p_crop, v_qty, p_price, 'available')
    returning id into v_id;

    insert into stock_changes
      (product_id, farm_id, changed_by, old_quantity, new_quantity, reason, source)
    values (v_id, p_farm_id, v_me, 0, v_qty, 'New listing created', 'manual');
  end if;

  return json_build_object('id', v_id, 'merged', v_merged);
end $$;

alter table public.job_applications
  add column if not exists employment_status text not null default 'active',
  add column if not exists ended_at timestamptz,
  add column if not exists end_reason text;

create or replace function public.payroll_summary(p_month text)
returns table (
  farmer_id    uuid,
  worker_name  text,
  phone        text,
  days_present int,
  days_absent  int,
  days_half    int,
  days_leave   int,
  total_hours  numeric,
  total_pay    numeric
)
language sql stable security definer set search_path = public
as $$
  select
    a.farmer_id,
    p.name,
    p.phone,
    count(*) filter (where a.status = 'present')::int,
    count(*) filter (where a.status = 'absent')::int,
    count(*) filter (where a.status = 'half_day')::int,
    count(*) filter (where a.status = 'leave')::int,
    coalesce(sum(a.hours_worked), 0),
    coalesce(sum(a.computed_pay), 0)
  from attendance a
  join profiles p on p.id = a.farmer_id
  join farms f on f.id = a.farm_id
  where f.owner_id = public.my_profile_id('owner')
    and to_char(a.work_date, 'YYYY-MM') = p_month
  group by a.farmer_id, p.name, p.phone
  order by coalesce(sum(a.computed_pay), 0) desc;
$$;

revoke all on function public.payroll_summary(text) from public;
grant execute on function public.payroll_summary(text) to authenticated;

notify pgrst, 'reload schema';
