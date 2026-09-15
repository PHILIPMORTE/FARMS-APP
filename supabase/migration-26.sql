-- ============================================================================
--  FARMS — MIGRATION 26
--  Readable order numbers, and an outbox that queues SMS and email so they
--  can be sent by a provider without losing the message if sending fails.
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. ORDER NUMBER
-- A short human reference the buyer and farm can both quote.
-- ---------------------------------------------------------------------------
create sequence if not exists public.order_number_seq start 1000;

alter table public.orders
  add column if not exists order_no text;

create or replace function public.set_order_no()
returns trigger language plpgsql as $$
begin
  if new.order_no is null then
    new.order_no := 'FA-' || to_char(now(), 'YYMM') || '-' ||
                    lpad(nextval('public.order_number_seq')::text, 4, '0');
  end if;
  return new;
end $$;

drop trigger if exists trg_set_order_no on public.orders;
create trigger trg_set_order_no
  before insert on public.orders
  for each row execute function public.set_order_no();

update public.orders
   set order_no = 'FA-' || to_char(created_at, 'YYMM') || '-' ||
                  lpad(nextval('public.order_number_seq')::text, 4, '0')
 where order_no is null;

create unique index if not exists orders_order_no_key on public.orders(order_no);

-- ---------------------------------------------------------------------------
-- 2. MESSAGE OUTBOX
-- Rows are written by the system and picked up by whatever provider is
-- connected. Queuing rather than sending directly means a provider outage
-- delays a message instead of losing it.
-- ---------------------------------------------------------------------------
do $$ begin
  create type message_channel as enum ('sms','email');
exception when duplicate_object then null; end $$;

do $$ begin
  create type message_state as enum ('queued','sent','failed');
exception when duplicate_object then null; end $$;

create table if not exists public.message_outbox (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid references public.profiles(id) on delete set null,
  channel     message_channel not null,
  recipient   text not null,
  subject     text,
  body        text not null,
  status      message_state not null default 'queued',
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);

create index if not exists outbox_queued_idx on public.message_outbox(status, created_at);

alter table public.message_outbox enable row level security;

drop policy if exists outbox_admin on public.message_outbox;
create policy outbox_admin on public.message_outbox for select to authenticated
  using (public.is_admin() or public.is_mine(profile_id));

create or replace function public.queue_message(
  p_profile_id uuid,
  p_subject text,
  p_body text
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_phone text;
  v_email text;
begin
  select p.phone, u.email into v_phone, v_email
    from profiles p
    left join auth.users u on u.id = p.user_id
   where p.id = p_profile_id;

  if v_phone is not null and v_phone <> '' then
    insert into message_outbox (profile_id, channel, recipient, subject, body)
    values (p_profile_id, 'sms', v_phone, p_subject, p_body);
  end if;

  if v_email is not null and v_email not like '%@phone.farms.ph' then
    insert into message_outbox (profile_id, channel, recipient, subject, body)
    values (p_profile_id, 'email', v_email, p_subject, p_body);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. HARVEST READY
-- Called from the dashboard each day. Sends once per planting.
-- ---------------------------------------------------------------------------
alter table public.schedules
  add column if not exists harvest_notified_at timestamptz;

create or replace function public.notify_ready_harvests()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  r     record;
  v_n   int := 0;
begin
  for r in
    select s.id, s.crop, s.variety, s.harvest_date, s.expected_sacks,
           f.owner_id, f.name as farm_name
      from schedules s
      join farms f on f.id = s.farm_id
     where s.status <> 'harvested'
       and s.status <> 'cancelled'
       and s.harvest_date is not null
       and s.harvest_date <= current_date
       and s.harvest_notified_at is null
       and f.owner_id = public.my_profile_id('owner')
  loop
    perform public.queue_message(
      r.owner_id,
      'Your ' || coalesce(nullif(r.variety, ''), r.crop::text) || ' is ready to harvest',
      'FARMS: Your ' || coalesce(nullif(r.variety, ''), r.crop::text) ||
      ' at ' || r.farm_name || ' reached its harvest date on ' ||
      to_char(r.harvest_date, 'FMMon DD, YYYY') || '. About ' || r.expected_sacks ||
      ' sacks expected. Open FARMS to record the harvest.');

    insert into notifications (user_id, message, type, link)
    values (r.owner_id,
            coalesce(nullif(r.variety, ''), r.crop::text) || ' is ready to harvest.',
            'harvest', '/owner/calendar');

    update schedules set harvest_notified_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

grant execute on function public.notify_ready_harvests() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. VERIFICATION RESULT
-- ---------------------------------------------------------------------------
create or replace function public.review_owner_verification(
  p_verification_id uuid,
  p_decision verification_status,
  p_notes text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_row  owner_verifications%rowtype;
  v_me   uuid := public.my_profile_id('admin');
  v_role user_role;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator can review verifications.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected.';
  end if;

  select * into v_row from owner_verifications where id = p_verification_id for update;
  if not found then raise exception 'Verification request not found.'; end if;

  select role into v_role from profiles where id = v_row.profile_id;

  update owner_verifications
     set status = p_decision,
         review_notes = nullif(p_notes,''),
         reviewed_by = v_me,
         reviewed_at = now()
   where id = p_verification_id;

  if p_decision = 'approved' and v_role = 'owner' then
    if exists (select 1 from farms where owner_id = v_row.profile_id) then
      update farms
         set latitude  = coalesce(v_row.latitude, latitude),
             longitude = coalesce(v_row.longitude, longitude)
       where owner_id = v_row.profile_id;
    else
      insert into farms (owner_id, name, address, city, latitude, longitude)
      values (v_row.profile_id,
              coalesce(nullif(v_row.farm_name,''), 'My Farm'),
              v_row.farm_address, v_row.barangay,
              v_row.latitude, v_row.longitude);
    end if;
  end if;

  perform public.queue_message(
    v_row.profile_id,
    case when p_decision = 'approved'
         then 'Your FARMS account is verified'
         else 'Your FARMS verification was not approved' end,
    case when p_decision = 'approved'
         then 'FARMS: Good news. Your account has been verified and is ready to use. ' ||
              'You can now sign in and start using the system.'
         else 'FARMS: Your verification was not approved.' ||
              coalesce(' Reason: ' || nullif(p_notes,''), '') ||
              ' You may correct your details and submit again.'
    end);

  insert into notifications (user_id, message, type, link)
  values (v_row.profile_id,
          case when p_decision = 'approved'
               then 'Your account has been verified. You now have full access.'
               else 'Your verification was not approved.' ||
                    coalesce(' Reason: ' || nullif(p_notes,''), '')
          end,
          'verification', '/');
end $$;

notify pgrst, 'reload schema';
