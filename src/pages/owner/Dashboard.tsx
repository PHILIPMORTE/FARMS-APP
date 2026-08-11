import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Empty, SectionHeading, Spinner, Stat } from '@/components/ui'
import { CROPS, CROP_EMOJI, peso, pesoShort, relativeDate, sacks, titleCase, weightNote } from '@/lib/format'
import type { Crop, InventoryItem } from '@/lib/types'

interface Snapshot {
  revenue: number
  schedules: number
  stock: Record<Crop, number>
  recent: InventoryItem[]
  openJobs: number
  pendingApps: number
}

export default function OwnerDashboard() {
  const { profile, farm } = useAuth()
  const [data, setData] = useState<Snapshot | null>(null)

  useEffect(() => {
    if (!farm || !profile) return
    let alive = true

    ;(async () => {
      // Writes any harvest reminders that are now due. Safe to call repeatedly —
      // it will not create the same reminder twice.
      supabase.rpc('generate_harvest_reminders').then(({ error }) => {
        if (error) console.warn('Harvest reminders skipped:', error.message)
      })

      const [txns, scheds, inv, jobs] = await Promise.all([
        supabase.from('transactions').select('amount,type').eq('farm_id', farm.id).eq('type', 'income'),
        supabase.from('schedules').select('id').eq('farm_id', farm.id),
        supabase.from('inventory').select('*').eq('farm_id', farm.id).order('added_at', { ascending: false }),
        supabase.from('job_posts').select('id,status').eq('owner_id', profile.id),
      ])

      const jobIds = (jobs.data ?? []).map((j) => j.id)
      let pendingApps = 0
      if (jobIds.length) {
        const { count } = await supabase
          .from('job_applications')
          .select('id', { count: 'exact', head: true })
          .in('job_id', jobIds)
          .eq('status', 'pending')
        pendingApps = count ?? 0
      }

      const stock: Record<Crop, number> = { rice: 0, corn: 0, watermelon: 0 }
      for (const row of (inv.data ?? []) as InventoryItem[]) {
        // Integer arithmetic only — a stock total is a count of sacks.
        stock[row.crop] += Math.floor(row.quantity)
      }

      if (!alive) return
      setData({
        revenue: (txns.data ?? []).reduce((s, t) => s + Number(t.amount), 0),
        schedules: scheds.data?.length ?? 0,
        stock,
        recent: ((inv.data ?? []) as InventoryItem[]).slice(0, 6),
        openJobs: (jobs.data ?? []).filter((j) => j.status === 'open').length,
        pendingApps,
      })
    })()

    return () => {
      alive = false
    }
  }, [farm?.id, profile?.id])

  if (!data) return <Spinner label="Loading your farm" />

  return (
    <div className="space-y-7">
      <div>
        <h1 className="text-[22px] font-bold">
          {greeting()}, {profile?.name.split(' ')[0]}
        </h1>
        <p className="mt-0.5 text-[13px] text-soil-600">{farm?.name}</p>
      </div>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Revenue" value={pesoShort(data.revenue)} accent="green" sub="All recorded income" />
        <Stat label="Active schedules" value={String(data.schedules)} sub="Planting plans" />
        <Stat label="Rice stock" value={sacks(data.stock.rice)} sub={weightNote(data.stock.rice)} />
        <Stat label="Corn stock" value={sacks(data.stock.corn)} sub={weightNote(data.stock.corn)} />
      </div>

      {/* Weather */}
      <div className="card flex items-center justify-between gap-4 px-5 py-4">
        <div>
          <p className="text-[11px] font-bold uppercase tracking-[0.08em] text-soil-400">Today</p>
          <p className="num mt-0.5 text-2xl font-bold">28°C</p>
          <p className="text-sm text-soil-600">Sunny — good drying weather</p>
        </div>
        <span className="text-4xl" aria-hidden>☀️</span>
      </div>

      {/* Inventory */}
      <section>
        <SectionHeading
          action={
            <Link to="/owner/market" className="text-sm font-semibold text-brand-700 hover:underline">
              Sell stock
            </Link>
          }
        >
          Inventory
        </SectionHeading>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {CROPS.map((crop) => (
            <div key={crop} className="card flex items-center gap-4 px-4 py-4">
              <span className="text-3xl" aria-hidden>{CROP_EMOJI[crop]}</span>
              <div className="min-w-0">
                <p className="text-sm font-bold">{titleCase(crop)}</p>
                <p className="num text-xl font-bold leading-tight">{sacks(data.stock[crop])}</p>
                <p className="text-[12px] text-soil-400">{weightNote(data.stock[crop])}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Recent additions */}
      <section>
        <SectionHeading>Recent stock added</SectionHeading>
        {data.recent.length === 0 ? (
          <Empty
            title="No stock recorded yet"
            body="Harvest entries appear here once you add them to inventory."
          />
        ) : (
          <ul className="card divide-y divide-soil-200/70">
            {data.recent.map((row) => (
              <li key={row.id} className="flex items-center justify-between gap-3 px-4 py-3">
                <span className="flex min-w-0 items-center gap-3">
                  <span className="text-xl" aria-hidden>{CROP_EMOJI[row.crop]}</span>
                  <span className="min-w-0">
                    <span className="block text-sm font-semibold">{titleCase(row.crop)}</span>
                    <span className="block text-[12px] text-soil-400">{relativeDate(row.added_at)}</span>
                  </span>
                </span>
                <span className="num shrink-0 text-sm font-bold text-brand-700">
                  +{sacks(row.quantity)} sacks
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* Hiring peek */}
      <section>
        <SectionHeading
          action={
            <Link to="/owner/jobs" className="text-sm font-semibold text-brand-700 hover:underline">
              Manage jobs
            </Link>
          }
        >
          Hiring
        </SectionHeading>
        <div className="grid grid-cols-2 gap-3">
          <Stat label="Open job posts" value={String(data.openJobs)} />
          <Stat
            label="Pending applications"
            value={String(data.pendingApps)}
            sub={data.pendingApps > 0 ? 'Waiting on your decision' : 'Nothing to review'}
          />
        </div>
      </section>
    </div>
  )
}

function greeting() {
  const h = new Date().getHours()
  if (h < 11) return 'Magandang umaga'
  if (h < 18) return 'Magandang hapon'
  return 'Magandang gabi'
}
