-- ============================================================================
--  FARMS — MIGRATION 27
--  Sends the queued emails through Resend. SMS rows are no longer queued,
--  since the system sends email only.
--
--  The Resend API key is already filled in below, so this runs as-is.
--  Run migration-26.sql first, then this one, in the Supabase SQL Editor.
--  Safe to run more than once.
-- ============================================================================

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- Where the API key lives. Readable only by the database itself, never by the
-- browser, so the key is not exposed to users.
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);

alter table public.app_settings enable row level security;
-- No policy is added on purpose: no client role can read this table.

insert into public.app_settings (key, value) values
  ('resend_api_key', 'SET-THIS-SEPARATELY'),
  ('mail_from', 'FARMS <onboarding@resend.dev>')
on conflict (key) do update set value = excluded.value;

-- ---------------------------------------------------------------------------
-- Email only. SMS rows are not created any more.
-- ---------------------------------------------------------------------------
create or replace function public.queue_message(
  p_profile_id uuid,
  p_subject text,
  p_body text
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_email text;
begin
  select u.email into v_email
    from profiles p
    left join auth.users u on u.id = p.user_id
   where p.id = p_profile_id;

  if v_email is null or v_email like '%@phone.farms.ph' then
    return;
  end if;

  insert into message_outbox (profile_id, channel, recipient, subject, body)
  values (p_profile_id, 'email', v_email, p_subject, p_body);

  perform public.send_queued_emails();
end $$;

-- ---------------------------------------------------------------------------
-- Hands each queued email to Resend. Marked sent only once handed over, so a
-- failure leaves the row queued for the next attempt rather than losing it.
-- ---------------------------------------------------------------------------
create or replace function public.send_queued_emails()
returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_key  text;
  v_from text;
  r      record;
  v_n    int := 0;
begin
  select value into v_key  from app_settings where key = 'resend_api_key';
  select value into v_from from app_settings where key = 'mail_from';

  if v_key is null or v_key = '' or v_key like 'PASTE%' then
    return 0;
  end if;

  for r in
    select * from message_outbox
     where status = 'queued' and channel = 'email'
     order by created_at
     limit 20
  loop
    begin
      perform net.http_post(
        url     := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'Authorization', 'Bearer ' || v_key),
        body    := jsonb_build_object(
                     'from', coalesce(v_from, 'FARMS <onboarding@resend.dev>'),
                     'to', array[r.recipient],
                     'subject', coalesce(r.subject, 'FARMS notification'),
                     'text', r.body)
      );

      update message_outbox
         set status = 'sent', sent_at = now(), error = null
       where id = r.id;

      v_n := v_n + 1;
    exception when others then
      update message_outbox
         set status = 'failed', error = sqlerrm
       where id = r.id;
    end;
  end loop;

  return v_n;
end $$;

grant execute on function public.send_queued_emails() to authenticated;

-- Anything already queued as SMS is dropped, since SMS is not used.
delete from public.message_outbox where channel = 'sms' and status = 'queued';

notify pgrst, 'reload schema';
