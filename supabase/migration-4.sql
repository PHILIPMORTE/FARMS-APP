-- ============================================================================
--  FARMS — MIGRATION 4
--  Aligns the order stage with the older status column.
--
--  Orders created before the stage column existed kept status = 'completed'
--  or 'cancelled' but received the default stage of 'placed'. That made the
--  same order appear as both incoming and finished. This backfills them.
--
--  Run in the Supabase SQL Editor. Safe to run more than once.
-- ============================================================================

update public.orders
   set stage = 'completed'
 where status = 'completed'
   and stage in ('placed', 'confirmed');

update public.orders
   set stage = 'cancelled'
 where status = 'cancelled'
   and stage <> 'cancelled';

-- Give every order at least one timeline entry so the buyer's tracker is
-- never empty for older purchases.
insert into public.order_events (order_id, stage, note, created_at)
select o.id, o.stage, 'Recorded from earlier order history', o.created_at
  from public.orders o
 where not exists (
   select 1 from public.order_events e where e.order_id = o.id
 );

notify pgrst, 'reload schema';
