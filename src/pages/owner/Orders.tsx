import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  DataTable,
  Dialog,
  Empty,
  Search,
  Select,
  SectionHeading,
  Spinner,
  Stat,
  TextArea,
  ViewToggle,
} from '@/components/ui'
import { BuyerContactCard } from '@/components/BuyerContactCard'
import { OrderTimeline, StageBadge } from '@/components/OrderTimeline'
import {
  CROP_EMOJI,
  ORDER_STAGES,
  STAGE_LABEL,
  effectiveStage,
  isFinishedOrder,
  peso,
  pesoShort,
  sacks,
  shortDate,
  stageIndex,
} from '@/lib/format'
import { displayPhone, friendlyError } from '@/lib/validation'
import type { Order, OrderEvent, OrderStage, Profile } from '@/lib/types'

type Row = Order & { buyer?: Profile | null }

const TABS: { key: string; label: string; match: (o: Order) => boolean }[] = [
  { key: 'action', label: 'Needs action', match: (o) => !isFinishedOrder(o) },
  { key: 'all', label: 'All', match: () => true },
  { key: 'placed', label: 'To Confirm', match: (o) => effectiveStage(o) === 'placed' },
  { key: 'confirmed', label: 'Order Confirmed', match: (o) => effectiveStage(o) === 'confirmed' },
  { key: 'shipped', label: 'Out for Delivery', match: (o) => effectiveStage(o) === 'shipped' },
  { key: 'unpaid', label: 'Unpaid', match: (o) => !o.paid && effectiveStage(o) !== 'cancelled' },
  { key: 'completed', label: 'Completed', match: (o) => effectiveStage(o) === 'completed' },
  { key: 'cancelled', label: 'Cancelled', match: (o) => effectiveStage(o) === 'cancelled' },
]

