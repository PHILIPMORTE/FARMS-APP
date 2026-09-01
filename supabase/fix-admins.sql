-- ============================================================================
--  FARMS — RESOLVE DUPLICATE ADMINISTRATORS
--
--  Run STEP 1 first and read the result. Then run STEP 2.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- STEP 1 — See every administrator account you currently have.
-- The oldest one is the one STEP 2 keeps.
-- ---------------------------------------------------------------------------
select p.id,
       p.name,
       p.phone,
       p.created_at,
       u.email,
       case when p.created_at = min(p.created_at) over () then 'KEEP (oldest)' else 'will be removed' end as outcome
  from public.profiles p
  left join auth.users u on u.id = p.user_id
 where p.role = 'admin'
 order by p.created_at;
