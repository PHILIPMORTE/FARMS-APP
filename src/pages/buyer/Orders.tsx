import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, Empty, Spinner, Stat } from '@/components/ui'
import { CROP_EMOJI, peso, pesoShort, sacks, shortDate, titleCase, weightNote } from '@/lib/format'
import type { Order } from '@/lib/types'

export default function BuyerOrders() {
  const { profile } = useAuth()
  const [orders, setOrders] = useState<Order[] | null>(null)

  useEffect(() => {
    if (!profile) return
    ;(async () => {
      const { data } = await supabase
        .from('orders')
        .select('*, products(*, farms(name, city, province))')
        .eq('buyer_id', profile.id)
        .order('created_at', { ascending: false })
      setOrders((data as unknown as Order[]) ?? [])
    })()
  }, [profile?.id])

  if (!orders) return <Spinner label="Loading your orders" />

  const spent = orders
    .filter((o) => o.status !== 'cancelled')
    .reduce((s, o) => s + Number(o.total_price), 0)

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">Everything you have bought through FARMS.</p>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Stat label="Total orders" value={String(orders.length)} />
        <Stat label="Total spent" value={pesoShort(spent)} accent="green" />
      </div>

      {orders.length === 0 ? (
        <Empty
          title="No orders yet"
          body="Head to the market to buy rice, corn or watermelon straight from the farm."
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {orders.map((o) => {
            const p = o.products
            return (
              <article key={o.id} className="card flex flex-col gap-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <span className="text-2xl" aria-hidden>
                    {p?.crop ? CROP_EMOJI[p.crop] : '📦'}
                  </span>
                  <Badge
                    tone={
                      o.status === 'completed' ? 'green' : o.status === 'pending' ? 'amber' : 'red'
                    }
                  >
                    {titleCase(o.status)}
                  </Badge>
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
              </article>
            )
          })}
        </div>
      )}
    </div>
  )
}
