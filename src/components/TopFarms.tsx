import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Empty, Spinner } from '@/components/ui'
import { peso, sacks } from '@/lib/format'

export interface TopFarm {
  rank: number
  farm_id: string
  farm_name: string
  owner_name: string
  city: string | null
  order_count: number
  sacks_sold: number
  total_sales: number
}

export const PERIODS = [
  { days: 7, label: 'This week' },
  { days: 30, label: 'This month' },
  { days: 0, label: 'All time' },
] as const

const MEDAL = ['🥇', '🥈', '🥉']

export function TopFarms({
  limit = 10,
  highlightFarmId,
  showPeriodPicker = true,
  defaultDays = 7,
}: {
  limit?: number
  highlightFarmId?: string | null
  showPeriodPicker?: boolean
  defaultDays?: number
}) {
  const [days, setDays] = useState<number>(defaultDays)
  const [rows, setRows] = useState<TopFarm[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    setRows(null)

    ;(async () => {
      const { data, error: rpcError } = await supabase.rpc('top_selling_farms', {
        p_days: days,
        p_limit: limit,
      })
      if (!alive) return
      if (rpcError) {
        setError(rpcError.message)
        setRows([])
        return
      }
      setError(null)
      setRows((data as TopFarm[]) ?? [])
    })()

    return () => {
      alive = false
    }
  }, [days, limit])

  return (
    <div className="space-y-3">
      {showPeriodPicker && (
        <div className="flex flex-wrap gap-2">
          {PERIODS.map((p) => (
            <button
              key={p.days}
              onClick={() => setDays(p.days)}
              aria-pressed={days === p.days}
              className={`chip border transition ${
                days === p.days
                  ? 'border-brand-600 bg-brand-600 text-white'
                  : 'border-soil-200 bg-white text-soil-600 hover:bg-soil-100'
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
          {error}
        </div>
      )}

      {rows === null ? (
        <Spinner label="Working out the rankings" />
      ) : rows.length === 0 ? (
        <Empty
          title="No sales yet"
          body={
            days === 0
              ? 'Once buyers start ordering, the best-selling farms appear here.'
              : 'No orders in this period. Try a longer one.'
          }
        />
      ) : (
        <ul className="card divide-y divide-soil-200">
          {rows.map((r) => {
            const mine = highlightFarmId && r.farm_id === highlightFarmId
            const top = r.rank <= 3

            return (
              <li
                key={r.farm_id}
                className={`flex items-center gap-3 px-4 py-3 ${mine ? 'bg-brand-50' : ''}`}
              >
                <span
                  className={`num flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-[13px] font-bold ${
                    top ? 'bg-transparent text-lg' : 'bg-soil-100 text-soil-600'
                  }`}
                  aria-label={`Rank ${r.rank}`}
                >
                  {top ? MEDAL[r.rank - 1] : r.rank}
                </span>

                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] font-bold">
                    {r.farm_name}
                    {mine && (
                      <span className="ml-1.5 align-middle text-[10px] font-bold uppercase tracking-wide text-brand-700">
                        You
                      </span>
                    )}
                  </span>
                  <span className="block truncate text-[12px] text-soil-400">
                    {r.owner_name}
                    {r.city ? ` · ${r.city}` : ''}
                  </span>
                </span>

                <span className="shrink-0 text-right">
                  <span className="num block text-[14px] font-bold text-brand-700">
                    {peso(r.total_sales)}
                  </span>
                  <span className="num block text-[11px] text-soil-400">
                    {sacks(r.sacks_sold)} sacks · {r.order_count}{' '}
                    {Number(r.order_count) === 1 ? 'order' : 'orders'}
                  </span>
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

export function MyFarmRank({ days = 7 }: { days?: number }) {
  const [data, setData] = useState<{
    rank: number | null
    orders: number
    sacks: number
    sales: number
    farms: number
  } | null>(null)

  useEffect(() => {
    ;(async () => {
      const { data: res } = await supabase.rpc('my_farm_sales', { p_days: days })
      setData((res as any) ?? null)
    })()
  }, [days])

  if (!data) return null

  return (
    <div className="card flex items-center justify-between gap-4 px-5 py-4">
      <div className="min-w-0">
        <p className="text-[11px] font-bold uppercase tracking-[0.08em] text-soil-400">
          Your sales this week
        </p>
        <p className="num mt-0.5 text-[22px] font-bold text-brand-700">{peso(data.sales)}</p>
        <p className="text-[12px] text-soil-400">
          {sacks(data.sacks)} sacks across {data.orders} {data.orders === 1 ? 'order' : 'orders'}
        </p>
      </div>

      <div className="shrink-0 text-right">
        {data.rank ? (
          <>
            <p className="num text-[28px] font-bold leading-none">
              {data.rank <= 3 ? MEDAL[data.rank - 1] : `#${data.rank}`}
            </p>
            <p className="mt-1 text-[12px] text-soil-400">
              of {data.farms} {data.farms === 1 ? 'farm' : 'farms'}
            </p>
          </>
        ) : (
          <p className="max-w-[9rem] text-[12px] leading-snug text-soil-400">
            No sales yet this week
          </p>
        )}
      </div>
    </div>
  )
}
