-- ============================================================================
--  FARMS — MIGRATION 11
--  Administrator invitations.
--
--  A second administrator can only exist if an existing administrator approves
--  the request. Nobody can make themselves an admin, and the single-admin
--  index is replaced by an approval workflow rather than removed outright.
--
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- The one-admin index is replaced by a controlled process, so it goes.
drop index if exists public.profiles_single_admin;

create table if not exists public.admin_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  requester_id  uuid not null references public.profiles(id) on delete cascade,
  full_name     text not null default '',
  phone         text not null default '',
  reason        text not null default '',
  status        verification_status not null default 'pending',
  review_notes  text,
  reviewed_by   uuid references public.profiles(id) on delete set null,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists admin_requests_status_idx on public.admin_requests(status);

-- Only one open request per person at a time.
create unique index if not exists admin_requests_one_pending
  on public.admin_requests (user_id)
  where status = 'pending';

alter table public.admin_requests enable row level security;

drop policy if exists ar_select on public.admin_requests;
create policy ar_select on public.admin_requests for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists ar_insert on public.admin_requests;
create policy ar_insert on public.admin_requests for insert to authenticated
  with check (user_id = auth.uid() and public.is_mine(requester_id));

-- ---------------------------------------------------------------------------
-- REQUEST ADMIN ACCESS
-- Anyone with an existing verified account may ask. It creates nothing but a
-- request; the admin role is only granted on approval.
-- ---------------------------------------------------------------------------
create or replace function public.request_admin_access(p_reason text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_profile profiles%rowtype;
  v_id      uuid;
begin
  select * into v_profile
    from profiles
   where user_id = auth.uid()
   order by created_at
   limit 1;

  if not found then
    raise exception 'Create an account first, then request administrator access.';
  end if;

  if exists (select 1 from profiles where user_id = auth.uid() and role = 'admin') then
    raise exception 'You are already an administrator.';
  end if;

  if exists (
    select 1 from admin_requests where user_id = auth.uid() and status = 'pending'
  ) then
    raise exception 'You already have a request waiting for review.';
  end if;

  insert into admin_requests (user_id, requester_id, full_name, phone, reason)
  values (auth.uid(), v_profile.id, v_profile.name, v_profile.phone, trim(p_reason))
  returning id into v_id;

  -- Tell every current administrator.
  insert into notifications (user_id, message, type, link)
  select p.id,
         coalesce(nullif(v_profile.name, ''), 'Someone') ||
         ' has requested administrator access.',
         'verification', '/admin/requests'
    from profiles p
   where p.role = 'admin';

  return v_id;
end $$;

grant execute on function public.request_admin_access(text) to authenticated;

-- ---------------------------------------------------------------------------
-- REVIEW AN ADMIN REQUEST
-- Approving creates the admin profile. Only an existing administrator can do
-- this, and nobody can approve their own request.
-- ---------------------------------------------------------------------------
create or replace function public.review_admin_request(
  p_request_id uuid,
  p_decision verification_status,
  p_notes text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_req admin_requests%rowtype;
  v_me  uuid := public.my_profile_id('admin');
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can review these requests.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected.';
  end if;

  select * into v_req from admin_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found.'; end if;

  if v_req.user_id = auth.uid() then
    raise exception 'You cannot approve your own request.';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already reviewed.';
  end if;

  update admin_requests
     set status = p_decision,
         review_notes = nullif(p_notes,''),
         reviewed_by = v_me,
         reviewed_at = now()
   where id = p_request_id;

  if p_decision = 'approved' then
    if not exists (select 1 from profiles where user_id = v_req.user_id and role = 'admin') then
      insert into profiles (user_id, role, name, phone)
      values (v_req.user_id, 'admin',
              coalesce(nullif(v_req.full_name,''), 'Administrator'),
              v_req.phone);
    end if;
  end if;

  insert into notifications (user_id, message, type, link)
  values (v_req.requester_id,
          case when p_decision = 'approved'
               then 'Your administrator access has been approved. Sign in at the admin panel.'
               else 'Your request for administrator access was declined.' ||
                    coalesce(' Reason: ' || nullif(p_notes,''), '')
          end,
          'verification', '/');
end $$;

grant execute on function public.review_admin_request(uuid, verification_status, text) to authenticated;

-- ---------------------------------------------------------------------------
-- REMOVE AN ADMINISTRATOR
-- The last administrator cannot be removed, or the system would be locked out
-- of its own management functions.
-- ---------------------------------------------------------------------------
create or replace function public.revoke_admin(p_profile_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_count int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can do this.';
  end if;
  if p_profile_id = public.my_profile_id('admin') then
    raise exception 'You cannot remove your own administrator access.';
  end if;

  select count(*) into v_count from profiles where role = 'admin';
  if v_count <= 1 then
    raise exception 'There must always be at least one administrator.';
  end if;

  delete from profiles where id = p_profile_id and role = 'admin';
end $$;

grant execute on function public.revoke_admin(uuid) to authenticated;

notify pgrst, 'reload schema';
