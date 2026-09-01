-- ============================================================================
--  FARMS — ADMINISTRATOR TOOLS
--  Pick ONE option below and run only that block.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0 — Find the user id you want to work with.
-- Register the person normally through any login page first, then run this.
-- ---------------------------------------------------------------------------
select u.id as user_id,
       u.email,
       u.phone,
       p.role,
       p.name
  from auth.users u
  left join public.profiles p on p.user_id = u.id
 order by u.created_at desc;


-- ---------------------------------------------------------------------------
-- OPTION A — REPLACE the administrator (still only one).
-- Removes the current admin profile and makes someone else the admin.
-- The old admin keeps any other roles they hold.
-- ---------------------------------------------------------------------------
-- delete from public.profiles where role = 'admin';
--
-- insert into public.profiles (user_id, role, name, phone)
-- values ('PASTE-USER-ID-HERE', 'admin', 'System Administrator', '+639000000001');


-- ---------------------------------------------------------------------------
-- OPTION B — ALLOW MORE THAN ONE administrator.
-- Drops the single-admin rule, then adds the new one. Every admin has full
-- access to users, verifications, products and orders, so only do this for
-- people who genuinely need it.
-- ---------------------------------------------------------------------------
-- drop index if exists public.profiles_single_admin;
--
-- insert into public.profiles (user_id, role, name, phone)
-- values ('PASTE-USER-ID-HERE', 'admin', 'Second Administrator', '+639000000002');


-- ---------------------------------------------------------------------------
-- OPTION C — GO BACK to one administrator after using Option B.
-- Keeps the oldest admin and removes the rest, then restores the rule.
-- ---------------------------------------------------------------------------
-- delete from public.profiles
--  where role = 'admin'
--    and id <> (select id from public.profiles where role = 'admin' order by created_at limit 1);
--
-- create unique index if not exists profiles_single_admin
--   on public.profiles ((role))
--   where role = 'admin';


notify pgrst, 'reload schema';