export default function OwnerOrders() {
  const { farm } = useAuth()
  const [rows, setRows] = useState<Row[] | null>(null)
  const [events, setEvents] = useState<Record<string, OrderEvent[]>>({})
  const [filter, setFilter] = useState<string>('action')
  const [acting, setActing] = useState<{ order: Row; stage: OrderStage } | null>(null)
  const [view, setView] = useState<'grid' | 'table'>('table')
  const [settling, setSettling] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [varietyFilter, setVarietyFilter] = useState('all')
  const [sukiCounts, setSukiCounts] = useState<Record<string, number>>({})
  const [error, setError] = useState<string | null>(null)

  async function togglePaid(o: Row) {
    setSettling(o.id)
    const { error } = await supabase.rpc('set_order_paid', {
      p_order_id: o.id,
      p_paid: !o.paid,
    })
    setSettling(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(o.paid ? 'Payment undone' : 'Order marked as paid')
    load()
  }

  const load = useCallback(async () => {
    if (!farm) return
    const { data, error: qError } = await supabase
      .from('orders')
      .select('*, products!inner(variety, crop, price, farm_id), profiles!orders_buyer_id_fkey(*)')
      .eq('products.farm_id', farm.id)
      .order('created_at', { ascending: false })

    if (qError) {
      setError(qError.message)
      setRows([])
      return
    }
    setError(null)

    const list = ((data as any[]) ?? []).map((o) => ({ ...o, buyer: (o.profiles as Profile) ?? null }))
    setRows(list)

    const counts: Record<string, number> = {}
    for (const o of list) {
      if (o.stage === 'completed' && o.buyer_id) {
        counts[o.buyer_id] = (counts[o.buyer_id] ?? 0) + 1
      }
    }
    setSukiCounts(counts)

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
  }, [farm?.id])

  useEffect(() => {
    load()
    if (!farm) return

    const channel = supabase
      .channel(`owner-orders-${farm.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [farm?.id, load])

  const varieties = useMemo(
    () =>
      [...new Set((rows ?? []).map((o) => o.products?.variety).filter(Boolean) as string[])].sort(),
    [rows],
  )

  const filtered = useMemo(() => {
    const tab = TABS.find((t) => t.key === filter) ?? TABS[0]
    const q = query.trim().toLowerCase()

    return (rows ?? []).filter((o) => {
      if (!tab.match(o)) return false
      if (varietyFilter !== 'all' && o.products?.variety !== varietyFilter) return false
      if (!q) return true
      return [o.order_no, o.buyer?.name, o.products?.variety]
        .filter(Boolean)
        .some((v) => String(v).toLowerCase().includes(q))
    })
  }, [rows, filter, query, varietyFilter])

  const activeList = useMemo(() => filtered.filter((o) => !isFinishedOrder(o)), [filtered])
  const doneList = useMemo(() => filtered.filter((o) => isFinishedOrder(o)), [filtered])

  if (!rows) return <Spinner label="Loading your orders" />

  const open = rows.filter((o) => !isFinishedOrder(o)).length
  const earned = rows
    .filter((o) => effectiveStage(o) !== 'cancelled')
    .reduce((s, o) => s + Number(o.total_price), 0)

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Move each order along so the buyer can follow its progress.
        </p>
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700"
        >
          <p className="font-semibold">Orders could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
          <button onClick={load} className="mt-2 font-semibold underline">
            Try again
          </button>
        </div>
      )}

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="All orders" value={String(rows.length)} />
        <Stat label="Needs action" value={String(open)} accent={open ? 'red' : undefined} />
        <Stat label="Sales value" value={pesoShort(earned)} accent="green" />
      </div>

      <div className="grid gap-3 sm:grid-cols-[1fr_16rem]">
        <Search
          value={query}
          onChange={setQuery}
          placeholder="Search order ID, buyer or variety"
        />
        <Select
          label=""
          value={varietyFilter}
          onChange={(e) => setVarietyFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All varieties' },
            ...varieties.map((v) => ({ value: v, label: v })),
          ]}
        />
      </div>

      <div className="flex items-end justify-between gap-3">
        <div className="-mx-4 min-w-0 flex-1 overflow-x-auto px-4 lg:mx-0 lg:px-0">
          <div role="tablist" className="scrollbar-none flex min-w-max gap-1 border-b border-soil-200">
            {TABS.map((t) => {
              const count = (rows ?? []).filter(t.match).length
              return (
                <button
                  key={t.key}
                  role="tab"
                  aria-selected={filter === t.key}
                  onClick={() => setFilter(t.key)}
                  className={`whitespace-nowrap border-b-2 px-4 py-2.5 text-[13px] font-semibold transition ${
                    filter === t.key
                      ? 'border-brand-600 text-brand-700'
                      : 'border-transparent text-soil-600 hover:text-soil-900'
                  }`}
                >
                  {t.label}
                  {count > 0 && <span className="num ml-1 text-brand-600">({count})</span>}
                </button>
              )
            })}
          </div>
        </div>
        <ViewToggle view={view} onChange={setView} />
      </div>

      {filtered.length === 0 ? (
        <Empty
          title="No orders here"
          body={
            rows.length === 0
              ? 'When a buyer orders from your market listings, it appears here.'
              : 'Nothing matches this filter.'
          }
        />
      ) : (
        <div className="space-y-6">
          {[
            { key: 'active', title: 'Incoming orders', list: activeList },
            { key: 'done', title: 'Completed orders', list: doneList },
          ]
            .filter((g) => g.list.length > 0)
            .map((group) => (
              <section key={group.key}>
                <SectionHeading>
                  {group.title}
                  <span className="num ml-2 text-soil-400">({group.list.length})</span>
                </SectionHeading>
                {view === 'table' ? (
                  <DataTable
                    minWidth="52rem"
                    headers={[
                      { label: 'Order ID' },
                      { label: 'Date' },
                      { label: 'Product' },
                      { label: 'Buyer' },
                      { label: 'Sacks', align: 'right' },
                      { label: 'Total', align: 'right' },
                      { label: 'Stage' },
                      { label: 'Payment' },
                      { label: 'Action', align: 'right' },
                    ]}
                  >
                    {group.list.map((o) => {
                      const st = effectiveStage(o)
                      const ni = stageIndex(st)
                      const next = ORDER_STAGES[ni + 1]?.stage
                      const canCancel = !['completed', 'cancelled', 'delivered'].includes(st)
                      return (
                        <tr key={o.id}>
                          <td className="num px-4 py-3">
                            <span className="font-semibold text-soil-800">
                              {o.order_no ?? '—'}
                            </span>
                          </td>
                          <td className="num px-4 py-3 text-soil-600">
                            {shortDate(o.created_at)}
                          </td>
                          <td className="px-4 py-3 font-semibold">
                            {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                            {o.products?.variety ?? 'Product'}
                          </td>
                          <td className="px-4 py-3">
                            <span className="flex flex-wrap items-center gap-1.5">
                              <span className="text-soil-800">{o.buyer?.name ?? '—'}</span>
                              {(sukiCounts[o.buyer_id] ?? 0) >= 3 && (
                                <span
                                  title="A regular customer — three or more completed orders"
                                  className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-amber-800"
                                >
                                  <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                                    <path d="M12 2l2.9 6.1 6.6.9-4.8 4.6 1.2 6.6L12 17.1 6.1 20.2l1.2-6.6L2.5 9l6.6-.9z" />
                                  </svg>
                                  Suki
                                </span>
                              )}
                            </span>
                            {o.buyer?.phone && (
                              <a
                                href={`tel:${o.buyer.phone}`}
                                className="num block text-[12px] text-brand-700 underline"
                              >
                                {displayPhone(o.buyer.phone)}
                              </a>
                            )}
                          </td>
                          <td className="num px-4 py-3 text-right font-bold">
                            {sacks(o.quantity)}
                          </td>
                          <td className="num px-4 py-3 text-right font-bold text-brand-700">
                            {peso(o.total_price)}
                          </td>
                          <td className="px-4 py-3">
                            <StageBadge stage={st} />
                          </td>
                          <td className="px-4 py-3">
                            {st === 'cancelled' ? (
                              <span className="text-[12px] text-soil-400">—</span>
                            ) : o.paid ? (
                              <Badge tone="green">Paid</Badge>
                            ) : (
                              <button
                                className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                                disabled={settling === o.id}
                                onClick={() => togglePaid(o)}
                              >
                                {settling === o.id ? '…' : 'Mark paid'}
                              </button>
                            )}
                          </td>
                          <td className="px-4 py-3 text-right">
                            {next || canCancel ? (
                              <span className="inline-flex gap-1.5">
                                {next && (
                                  <button
                                    className="btn-sm bg-brand-600 text-white hover:bg-brand-700 disabled:opacity-40"
                                    disabled={next === 'completed' && !o.paid}
                                    title={
                                      next === 'completed' && !o.paid
                                        ? 'Mark the order as paid first'
                                        : undefined
                                    }
                                    onClick={() => setActing({ order: o, stage: next })}
                                  >
                                    {STAGE_LABEL[next]}
                                  </button>
                                )}
                                {canCancel && (
                                  <button
                                    className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                                    onClick={() => setActing({ order: o, stage: 'cancelled' })}
                                  >
                                    Cancel
                                  </button>
                                )}
                              </span>
                            ) : (
                              <span className="text-[12px] text-soil-400">Done</span>
                            )}
                          </td>
                        </tr>
                      )
                    })}
                  </DataTable>
                ) : (
                <div className="grid gap-3 lg:grid-cols-2">
                  {group.list.map((o) => {
            const stage = effectiveStage(o)
            const idx = stageIndex(stage)
            const nextStage = ORDER_STAGES[idx + 1]?.stage
            const cancellable = !['completed', 'cancelled'].includes(stage)

            return (
              <article key={o.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h2 className="text-[15px] font-bold">
                      {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                      {o.products?.variety ?? 'Product'}
                    </h2>
                    <p className="text-[12px] text-soil-400">
                      Ordered {shortDate(o.created_at)}
                    </p>
                  </div>
                  <StageBadge stage={stage} />
                </div>

                <dl className="space-y-1 text-[13px]">
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Quantity</dt>
                    <dd className="num font-semibold">{sacks(o.quantity)} sacks</dd>
                  </div>
                  <div className="flex justify-between border-t border-soil-200 pt-1">
                    <dt className="font-bold">Total</dt>
                    <dd className="num font-bold text-brand-700">{peso(o.total_price)}</dd>
                  </div>
                </dl>

                <BuyerContactCard buyer={o.buyer} />

                <details className="rounded-lg border border-soil-200">
                  <summary className="cursor-pointer px-3.5 py-2.5 text-[13px] font-semibold">
                    Progress
                  </summary>
                  <div className="border-t border-soil-200 px-3.5 py-3">
                    <OrderTimeline
                      stage={stage}
                      events={events[o.id] ?? []}
                      cancelReason={o.cancel_reason}
                    />
                  </div>
                </details>

                {(nextStage || cancellable) && (
                  <div className="grid grid-cols-2 gap-2 border-t border-soil-200 pt-3">
                    {nextStage ? (
                      <button
                        className="btn-primary py-2 text-[13px]"
                        onClick={() => setActing({ order: o, stage: nextStage })}
                      >
                        {STAGE_LABEL[nextStage]}
                      </button>
                    ) : (
                      <span />
                    )}
                    {cancellable && (
                      <button
                        className="btn-ghost py-2 text-[13px] text-red-600 hover:bg-red-50"
                        onClick={() => setActing({ order: o, stage: 'cancelled' })}
                      >
                        Cancel order
                      </button>
                    )}
                  </div>
                )}
                    </article>
                    )
                  })}
                </div>
                )}
              </section>
            ))}
        </div>
      )}

      <StageDialog
        acting={acting}
        onClose={() => setActing(null)}
        onDone={() => {
          setActing(null)
          load()
        }}
      />
    </div>
  )
}

function StageDialog({
  acting,
  onClose,
  onDone,
}: {
  acting: { order: Order; stage: OrderStage } | null
  onClose(): void
  onDone(): void
}) {
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (acting) setNote('')
  }, [acting?.order.id, acting?.stage])

  if (!acting) return null
  const cancelling = acting.stage === 'cancelled'

  async function confirm() {
    if (cancelling && !note.trim()) {
      toast.error('Give the buyer a reason for the cancellation.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('set_order_stage', {
      p_order_id: acting!.order.id,
      p_stage: acting!.stage,
      p_note: note.trim(),
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(cancelling ? 'Order cancelled — stock returned' : `Marked as ${STAGE_LABEL[acting!.stage]}`)
    onDone()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={cancelling ? 'Cancel this order?' : `Mark as ${STAGE_LABEL[acting.stage]}?`}
      description={acting.order.products?.variety}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Go back
          </button>
          <button
            className={cancelling ? 'btn-danger' : 'btn-primary'}
            onClick={confirm}
            disabled={busy}
          >
            {busy ? 'Saving…' : cancelling ? 'Cancel order' : 'Confirm'}
          </button>
        </>
      }
    >
      <div className="space-y-3">
        {cancelling ? (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-[13px] leading-relaxed text-amber-900">
            The {sacks(acting.order.quantity)} sacks go back into your stock, and a refund entry is
            added to your books so Finance stays accurate.
          </div>
        ) : (
          <p className="text-[14px] leading-relaxed text-soil-800">
            The buyer is notified straight away and sees this stage on their order timeline.
          </p>
        )}

        <TextArea
          label={cancelling ? 'Reason for the buyer' : 'Note for the buyer'}
          max={200}
          placeholder={cancelling ? 'e.g. Harvest was damaged by rain' : 'Optional'}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </div>
    </Dialog>
  )
}
