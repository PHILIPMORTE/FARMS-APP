-- ============================================================================
--  FARMS — SEND A TEST EMAIL
--  Run this after migration-27.sql to check email is working.
-- ============================================================================

-- Sends to whichever account has a real email address on it.
select public.queue_message(
  (select p.id
     from public.profiles p
     join auth.users u on u.id = p.user_id
    where u.email not like '%@phone.farms.ph'
    order by p.created_at
    limit 1),
  'FARMS test email',
  'If you are reading this, email from FARMS is working.'
);

-- Then read the result.
select recipient, subject, status, error, sent_at
  from public.message_outbox
 order by created_at desc
 limit 5;

-- status = 'sent'   -> working, check your inbox and spam folder
-- status = 'queued' -> the key did not save, re-run migration-27.sql
-- status = 'failed' -> read the error column
