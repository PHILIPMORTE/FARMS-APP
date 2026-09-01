import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/validation'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Empty, Spinner, Stat, TextArea } from '@/components/ui'
import { OrderTimeline, StageBadge } from '@/components/OrderTimeline'
import {
  CROP_EMOJI,
  effectiveStage,
  peso,
  pesoShort,
  sacks,
  shortDate,
  titleCase,
  weightNote,
} from '@/lib/format'
import type { Order, OrderEvent } from '@/lib/types'

export default function BuyerOrders() {
  const { profile } = useAuth()
  const [orders, setOrders] = useState<Order[] | null>(null)
  const [events, setEvents] = useState<Record<string, OrderEvent[]>>({})
  const [tab, setTab] = useState<string>('all')
  const [cancelling, setCancelling] = useState<Order | null>(null)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)

  async function confirmCancel() {
    if (!cancelling) return
    setBusy(true)
    const { error } = await supabase.rpc('buyer_cancel_order', {
      p_order_id: cancelling.id,
      p_reason: reason.trim(),
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Order cancelled')
    setCancelling(null)
    setReason('')

    const { data } = await supabase
      .from('orders')
      .select('*, products(*, farms(name, city, province))')
      .eq('buyer_id', profile!.id)
      .order('created_at', { ascending: false })
    setOrders((data as unknown as Order[]) ?? [])
  }

  useEffect(() => {
    if (!profile) return
    ;(async () => {
      const { data } = await supabase
        .from('orders')
        .select('*, products(*, farms(name, city, province))')
        .eq('buyer_id', profile.id)
        .order('created_at', { ascending: false })
      const list = (data as unknown as Order[]) ?? []
      setOrders(list)

      if (list.length) {
        const { data: evs } = await supabase
          .from('order_events')
          .select('*')
          .in('order_id', list.map((o) => o.id))
          .order('created_at', { ascending: true })

        const grouped: Record<string, OrderEvent[]> = {}
        for (const e of (evs as OrderEvent[]) ?? []) {
          ;(grouped[e.order_id] ??= []).push(e)
        }
        setEvents(grouped)
      }
    })()

    const channel = supabase
      .channel(`buyer-orders-${profile?.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => {
        supabase
          .from('orders')
          .select('*, products(*, farms(name, city, province))')
          .eq('buyer_id', profile!.id)
          .order('created_at', { ascending: false })
          .then(({ data }) => setOrders((data as unknown as Order[]) ?? []))
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [profile?.id])

  if (!orders) return <Spinner label="Loading your orders" />

  const TABS: { key: string; label: string; match: (o: Order) => boolean }[] = [
    { key: 'all', label: 'All', match: () => true },
    {
      key: 'placed',
      label: 'To Confirm',
      match: (o) => effectiveStage(o) === 'placed',
    },
    {
      key: 'confirmed',
      label: 'Order Confirmed',
      match: (o) => effectiveStage(o) === 'confirmed',
    },
    {
      key: 'shipped',
      label: 'Out for Delivery',
      match: (o) => effectiveStage(o) === 'shipped',
    },
    { key: 'completed', label: 'Completed', match: (o) => effectiveStage(o) === 'completed' },
    { key: 'cancelled', label: 'Cancelled', match: (o) => effectiveStage(o) === 'cancelled' },
  ]

  const activeTab = TABS.find((t) => t.key === tab) ?? TABS[0]
  const shown = orders.filter(activeTab.match)

  const spent = orders
    .filter((o) => o.status !== 'cancelled')
    .reduce((s, o) => s + Number(o.total_price), 0)

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">Everything you have bought through FARMS.</p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3">
        <Stat label="Total orders" value={String(orders.length)} />
        <Stat label="Total spent" value={pesoShort(spent)} accent="green" />
      </div>

      <div className="-mx-4 overflow-x-auto px-4 lg:mx-0 lg:px-0">
        <div
          role="tablist"
          className="flex min-w-max gap-1 border-b border-soil-200"
        >
          {TABS.map((t) => {
            const count = orders.filter(t.match).length
            return (
              <button
                key={t.key}
                role="tab"
                aria-selected={tab === t.key}
                onClick={() => setTab(t.key)}
                className={`whitespace-nowrap border-b-2 px-4 py-2.5 text-[13px] font-semibold transition ${
                  tab === t.key
                    ? 'border-brand-600 text-brand-700'
                    : 'border-transparent text-soil-600 hover:text-soil-900'
                }`}
              >
                {t.label}
                {count > 0 && t.key !== 'all' && (
                  <span className="num ml-1 text-brand-600">({count})</span>
                )}
              </button>
            )
          })}
        </div>
      </div>

      {shown.length === 0 ? (
        <Empty
          title={tab === 'all' ? 'No orders yet' : `Nothing under ${activeTab.label}`}
          body={
            tab === 'all'
              ? 'Head to the market to buy rice, corn or watermelon straight from the farm.'
              : 'Orders move through each stage as the farm updates them.'
          }
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {shown.map((o) => {
            const p = o.products
            return (
              <article key={o.id} className="card flex flex-col gap-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <span className="text-2xl" aria-hidden>
                    {p?.crop ? CROP_EMOJI[p.crop] : '📦'}
                  </span>
                  <StageBadge stage={effectiveStage(o)} />
                </div>

                <div>
                  <h2 className="text-base font-bold leading-snug">{p?.variety ?? 'Product'}</h2>
                  <p className="text-[13px] text-soil-600">{p?.farms?.name ?? 'Farm'}</p>
                  <p className="text-[12px] text-soil-400">{shortDate(o.created_at)}</p>
                </div>

                <dl className="mt-auto space-y-1.5 border-t border-soil-200/70 pt-3 text-sm">
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Quantity</dt>
                    <dd className="num font-semibold">{sacks(o.quantity)} sacks</dd>
                  </div>
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Weight</dt>
                    <dd className="num font-semibold">{weightNote(o.quantity).split('= ')[1]}</dd>
                  </div>
                  {p && (
                    <div className="flex justify-between">
                      <dt className="text-soil-600">Price per sack</dt>
                      <dd className="num font-semibold">{peso(p.price)}</dd>
                    </div>
                  )}
                  <div className="flex justify-between border-t border-soil-200/70 pt-1.5">
                    <dt className="font-bold">Total</dt>
                    <dd className="num font-bold text-brand-700">{peso(o.total_price)}</dd>
                  </div>
                </dl>

                <div className="border-t border-soil-200 pt-3">
                  <OrderTimeline
                    stage={effectiveStage(o)}
                    events={events[o.id] ?? []}
                    cancelReason={o.cancel_reason}
                  />
                </div>

                {['placed', 'confirmed'].includes(effectiveStage(o)) && (
                  <button
                    className="btn-ghost w-full py-2 text-[13px] text-red-600 hover:bg-red-50"
                    onClick={() => {
                      setCancelling(o)
                      setReason('')
                    }}
                  >
                    Cancel order
                  </button>
                )}
              </article>
            )
          })}
        </div>
      )}
      <Dialog
        open={cancelling !== null}
        onClose={() => setCancelling(null)}
        title="Cancel this order?"
        description={cancelling?.products?.variety}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setCancelling(null)}>
              Keep order
            </button>
            <button className="btn-danger" onClick={confirmCancel} disabled={busy}>
              {busy ? 'Cancelling…' : 'Cancel order'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            The sacks go back on sale and the farm is told. You can only cancel before the farm
            starts preparing your order.
          </p>
          <TextArea
            label="Reason (optional)"
            max={200}
            placeholder="Let the farm know why"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </div>
      </Dialog>
    </div>
  )
}
