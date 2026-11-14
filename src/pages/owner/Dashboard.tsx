import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Empty, SectionHeading, Select, Spinner, Stat } from '@/components/ui'
import { MyFarmRank, TopFarms } from '@/components/TopFarms'
import { CROPS, CROP_EMOJI, pesoShort, relativeDate, sacks, titleCase, weightNote, sacksLabel } from '@/lib/format'
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
  const [stockFilter, setStockFilter] = useState('all')

  useEffect(() => {
    if (!farm || !profile) return
    let alive = true

    ;(async () => {
      // A query only runs once something waits on it, so this needs the .then.
      supabase.rpc('notify_ready_harvests').then(({ error }) => {
        if (error) console.warn('Growth notices skipped:', error.message)
      })

      supabase.rpc('generate_harvest_reminders').then(({ error }) => {
        if (error) console.warn('Harvest reminders skipped:', error.message)
      })

      const [txns, scheds, inv, jobs] = await Promise.all([
        supabase.from('transactions').select('amount,type').eq('farm_id', farm.id).eq('type', 'income'),
        supabase.from('schedules').select('id,status').eq('farm_id', farm.id),
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
        stock[row.crop] += Math.floor(row.quantity)
      }

      if (!alive) return
      setData({
        revenue: (txns.data ?? []).reduce((s, t) => s + Number(t.amount), 0),
        schedules: (scheds.data ?? []).filter((r: any) =>
          ['planned', 'planted', 'growing'].includes(r.status),
        ).length,
        stock,
        recent: ((inv.data ?? []) as InventoryItem[]).slice(0, 40),
        openJobs: (jobs.data ?? []).filter((j) => j.status === 'open').length,
        pendingApps,
      })
    })()

    return () => {
      alive = false
    }
  }, [farm?.id, profile?.id])

  if (!data) return <Spinner label="Loading your farm" />

  const shownStock = (
    stockFilter === 'all' ? data.recent : data.recent.filter((r) => r.crop === stockFilter)
  ).slice(0, 6)

  return (
    <div className="space-y-7">
      <div>
        <h1 className="text-[22px] font-bold">
          {greeting()}, {(profile?.name ?? '').split(' ')[0]}
        </h1>
        <p className="mt-0.5 text-[13px] text-soil-600">{farm?.name}</p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Revenue" value={pesoShort(data.revenue)} accent="green" sub="All recorded income" />
        <Stat label="Active schedules" value={String(data.schedules)} sub="Planting plans" />
        <Stat label="Rice stock" value={sacks(data.stock.rice)} sub={weightNote(data.stock.rice, 'rice')} />
        <Stat label="Corn stock" value={sacks(data.stock.corn)} sub={weightNote(data.stock.corn, 'corn')} />
      </div>

      <Weather lat={farm?.latitude ?? null} lng={farm?.longitude ?? null} />

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
                <p className="text-[12px] text-soil-400">{weightNote(data.stock[crop], crop)}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section>
        <SectionHeading
          action={
            <div className="w-40">
              <Select
                label=""
                value={stockFilter}
                onChange={(e) => setStockFilter(e.target.value)}
                options={[
                  { value: 'all', label: 'All crops' },
                  ...CROPS.map((c) => ({
                    value: c,
                    label: `${CROP_EMOJI[c]} ${titleCase(c)}`,
                  })),
                ]}
              />
            </div>
          }
        >
          Recent stock added
        </SectionHeading>
        {shownStock.length === 0 ? (
          <Empty
            title={stockFilter === 'all' ? 'No stock recorded yet' : `No ${stockFilter} recorded`}
            body="Harvest entries appear here once you record them on the Calendar."
          />
        ) : (
          <ul className="card divide-y divide-soil-200/70">
            {shownStock.map((row) => (
              <li key={row.id} className="flex items-center justify-between gap-3 px-4 py-3">
                <span className="flex min-w-0 items-center gap-3">
                  <span className="text-xl" aria-hidden>{CROP_EMOJI[row.crop]}</span>
                  <span className="min-w-0">
                    <span className="block text-sm font-semibold">{titleCase(row.crop)}</span>
                    <span className="block text-[12px] text-soil-400">{relativeDate(row.added_at)}</span>
                  </span>
                </span>
                <span className="num shrink-0 text-sm font-bold text-brand-700">
                  +{sacksLabel(row.quantity, row.crop)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <SectionHeading>Sales ranking</SectionHeading>
        <div className="space-y-3">
          <MyFarmRank days={7} />
          <TopFarms limit={5} highlightFarmId={farm?.id} showPeriodPicker={false} />
        </div>
      </section>

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
        <div className="stagger grid grid-cols-2 gap-3">
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
  const h = Number(
    new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Manila', hour: 'numeric', hour12: false }).format(
      new Date(),
    ),
  ) % 24
  if (h < 11) return 'Magandang umaga'
  if (h < 18) return 'Magandang hapon'
  return 'Magandang gabi'
}

/** Weather code (WMO) to a short description and symbol. */
function describeWeather(code: number): { text: string; icon: string } {
  if (code === 0) return { text: 'Clear sky', icon: '☀️' }
  if (code === 1 || code === 2) return { text: 'Partly cloudy', icon: '⛅' }
  if (code === 3) return { text: 'Overcast', icon: '☁️' }
  if (code === 45 || code === 48) return { text: 'Foggy', icon: '🌫️' }
  if (code >= 51 && code <= 57) return { text: 'Light drizzle', icon: '🌦️' }
  if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return { text: 'Rain', icon: '🌧️' }
  if (code >= 95) return { text: 'Thunderstorm', icon: '⛈️' }
  return { text: 'Cloudy', icon: '☁️' }
}

/**
 * Today's weather at the farm, from Open-Meteo (free, no key). The card is simply left out
 * when the weather cannot be fetched, so it never shows made-up figures.
 */
function Weather({ lat, lng }: { lat: number | null; lng: number | null }) {
  const [w, setW] = useState<{ temp: number; code: number; rain: number | null } | null>(null)
  const la = lat ?? 9.3764 // Pagatban, Dumaguete, when the farm has no pin
  const lo = lng ?? 122.741

  useEffect(() => {
    const ctrl = new AbortController()
    fetch(
      `https://api.open-meteo.com/v1/forecast?latitude=${la}&longitude=${lo}` +
        `&current=temperature_2m,weather_code&daily=precipitation_probability_max` +
        `&timezone=Asia%2FManila&forecast_days=1`,
      { signal: ctrl.signal },
    )
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error('weather unavailable'))))
      .then((j) =>
        setW({
          temp: Math.round(j.current.temperature_2m),
          code: Number(j.current.weather_code),
          rain: j.daily?.precipitation_probability_max?.[0] ?? null,
        }),
      )
      .catch(() => {})
    return () => ctrl.abort()
  }, [la, lo])

  if (!w) return null
  const d = describeWeather(w.code)
  return (
    <div className="card flex items-center justify-between gap-4 px-5 py-4">
      <div>
        <p className="text-[11px] font-bold uppercase tracking-[0.08em] text-soil-400">Today at the farm</p>
        <p className="num mt-0.5 text-2xl font-bold">{w.temp}°C</p>
        <p className="text-sm text-soil-600">
          {d.text}
          {w.rain != null ? ` · ${w.rain}% chance of rain` : ''}
        </p>
      </div>
      <span className="text-4xl" aria-hidden>
        {d.icon}
      </span>
    </div>
  )
}
