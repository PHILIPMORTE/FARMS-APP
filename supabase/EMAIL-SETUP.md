# Turning on email

FARMS queues every notification in `message_outbox`, then hands it to Resend.
Resend's free tier covers 3,000 emails a month, which is far more than a
capstone needs. No card is required.

Takes about five minutes.

---

## 1. Get a Resend API key

1. Go to `resend.com` and sign up. Signing in with GitHub is quickest.
2. Open **API Keys** in the left sidebar.
3. Click **Create API Key**, name it `FARMS`, permission **Sending access**.
4. Copy the key. It starts with `re_`.

**Copy it now.** Resend shows the key once and never again.

---

## 2. Put the key into your database

Supabase SQL Editor:

```sql
update public.app_settings
   set value = 're_paste_your_key_here'
 where key = 'resend_api_key';
```

That's it. The key lives in a table with row level security on and no policy,
so no browser session can read it. Only the database functions can.

---

## 3. Send a test

```sql
select public.queue_message(
  (select id from public.profiles order by created_at limit 1),
  'FARMS test email',
  'If you are reading this, email from FARMS is working.'
);
```

Then check it went:

```sql
select recipient, subject, status, error, sent_at
  from public.message_outbox
 order by created_at desc
 limit 5;
```

- `status = 'sent'` — working. Check the inbox, and the spam folder.
- `status = 'queued'` — the key is still the placeholder. Redo step 2.
- `status = 'failed'` — read the `error` column.

---

## What sends automatically

| When | Who gets it |
|---|---|
| An administrator approves or rejects a verification | The applicant |
| A crop reaches its harvest date | The farm owner |

Both also create an in-app notification, so nothing depends on email arriving.

---

## About the sender address

Out of the box mail is sent from `onboarding@resend.dev`, Resend's shared
testing address. It works immediately but **only delivers to the email address
you signed up to Resend with**. That is fine for a demo.

To send to anyone, verify a domain in Resend under **Domains**, add the DNS
records it gives you at Namecheap, then:

```sql
update public.app_settings
   set value = 'FARMS <noreply@farms-pagatban.me>'
 where key = 'mail_from';
```

---

## Accounts registered by phone

Phone registrations get an internal address like `p639xxxxxxxxx@phone.farms.ph`,
which is not a real mailbox. Those are skipped rather than bounced. Only
accounts with a real email, such as Google sign-ins, receive mail.

This is worth being able to explain: the system does not pretend to email an
address that cannot receive it.

---

## If email is never set up

Nothing breaks. Messages stay in `message_outbox` with status `queued`, and the
in-app notifications still work exactly as before.
