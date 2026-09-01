import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Empty, Spinner } from '@/components/ui'
import { CROP_COLOR, CROP_EMOJI, peso, sacks, shortDate, titleCase } from '@/lib/format'
import type { Crop } from '@/lib/types'

interface Row {
  id: string
  variety: string
  crop: Crop
  photo_url: string | null
  quantity: number
  total_price: number
  price: number
  stage: string
  paid: boolean
  created_at: string
}

export function BuyerPurchases({ buyerId }: { buyerId: string }) {
  const [rows, setRows] = useState<Row[] | null>(null)

  useEffect(() => {
    setRows(null)
    supabase
      .rpc('buyer_orders_for_my_farm', { p_buyer_id: buyerId })
      .then(({ data }) => setRows((data as Row[]) ?? []))
  }, [buyerId])

  if (!rows) return <Spinner label="Loading their purchases" />
  if (rows.length === 0) {
    return <Empty title="No purchases yet" body="This buyer has not completed an order with you." />
  }

  const completed = rows.filter((r) => r.stage === 'completed')
  const totalSacks = completed.reduce((s, r) => s + r.quantity, 0)
  const totalSpent = completed.reduce((s, r) => s + Number(r.total_price), 0)

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-3 gap-2 rounded-xl bg-brand-50 px-4 py-3 text-center">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
            Orders
          </p>
          <p className="num text-[18px] font-bold text-brand-900">{completed.length}</p>
        </div>
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
            Sacks
          </p>
          <p className="num text-[18px] font-bold text-brand-900">{sacks(totalSacks)}</p>
        </div>
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
            Spent
          </p>
          <p className="num text-[18px] font-bold text-brand-900">{peso(totalSpent)}</p>
        </div>
      </div>

      <ul className="space-y-2">
        {rows.map((r) => (
          <li
            key={r.id}
            className="flex items-center gap-3 rounded-xl border border-soil-200 p-2.5"
          >
            {r.photo_url ? (
              <img
                src={r.photo_url}
                alt={r.variety}
                className="h-14 w-14 shrink-0 rounded-lg object-cover"
              />
            ) : (
              <span
                className={`flex h-14 w-14 shrink-0 items-center justify-center rounded-lg text-2xl ${
                  CROP_COLOR[r.crop].soft
                }`}
              >
                {CROP_EMOJI[r.crop]}
              </span>
            )}

            <span className="min-w-0 flex-1">
              <span className="block truncate text-[14px] font-bold">{r.variety}</span>
              <span className="block text-[12px] text-soil-500">
                {titleCase(r.crop)} · {shortDate(r.created_at)}
              </span>
              <span className="num block text-[12px] text-soil-600">
                {sacks(r.quantity)} sacks × {peso(r.price)}
              </span>
            </span>

            <span className="shrink-0 text-right">
              <span className="num block text-[14px] font-bold text-brand-700">
                {peso(r.total_price)}
              </span>
              <span
                className={`chip mt-1 ${
                  r.stage === 'completed'
                    ? 'bg-green-100 text-green-800'
                    : r.stage === 'cancelled'
                      ? 'bg-red-100 text-red-700'
                      : 'bg-amber-100 text-amber-800'
                }`}
              >
                {titleCase(r.stage)}
              </span>
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}
