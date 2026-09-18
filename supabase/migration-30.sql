-- ============================================================================
--  FARMS — MIGRATION 30
--  Applicants can attach a resume and an ID, and the hire notice carries the
--  job title and the farm owner's number so the worker knows who to call.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. ATTACHMENTS ON A JOB APPLICATION
-- A private bucket: an applicant uploads to their own folder, and only they,
-- the farm owner who received the application, and an administrator can read.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('applications', 'applications', false, 10485760,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists app_upload on storage.objects;
create policy app_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'applications'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists app_change on storage.objects;
create policy app_change on storage.objects for update to authenticated
  using (bucket_id = 'applications'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists app_read on storage.objects;
create policy app_read on storage.objects for select to authenticated
  using (
    bucket_id = 'applications'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
      or exists (
        select 1
          from public.job_applications a
          join public.job_posts j on j.id = a.job_id
          join public.profiles p on p.id = a.farmer_id
         where p.user_id::text = (storage.foldername(name))[1]
           and j.owner_id = public.my_profile_id('owner')
      )
    )
  );

drop policy if exists app_remove on storage.objects;
create policy app_remove on storage.objects for delete to authenticated
  using (bucket_id = 'applications'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.job_applications
  add column if not exists resume_path text,
  add column if not exists id_photo_path text,
  add column if not exists work_photo_paths text[] not null default '{}';

-- ---------------------------------------------------------------------------
-- 2. A HIRE NOTICE THAT TELLS THE WORKER WHO TO CALL
-- ---------------------------------------------------------------------------
create or replace function public.decide_application(
  p_application_id uuid,
  p_decision app_status,
  p_note text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_app   job_applications%rowtype;
  v_job   job_posts%rowtype;
  v_me    uuid := public.my_profile_id('owner');
  v_phone text;
  v_farm  text;
begin
  if p_decision not in ('accepted','rejected') then
    raise exception 'Decision must be accepted or rejected.';
  end if;

  select * into v_app from job_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;

  select * into v_job from job_posts where id = v_app.job_id;
  if v_job.owner_id <> v_me then
    raise exception 'That job posting is not yours.';
  end if;

  if p_decision = 'rejected' and coalesce(trim(p_note), '') = '' then
    raise exception 'Give the applicant a reason for the rejection.';
  end if;

  select p.phone, f.name into v_phone, v_farm
    from profiles p
    left join farms f on f.owner_id = p.id
   where p.id = v_me;

  update job_applications
     set status = p_decision,
         message = case
                     when p_decision = 'rejected'
                     then coalesce(nullif(message, '') || ' | ', '') || 'Reason: ' || trim(p_note)
                     else message
                   end,
         updated_at = now()
   where id = p_application_id;

  insert into notifications (user_id, message, type, link)
  values (v_app.farmer_id,
          case when p_decision = 'accepted'
               then 'You were hired as ' || v_job.title ||
                    coalesce(' at ' || nullif(v_farm, ''), '') ||
                    '. Please contact ' || coalesce(v_phone, 'the farm owner') || '.'
               else 'Your application for ' || v_job.title ||
                    ' was not accepted. Reason: ' || trim(p_note)
          end,
          'application', '/farmer/applications');

  if p_decision = 'accepted' then
    perform public.queue_message(
      v_app.farmer_id,
      'You were hired as ' || v_job.title,
      'FARMS: You were hired as ' || v_job.title ||
      coalesce(' at ' || nullif(v_farm, ''), '') ||
      '. Please contact the farm owner on ' || coalesce(v_phone, 'the number in the app') ||
      ' to arrange your first day.');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. IS THIS NUMBER ALREADY REGISTERED FOR THIS ROLE?
-- Returns enough for the sign-up form to say something useful rather than
-- failing with a database error.
-- ---------------------------------------------------------------------------
create or replace function public.registration_status(p_phone text, p_role user_role)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'taken', exists (select 1 from profiles where phone = p_phone and role = p_role),
    'other_roles', coalesce((
      select json_agg(role::text order by role)
        from profiles
       where phone = p_phone and role <> p_role), '[]'::json),
    'verification', coalesce((
      select v.status::text
        from owner_verifications v
        join profiles p on p.id = v.profile_id
       where p.phone = p_phone and p.role = p_role
       limit 1), 'none')
  );
$$;

grant execute on function public.registration_status(text, user_role) to anon, authenticated;

notify pgrst, 'reload schema';
