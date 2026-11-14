import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { PurokSelect, usePuroks } from '@/components/PurokSelect'
import { useAuth } from '@/context/AuthContext'
import { Dialog, Field, PesoInput, SackInput, Select, Spinner, TextArea, ViewToggle } from '@/components/ui'
import {
  CROPS,
  CROP_COLOR,
  CROP_EMOJI,
  SCHEDULE_LABEL,
  SEASON,
  VARIETIES,
  addDays,
  daysBetween,
  KG_PER_SACK,
  peso,
  sacks,
  plantNoun,
  pieceNoun,
  unitWord,
  sacksLabel,
  seedLabel,
  shortDate,
  toSacks,
  suggestedCrops,
  titleCase,
  todayISO,
} from '@/lib/format'
import { friendlyError, validateRequired } from '@/lib/validation'
import type { Crop, Schedule } from '@/lib/types'
import { STAGE_STYLE, growthStage, type GrowthStage } from '@/lib/growth'

// Demonstration setting. While true, the Harvest now button is clickable at every
// growth stage, so the panel can see what happens when a crop is harvested early:
// the system warns how much of the growing period has passed, and records the
// quantity actually harvested. Set it to false to allow harvesting only once a
// planting has reached 100%.
const ALLOW_EARLY_HARVEST_FOR_TESTING = true

const EXPENSE_CATEGORIES = [
  'Seeds',
  'Fertilizer',
  'Pesticides',
  'Labor',
  'Equipment',
  'Fuel',
  'Water',
  'Other',
]

/** Today in the Philippines, as a date the month grids can start from (noon, so no clock shift can move the day). */
const manilaToday = () => new Date(`${todayISO()}T12:00:00`)

export default function OwnerCalendar() {
  const { farm } = useAuth()
  const [cursor, setCursor] = useState(manilaToday)
  const [rows, setRows] = useState<Schedule[] | null>(null)
  const [view, setView] = useState<'calendar' | 'table'>('calendar')
  const [cropFilter, setCropFilter] = useState('all')
  const [varietyFilter, setVarietyFilter] = useState('all')
  const [adding, setAdding] = useState<string | null>(null)
  const [detail, setDetail] = useState<Schedule | null>(null)
  const [harvesting, setHarvesting] = useState<Schedule | null>(null)
  const [todayKey, setTodayKey] = useState(todayISO())

  useEffect(() => {
    const t = setInterval(() => {
      const now = todayISO()
      setTodayKey((prev) => (prev === now ? prev : now))
    }, 60000)
    return () => clearInterval(t)
  }, [])

  const load = useCallback(async () => {
    if (!farm) return
    const { data } = await supabase
      .from('schedules')
      .select('*')
      .eq('farm_id', farm.id)
      .order('planting_date', { ascending: false })
    setRows((data as Schedule[]) ?? [])
  }, [farm?.id])

  useEffect(() => {
    load()
  }, [load])

  // A planting that has turned yellow or green since the owner was last here gets
  // its notice now. Each notice is sent once per planting.
  useEffect(() => {
    supabase.rpc('notify_ready_harvests').then(({ error }) => {
      if (error) console.warn('Growth notices skipped:', error.message)
    })
  }, [])

  const varieties = useMemo(
    () => [...new Set((rows ?? []).map((r) => r.variety).filter(Boolean))].sort(),
    [rows],
  )

  const filtered = useMemo(
    () =>
      (rows ?? []).filter((r) => {
        if (r.status === 'cancelled') return false
        if (cropFilter !== 'all' && r.crop !== cropFilter) return false
        if (varietyFilter !== 'all' && r.variety !== varietyFilter) return false
        return true
      }),
    [rows, cropFilter, varietyFilter],
  )

  if (!rows) return <Spinner label="Loading your calendar" />

  const monthKey = `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, '0')}`
  const suggestions = suggestedCrops(cursor.getMonth())
  const plantedThisMonth = filtered.filter((r) => (r.planting_date ?? '').startsWith(monthKey))
  const todayIso = todayKey
  const dueSoon = filtered.filter(
    (r) =>
      r.status !== 'harvested' &&
      r.harvest_date &&
      r.harvest_date >= todayIso &&
      daysBetween(todayIso, r.harvest_date) <= 14,
  )

  return (
    <div className="animate-fade-up space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[26px] font-bold">Planting calendar</h1>
          <p className="mt-1 text-[14px] text-soil-600">
            Plan each planting, follow it to harvest, then send it straight to the market.
          </p>
        </div>
        <button
          className="btn-primary px-5 py-3 text-[15px]"
          onClick={() => setAdding(todayISO())}
        >
          Add planting
        </button>
      </div>

      {dueSoon.length > 0 && (
        <div className="rounded-xl border border-amber-300 bg-amber-50 px-5 py-4">
          <p className="text-[15px] font-bold text-amber-900">Harvest coming up</p>
          <ul className="mt-2 space-y-1">
            {dueSoon.map((r) => (
              <li key={r.id} className="text-[14px] text-amber-800">
                <span className="font-semibold">
                  {CROP_EMOJI[r.crop]} {r.variety || titleCase(r.crop)}
                </span>{' '}
                is due {shortDate(r.harvest_date)} — about{' '}
                <span className="num font-semibold">{sacksLabel(r.expected_sacks, r.crop)}</span>.
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex flex-wrap items-end gap-3">
        <Select
          label="Crop"
          className="w-44"
          value={cropFilter}
          onChange={(e) => setCropFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All crops' },
            ...CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` })),
          ]}
        />
        <Select
          label="Variety"
          className="w-52"
          value={varietyFilter}
          onChange={(e) => setVarietyFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All varieties' },
            ...varieties.map((v) => ({ value: v, label: v })),
          ]}
        />
        <div className="ml-auto">
          <ViewToggle
            view={view === 'calendar' ? 'grid' : 'table'}
            onChange={(v) => setView(v === 'grid' ? 'calendar' : 'table')}
          />
        </div>
      </div>

      {view === 'calendar' ? (
        <CalendarView
          cursor={cursor}
          setCursor={setCursor}
          rows={filtered}
          suggestions={suggestions}
          plantedThisMonth={plantedThisMonth}
          onOpen={setDetail}
          onPlant={setAdding}
          today={todayKey}
        />
      ) : (
        <TableView rows={filtered} onOpen={setDetail} onHarvest={setHarvesting} />
      )}

      <AddPlantingDialog
        date={adding}
        onClose={() => setAdding(null)}
        farmId={farm?.id ?? ''}
        defaultPurokId={farm?.purok_id ?? ''}
        existing={rows}
        onSaved={() => {
          setAdding(null)
          load()
        }}
      />

      <DetailDialog
        schedule={harvesting}
        startInHarvest
        onClose={() => setHarvesting(null)}
        onChanged={() => {
          setHarvesting(null)
          load()
        }}
      />

      <DetailDialog
        schedule={detail}
        onClose={() => setDetail(null)}
        onChanged={() => {
          setDetail(null)
          load()
        }}
      />
    </div>
  )
}

function CalendarView({
  cursor,
  setCursor,
  rows,
  suggestions,
  plantedThisMonth,
  onOpen,
  onPlant,
  today,
}: {
  cursor: Date
  setCursor: (d: Date) => void
  rows: Schedule[]
  suggestions: Crop[]
  plantedThisMonth: Schedule[]
  onOpen: (s: Schedule) => void
  onPlant: (iso: string) => void
  today: string
}) {
  const year = cursor.getFullYear()
  const month = cursor.getMonth()
  const firstDay = new Date(year, month, 1).getDay()
  const days = new Date(year, month + 1, 0).getDate()
  const cells: (number | null)[] = [
    ...Array(firstDay).fill(null),
    ...Array.from({ length: days }, (_, i) => i + 1),
  ]

  return (
    <div className="space-y-4">
      <div className="grid gap-3 lg:grid-cols-2">
        <div className="card p-5">
          <h3 className="text-[15px] font-bold">
            Good to plant in {cursor.toLocaleDateString('en-PH', { month: 'long' })}
          </h3>
          {suggestions.length === 0 ? (
            <p className="mt-2 text-[14px] leading-relaxed text-soil-600">
              None of the three crops is in its usual planting window this month.
            </p>
          ) : (
            <ul className="mt-3 space-y-2">
              {suggestions.map((c) => (
                <li
                  key={c}
                  className={`flex items-center gap-3 rounded-lg px-3 py-2.5 ${CROP_COLOR[c].soft}`}
                >
                  <span className="text-2xl">{CROP_EMOJI[c]}</span>
                  <span>
                    <span className={`block text-[14px] font-bold ${CROP_COLOR[c].text}`}>
                      {titleCase(c)}
                    </span>
                    <span className="block text-[12px] text-soil-600">In season this month</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="card p-5">
          <h3 className="text-[15px] font-bold">This month's plantings</h3>
          {plantedThisMonth.length === 0 ? (
            <p className="mt-2 text-[14px] text-soil-600">Nothing planted this month yet.</p>
          ) : (
            <>
              <p className="mt-1 text-[13px] text-soil-600">
                You already have {plantedThisMonth.length} planting
                {plantedThisMonth.length === 1 ? '' : 's'} recorded this month.
              </p>
              <ul className="mt-3 space-y-2">
                {plantedThisMonth.map((r) => (
                  <li key={r.id}>
                    <button
                      onClick={() => onOpen(r)}
                      className="flex w-full items-center justify-between gap-3 rounded-lg border border-soil-200 px-3 py-2.5 text-left transition hover:bg-soil-50"
                    >
                      <span className="min-w-0">
                        <span className="block truncate text-[14px] font-semibold">
                          {CROP_EMOJI[r.crop]} {r.variety || titleCase(r.crop)}
                        </span>
                        <span className="block text-[12px] text-soil-400">
                          Harvest {shortDate(r.harvest_date)}
                        </span>
                      </span>
                      <span className="num shrink-0 text-[13px] font-bold">
                        {sacksLabel(r.expected_sacks, r.crop)}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
      </div>

      <div className="card p-4 sm:p-6">
        <div className="mb-5 flex items-center justify-between">
          <button
            className="rounded-lg p-2.5 text-soil-600 transition hover:bg-soil-100"
            aria-label="Previous month"
            onClick={() => setCursor(new Date(year, month - 1, 1))}
          >
            <Chevron dir="left" />
          </button>
          <h2 className="text-[20px] font-bold">
            {cursor.toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
          </h2>
          <button
            className="rounded-lg p-2.5 text-soil-600 transition hover:bg-soil-100"
            aria-label="Next month"
            onClick={() => setCursor(new Date(year, month + 1, 1))}
          >
            <Chevron dir="right" />
          </button>
        </div>

        <div className="mb-4 flex flex-wrap items-center gap-x-5 gap-y-2 border-b border-soil-200 pb-4 text-[13px]">
          <span className="flex items-center gap-3">
            <span className="flex h-2.5 w-16 overflow-hidden rounded-full bg-soil-100">
              {CROPS.map((c) => (
                <span key={c} className={`h-full flex-1 ${CROP_COLOR[c].bar}`} />
              ))}
            </span>
            <span className="text-soil-500">Best to plant this month</span>
          </span>

          {CROPS.map((c) => (
            <span key={c} className="flex items-center gap-2">
              <span className={`h-3 w-3 rounded-sm ${CROP_COLOR[c].dot}`} />
              <span className="font-semibold">{titleCase(c)}</span>
            </span>
          ))}
          <span className="ml-auto flex items-center gap-3 text-soil-400">
            <span>🌱 Planting date</span>
            <span>🌾 Expected harvest</span>
          </span>
        </div>

        <GrowthLegend />

        <div className="grid grid-cols-7 gap-1.5 text-center sm:gap-2">
          {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map((d) => (
            <div
              key={d}
              className="pb-2 text-[11px] font-semibold uppercase tracking-[0.08em] text-soil-400"
            >
              <span className="hidden sm:inline">{d}</span>
              <span className="sm:hidden">{d[0]}</span>
            </div>
          ))}

          {cells.map((day, i) => {
            if (!day) return <div key={i} className="min-h-[6rem] sm:min-h-[7.5rem]" />
            const iso = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`
            const plantedHere = rows.filter((r) => r.planting_date === iso)
            const harvestsHere = rows.filter(
              (r) => r.harvest_date === iso && r.planting_date !== iso,
            )
            const isToday = iso === today
            const isPast = iso < today

            return (
              <div
                key={i}
                className={`group relative flex min-h-[6.5rem] flex-col rounded-lg border p-2 text-left transition sm:min-h-[8rem] ${
                  isToday
                    ? 'border-brand-600 bg-white ring-1 ring-brand-600'
                    : isPast
                      ? 'border-soil-200/70 bg-soil-50/40'
                      : 'border-soil-200 bg-white hover:border-soil-300'
                }`}
              >
                <span
                  className={`num text-[13px] font-bold sm:text-[15px] ${
                    isToday ? 'text-brand-700' : isPast ? 'text-soil-400' : 'text-soil-800'
                  }`}
                >
                  {day}
                </span>

                <SeasonBar suggestions={suggestions} />

                {plantedHere.length > 0 && (
                  <span className="mt-1 flex flex-col gap-1">
                    {plantedHere.map((r) => {
                      const total =
                        r.planting_date && r.harvest_date
                          ? Math.max(1, daysBetween(r.planting_date, r.harvest_date))
                          : 1
                      const done =
                        r.status === 'harvested'
                          ? total
                          : Math.min(Math.max(daysBetween(r.planting_date!, today), 0), total)
                      const pct = Math.round((done / total) * 100)
                      const stage = r.status === 'harvested' ? null : STAGE_STYLE[growthStage(pct)]

                      return (
                        <button
                          key={r.id}
                          onClick={() => onOpen(r)}
                          title={`${r.variety || titleCase(r.crop)} — ${pct}% grown${
                            stage ? ` — ${stage.label}` : ''
                          }`}
                          className="relative block overflow-hidden rounded bg-soil-100 text-left"
                        >
                          <span
                            aria-hidden
                            className={`absolute inset-y-0 left-0 ${stage ? stage.bar : CROP_COLOR[r.crop].bar}`}
                            style={{ width: `${Math.max(pct, 12)}%` }}
                          />
                          <span
                            className="relative flex items-center gap-1 px-1.5 py-1 text-[10px] font-semibold text-soil-800"
                          >
                            <span className="truncate rounded bg-white/85 px-1">
                              {r.variety || titleCase(r.crop)}
                              {r.field_name ? ` · ${r.field_name}` : ''}
                            </span>
                            <span className="num ml-auto shrink-0 rounded bg-white/85 px-1">{pct}%</span>
                          </span>
                        </button>
                      )
                    })}
                  </span>
                )}

                {harvestsHere.length > 0 && (
                  <span className="mt-1 flex flex-col gap-1">
                    {harvestsHere.map((r) => (
                      <button
                        key={r.id + 'h'}
                        onClick={() => onOpen(r)}
                        title={`Expected harvest: ${r.variety || titleCase(r.crop)} — ${sacksLabel(
                          r.expected_sacks,
                          r.crop,
                        )}`}
                        className={`block truncate rounded px-1.5 py-1 text-left text-[10px] font-semibold ${
                          CROP_COLOR[r.crop].chip
                        }`}
                      >
                        🌾 {r.variety || titleCase(r.crop)}
                      </button>
                    ))}
                  </span>
                )}

                {!isPast && (
                  <button
                    onClick={() => onPlant(iso)}
                    aria-label={`Plan a planting on ${iso}`}
                    className="mt-auto w-full rounded-md border border-dashed border-soil-300 py-1
                               text-[10px] font-medium text-soil-400 opacity-0 transition
                               hover:border-brand-600 hover:bg-brand-50 hover:text-brand-700
                               focus-visible:opacity-100 group-hover:opacity-100 sm:text-[11px]"
                  >
                    {isToday ? '+ Plant' : '+ Schedule'}
                  </button>
                )}
              </div>
            )
          })}
        </div>

      </div>

    </div>
  )
}

function GrowthLegend() {
  const order: GrowthStage[] = ['early', 'almost', 'ready']
  return (
    <div className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-[12px] text-soil-600">
      <span className="font-semibold text-soil-800">Growth bar</span>
      {order.map((k) => (
        <span key={k} className="flex items-center gap-1.5">
          <span aria-hidden className={`h-2.5 w-5 rounded-full ${STAGE_STYLE[k].bar}`} />
          {STAGE_STYLE[k].legend}
        </span>
      ))}
    </div>
  )
}

function SeasonBar({ suggestions }: { suggestions: Crop[] }) {
  const inSeason = CROPS.filter((c) => suggestions.includes(c))

  return (
    <span
      className="mt-1.5 flex h-2 overflow-hidden rounded-full bg-soil-100"
      title={
        inSeason.length === 0
          ? 'No crop is in its usual planting season this month'
          : `Good to plant: ${inSeason.map(titleCase).join(', ')}`
      }
    >
      {CROPS.map((c) => (
        <span
          key={c}
          className={`h-full ${inSeason.includes(c) ? CROP_COLOR[c].bar : ''}`}
          style={{ width: `${100 / CROPS.length}%` }}
        />
      ))}
    </span>
  )
}

function TableView({
  rows,
  onOpen,
  onHarvest,
}: {
  rows: Schedule[]
  onOpen: (s: Schedule) => void
  onHarvest: (s: Schedule) => void
}) {
  const [anchor, setAnchor] = useState(manilaToday)

  const year = anchor.getFullYear()
  const month = anchor.getMonth()
  const total = new Date(year, month + 1, 0).getDate()
  const days = Array.from({ length: total }, (_, i) => new Date(year, month, i + 1))

  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

  const todayIso = todayISO()

  function eventsOn(d: Date) {
    const key = iso(d)
    return rows
      .filter((r) => r.planting_date === key || r.harvest_date === key)
      .map((r) => ({
        row: r,
        kind: r.planting_date === key ? ('plant' as const) : ('harvest' as const),
      }))
  }

  return (
    <div className="card overflow-hidden">
      <div className="flex items-center gap-2 border-b border-soil-200 px-4 py-3">
        <button
          className="btn-sm border border-soil-200 hover:bg-soil-100"
          onClick={() => setAnchor(manilaToday())}
        >
          Today
        </button>
        <button
          className="rounded-lg p-1.5 text-soil-600 hover:bg-soil-100"
          aria-label="Previous month"
          onClick={() => setAnchor(new Date(year, month - 1, 1))}
        >
          <Chevron dir="left" />
        </button>
        <button
          className="rounded-lg p-1.5 text-soil-600 hover:bg-soil-100"
          aria-label="Next month"
          onClick={() => setAnchor(new Date(year, month + 1, 1))}
        >
          <Chevron dir="right" />
        </button>
        <h2 className="ml-1 text-[18px] font-bold">
          {anchor.toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
        </h2>
      </div>

      <div className="border-b border-soil-200 px-4 pt-3">
        <GrowthLegend />
      </div>

      <div className="max-h-[36rem] overflow-y-auto">
        {days.map((d) => {
          const key = iso(d)
          const events = eventsOn(d)
          const isToday = key === todayIso
          const isPast = key < todayIso
          const weekend = d.getDay() === 0 || d.getDay() === 6

          return (
            <div
              key={key}
              className={`grid grid-cols-[5rem_1fr] border-b border-soil-200/70 last:border-b-0 ${
                isToday ? 'bg-brand-50' : weekend ? 'bg-soil-50/50' : ''
              }`}
            >
              <div className="flex items-start justify-end gap-2 px-3 py-2.5 text-right">
                <span
                  className={`text-[11px] font-semibold uppercase ${
                    isToday ? 'text-brand-700' : 'text-soil-400'
                  }`}
                >
                  {d.toLocaleDateString('en-PH', { weekday: 'short' })}
                </span>
                <span
                  className={`num flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-[15px] font-semibold ${
                    isToday
                      ? 'bg-brand-600 text-white'
                      : isPast
                        ? 'text-soil-400'
                        : 'text-soil-800'
                  }`}
                >
                  {d.getDate()}
                </span>
              </div>

              <div className="min-h-[3rem] space-y-1 border-l border-soil-200 px-2 py-2">
                {events.length === 0 ? (
                  <span className="block h-full" />
                ) : (
                  events.map(({ row, kind }) => {
                    const c = CROP_COLOR[row.crop]
                    const total =
                      row.planting_date && row.harvest_date
                        ? Math.max(1, daysBetween(row.planting_date, row.harvest_date))
                        : 0
                    const elapsed =
                      row.planting_date && total
                        ? Math.min(Math.max(daysBetween(row.planting_date, todayIso), 0), total)
                        : 0
                    const done = row.status === 'harvested'
                    const pct = done ? 100 : total ? Math.round((elapsed / total) * 100) : 0
                    const left = Math.max(total - elapsed, 0)
                    const stage = done ? null : STAGE_STYLE[growthStage(pct)]

                    return (
                      <button
                        key={row.id + kind}
                        onClick={() => onOpen(row)}
                        title={[
                          `${row.variety || titleCase(row.crop)} (${titleCase(row.crop)})`,
                          `Planted: ${shortDate(row.planting_date)}`,
                          `Expected harvest: ${shortDate(row.harvest_date)}`,
                          `Expected ${unitWord(row.crop, 2)}: ${sacks(row.expected_sacks)}`,
                          done
                            ? 'Harvested'
                            : `${pct}% grown - day ${elapsed} of ${total}, ${left} days left - ${stage?.label}`,
                        ].join('\n')}
                        className="relative block w-full overflow-hidden rounded border border-soil-200 bg-soil-100 text-left transition hover:shadow-sm"
                      >
                        <span
                          aria-hidden
                          className={`absolute inset-y-0 left-0 transition-all duration-500 ${stage ? stage.bar : c.bar}`}
                          style={{ width: `${Math.max(pct, 5)}%` }}
                        />

                        <span className="relative flex items-center gap-2 px-2.5 py-1.5">
                          <span className="text-[13px]">{kind === 'plant' ? '🌱' : '🌾'}</span>
                          <span
                            className="truncate rounded bg-white/85 px-1.5 py-0.5 text-[13px] font-semibold text-soil-800"
                          >
                            {kind === 'plant' ? 'Planted' : 'Expected harvest'} ·{' '}
                            {row.variety || titleCase(row.crop)}
                          </span>

                          <span
                            className="num ml-auto shrink-0 rounded bg-white/85 px-1.5 py-0.5 text-[12px] font-semibold text-soil-700"
                          >
                            {done ? (
                              `Harvested · ${sacksLabel(row.actual_sacks ?? 0, row.crop)}`
                            ) : (
                              <>
                                {pct}%
                                <span className="hidden sm:inline"> · {stage?.label}</span>
                              </>
                            )}
                          </span>

                          {!done && (pct >= 100 || ALLOW_EARLY_HARVEST_FOR_TESTING) && (
                            <span
                              onClick={(ev) => {
                                ev.stopPropagation()
                                onHarvest(row)
                              }}
                              role="button"
                              tabIndex={0}
                              onKeyDown={(ev) => {
                                if (ev.key === 'Enter' || ev.key === ' ') {
                                  ev.preventDefault()
                                  ev.stopPropagation()
                                  onHarvest(row)
                                }
                              }}
                              className={`shrink-0 cursor-pointer rounded px-2.5 py-1 text-[11px] font-bold uppercase tracking-wide shadow-sm ring-2 ring-white transition ${
                                stage ? stage.button : 'bg-green-600 text-white hover:bg-green-700'
                              }`}
                            >
                              Harvest now
                            </span>
                          )}
                        </span>
                      </button>
                    )
                  })
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function AddPlantingDialog({
  date,
  onClose,
  farmId,
  defaultPurokId,
  existing,
  onSaved,
}: {
  date: string | null
  onClose(): void
  farmId: string
  /** The purok saved on the farm's account, so the owner does not pick it every time. */
  defaultPurokId: string
  existing: Schedule[]
  onSaved(): void
}) {
  const open = date !== null
  const today = todayISO()
  const [form, setForm] = useState({
    crop: 'rice' as Crop,
    variety: '',
    customVariety: '',
    seed_kg: '',
    note: '',
    purok_id: '',
  })

  useEffect(() => {
    if (!date) return
    setForm({
      crop: 'rice',
      variety: '',
      customVariety: '',
      seed_kg: '',
      note: '',
      purok_id: defaultPurokId,
    })
    setErrors({})
  }, [date])
  const [estimate, setEstimate] = useState<{
    expected_sacks: number
    expected_kg: number
    unit?: 'sack' | 'piece'
    plants?: number
    hills?: number
    seeds?: number
    fruits_per_plant?: number
    marketable_fraction?: number
    avg_fruit_kg?: number
    days_to_harvest: number
  } | null>(null)
  const [land, setLand] = useState<{
    hectares: number
    sqm: number
    kg_per_hectare: number
  } | null>(null)
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  const chosenVariety =
    form.variety === '__other' ? form.customVariety.trim() : form.variety.trim()

  // Watermelon seed is bought and sown by the gram; rice and corn by the kilogram.
  const isMelon = form.crop === 'watermelon'
  const inPieces = form.crop !== 'rice'
  const seedKg = isMelon ? Number(form.seed_kg || 0) / 1000 : Number(form.seed_kg || 0)

  useEffect(() => {
    if (!open) return
    const seed = seedKg
    if (seed <= 0) {
      setEstimate(null)
      return
    }
    let alive = true
    supabase
      .rpc('land_needed', {
        p_crop: form.crop,
        p_variety: chosenVariety,
        p_seed_kg: seed,
      })
      .then(({ data }) => {
        if (alive) setLand(data as any)
      })

    supabase
      .rpc('estimate_harvest', {
        p_crop: form.crop,
        p_variety: chosenVariety,
        p_seed_kg: seed,
      })
      .then(({ data }) => {
        if (alive) setEstimate(data as any)
      })

    return () => {
      alive = false
    }
  }, [open, form.crop, chosenVariety, form.seed_kg])

  const plantingDate = date ?? today
  const harvestDate = estimate ? addDays(plantingDate, estimate.days_to_harvest) : null

  const mergeInto = existing.find(
    (r) =>
      r.status !== 'cancelled' &&
      r.crop === form.crop &&
      r.planting_date === plantingDate &&
      (r.variety || '').trim().toLowerCase() === chosenVariety.toLowerCase() &&
      chosenVariety !== '',
  )

  const monthIndex = Number(plantingDate.slice(5, 7)) - 1
  const offSeason = !SEASON[form.crop].includes(monthIndex)
  const monthName = new Date(2000, monthIndex, 1).toLocaleDateString('en-PH', { month: 'long' })
  const goodMonths = SEASON[form.crop]
    .map((m) => new Date(2000, m, 1).toLocaleDateString('en-PH', { month: 'short' }))
    .join(', ')

  const sameDay = existing.filter(
    (r) => r.status !== 'cancelled' && r.planting_date === plantingDate,
  )

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      variety: form.variety ? null : 'Choose a variety.',
      customVariety:
        form.variety === '__other'
          ? validateRequired(form.customVariety, 'Variety name')
          : null,
      seed_kg:
        Number(form.seed_kg) > 0
          ? null
          : isMelon
            ? 'Enter the seed weight in grams.'
            : 'Enter the seed weight in kilograms.',
      purok_id: form.purok_id ? null : 'Choose the purok where the farm is located.',
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    const { data, error } = await supabase.rpc('add_or_merge_planting', {
      p_farm_id: farmId,
      p_crop: form.crop,
      p_variety: chosenVariety,
      p_planting_date: plantingDate,
      p_seed_kg: seedKg,
      p_note: form.note.trim(),
      p_purok_id: form.purok_id,
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }

    const result = data as { merged?: boolean; seed_kg?: number } | null
    toast.success(
      result?.merged
        ? `Merged into your existing ${chosenVariety} planting — now ${seedLabel(Number(result.seed_kg), form.crop)} of seed`
        : plantingDate > today
          ? 'Planting scheduled'
          : 'Planting added to your calendar',
    )
    onSaved()
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={date && date > today ? 'Schedule a planting' : 'Plan a planting'}
      description={
        date
          ? new Date(`${date}T12:00:00`).toLocaleDateString('en-PH', {
              weekday: 'long',
              day: 'numeric',
              month: 'long',
              year: 'numeric',
            })
          : undefined
      }
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Saving…' : 'Add planting'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        {offSeason && (
          <div className="flex gap-3 rounded-lg border border-amber-300 bg-amber-50 px-3.5 py-3">
            <span className="shrink-0 text-lg" aria-hidden>
              ⚠️
            </span>
            <span>
              <span className="block text-[13px] font-bold text-amber-900">
                {monthName} is not the usual season for {titleCase(form.crop)}
              </span>
              <span className="mt-0.5 block text-[13px] leading-relaxed text-amber-800">
                {titleCase(form.crop)} is normally planted in {goodMonths}. Planting outside these
                months can mean lower yield or more pests, so the estimate may be optimistic. You
                can still schedule it.
              </span>
            </span>
          </div>
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => {
              set('crop', e.target.value)
              set('variety', '')
            }}
            options={CROPS.map((c) => ({
              value: c,
              label: `${CROP_EMOJI[c]} ${titleCase(c)}`,
            }))}
          />
          <Select
            label="Variety"
            value={form.variety}
            error={errors.variety}
            onChange={(e) => set('variety', e.target.value)}
            options={[
              { value: '', label: 'Choose a variety…' },
              ...VARIETIES[form.crop].map((v) => ({ value: v, label: v })),
              { value: '__other', label: 'Other (not on the list)' },
            ]}
          />
        </div>

        <PurokSelect
          label="Where is the farm located?"
          value={form.purok_id}
          error={errors.purok_id}
          onChange={(id) => set('purok_id', id)}
          hint="Lets the barangay see which puroks are planting what."
        />

        {form.variety === '__other' && (
          <Field
            label="Name the variety you are planting"
            placeholder="Type the exact variety, e.g. Ifugao Tinawon"
            value={form.customVariety}
            error={errors.customVariety}
            onChange={(e) => set('customVariety', e.target.value)}
          />
        )}

        {mergeInto && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-3.5 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              You already planted {chosenVariety} on this date
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
              This seed is added to that planting, taking it from{' '}
              <span className="num font-semibold">
                {seedLabel(Number(mergeInto.seed_kg), form.crop)}
              </span>{' '}
              to{' '}
              <span className="num font-semibold">
                {seedLabel(Number(mergeInto.seed_kg) + seedKg, form.crop)}
              </span>
              . No second entry or progress bar is created.
            </p>
          </div>
        )}

        <div className="flex items-center gap-3 rounded-lg bg-brand-50 px-4 py-3">
          <span className="text-xl">🌱</span>
          <span>
            <span className="block text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
              {plantingDate > today ? 'Scheduled planting date' : 'Planting date'}
            </span>
            <span className="num block text-[15px] font-bold text-brand-900">
              {shortDate(plantingDate)}
            </span>
            {plantingDate > today && (
              <span className="block text-[11px] text-brand-900/70">
                In {daysBetween(today, plantingDate)} day
                {daysBetween(today, plantingDate) === 1 ? '' : 's'}
              </span>
            )}
          </span>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            label={isMelon ? 'Seed used (grams)' : 'Seed used (kg)'}
            type="number"
            min="0"
            step={isMelon ? '10' : '0.5'}
            inputMode="decimal"
            placeholder={isMelon ? 'e.g. 500' : 'e.g. 40'}
            value={form.seed_kg}
            error={errors.seed_kg}
            onChange={(e) => set('seed_kg', e.target.value)}
          />
        </div>

        {sameDay.length > 0 && (
          <p className="rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px] leading-relaxed text-soil-600">
            You already have {sameDay.length} planting{sameDay.length === 1 ? '' : 's'} on this
            date. Adding another is fine if it is a different plot.
          </p>
        )}

        {estimate && (
          <div className="rounded-xl bg-brand-50 px-4 py-3.5">
            <p className="text-center text-[13px] font-bold text-brand-900">Expected harvest</p>
            <div className="mt-3 rounded-lg bg-white/70 px-4 py-3 text-center">
              <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                Expected harvest date
              </p>
              <p className="num mt-0.5 text-[20px] font-bold text-brand-900">
                {shortDate(harvestDate)}
              </p>
              <p className="mt-0.5 text-[11px] text-brand-900/60">
                {estimate.days_to_harvest} days after planting
              </p>
            </div>

            <dl className={`mt-3 grid gap-3 ${inPieces && !isMelon ? 'grid-cols-3' : 'grid-cols-2'}`}>
              {inPieces && !isMelon && (
                <div className="rounded-lg bg-white/70 px-3 py-2.5 text-center">
                  <dt className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                    {plantNoun(form.crop)}s
                  </dt>
                  <dd className="num text-[19px] font-bold text-brand-900">
                    {Number(estimate.plants ?? 0).toLocaleString('en-PH')}
                  </dd>
                </div>
              )}
              <div className="rounded-lg bg-white/70 px-3 py-2.5 text-center">
                <dt className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                  {inPieces ? `Target ${pieceNoun(form.crop)}s` : 'Sacks'}
                </dt>
                <dd className="num text-[19px] font-bold text-brand-900">
                  {sacks(estimate.expected_sacks)}
                  {inPieces && <span className="ml-1 text-[12px] font-semibold">pcs</span>}
                </dd>
              </div>
              <div className="rounded-lg bg-white/70 px-3 py-2.5 text-center">
                <dt className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                  Weight
                </dt>
                <dd className="num text-[19px] font-bold text-brand-900">
                  {Math.round(estimate.expected_kg).toLocaleString('en-PH')} kg
                </dd>
              </div>
            </dl>

            {inPieces && (
              <p className="mt-2 text-[11px] leading-relaxed text-brand-900/60">
                The target is what this planting should bear when the plants are at their
                healthiest
                {isMelon
                  ? `, at around ${estimate.avg_fruit_kg} kg a fruit.`
                  : `: about ${estimate.fruits_per_plant} ${pieceNoun(form.crop)}${
                      Number(estimate.fruits_per_plant) === 1 ? '' : 's'
                    } on each ${plantNoun(form.crop)}, around ${estimate.avg_fruit_kg} kg each.`}
              </p>
            )}

            {land && land.hectares > 0 && (
              <div className="mt-3 rounded-lg bg-white/70 px-4 py-3 text-center">
                <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-900/70">
                  Land this seed needs
                </p>
                <p className="num mt-0.5 text-[20px] font-bold text-brand-900">
                  {Math.round(land.sqm).toLocaleString()} m²
                </p>
                <p className="mt-0.5 text-[11px] text-brand-900/60">
                  {isMelon
                    ? `${Math.round(land.kg_per_hectare * 1000)} g of seed covers 10,000 m² of Watermelon`
                    : ((land as any).caption ??
                      `${land.kg_per_hectare} kg of seed covers 10,000 m² of ${titleCase(form.crop)}`)}
                </p>
              </div>
            )}

          </div>
        )}

        <TextArea
          label="Note"
          max={200}
          rows={2}
          placeholder="Optional"
          value={form.note}
          onChange={(e) => set('note', e.target.value)}
        />
      </form>
    </Dialog>
  )
}

function DetailDialog({
  schedule,
  onClose,
  onChanged,
  startInHarvest = false,
}: {
  schedule: Schedule | null
  onClose(): void
  onChanged(): void
  startInHarvest?: boolean
}) {
  const [mode, setMode] = useState<'view' | 'harvest' | 'cost' | 'cancel'>('view')
  const [cancelReason, setCancelReason] = useState('')
  const [actual, setActual] = useState('')
  const [category, setCategory] = useState(EXPENSE_CATEGORIES[0])
  const [amount, setAmount] = useState('')
  const [spent, setSpent] = useState(0)
  const [busy, setBusy] = useState(false)
  const [modelKg, setModelKg] = useState<number | null>(null)
  const puroks = usePuroks()

  useEffect(() => {
    setModelKg(null)
    if (!schedule || schedule.crop === 'rice') return
    supabase
      .rpc('estimate_harvest', {
        p_crop: schedule.crop,
        p_variety: schedule.variety ?? '',
        p_seed_kg: Number(schedule.seed_kg),
      })
      .then(({ data }) => setModelKg(Number((data as any)?.expected_kg ?? 0)))
  }, [schedule?.id])

  useEffect(() => {
    if (!schedule) return
    setMode(startInHarvest ? 'harvest' : 'view')
    setCancelReason('')
    setActual(schedule.actual_sacks != null ? String(schedule.actual_sacks) : '')
    setAmount('')
    supabase
      .from('transactions')
      .select('amount')
      .eq('schedule_id', schedule.id)
      .then(({ data }) => setSpent((data ?? []).reduce((s, t: any) => s + Number(t.amount), 0)))
  }, [schedule?.id])

  if (!schedule) return null
  const c = CROP_COLOR[schedule.crop]

  async function doHarvest() {
    if (!/^\d+$/.test(actual.trim())) {
      toast.error(
        `Enter how many ${unitWord(schedule!.crop, 2)} you harvested (type 0 if you got none).`,
      )
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('harvest_schedule', {
      p_schedule_id: schedule!.id,
      p_actual_sacks: parseInt(actual.trim(), 10),
      p_price: null,
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Harvest recorded — list it on the Market when you are ready to sell')
    onChanged()
  }

  async function doCancel() {
    setBusy(true)
    const { error } = await supabase.rpc('cancel_schedule', {
      p_schedule_id: schedule!.id,
      p_reason: cancelReason.trim(),
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Planting cancelled')
    onChanged()
  }

  async function doCost() {
    if (!amount || Number(amount) <= 0) {
      toast.error('Enter the amount spent.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('add_crop_expense', {
      p_schedule_id: schedule!.id,
      p_category: category,
      p_amount: Number(amount),
      p_description: '',
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Cost recorded against this crop')
    onChanged()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={schedule.variety || titleCase(schedule.crop)}
      description={`${titleCase(schedule.crop)} · ${SCHEDULE_LABEL[schedule.status]}`}
      footer={
        mode === 'view' ? undefined : (
          <>
            <button className="btn-ghost" onClick={() => setMode('view')}>
              Back
            </button>
            <button
              className={mode === 'cancel' ? 'btn-danger' : 'btn-primary'}
              onClick={mode === 'harvest' ? doHarvest : mode === 'cancel' ? doCancel : doCost}
              disabled={busy}
            >
              {busy
                ? 'Saving…'
                : mode === 'harvest'
                  ? 'Save harvest'
                  : mode === 'cancel'
                    ? 'Cancel planting'
                    : 'Save cost'}
            </button>
          </>
        )
      }
    >
      {mode === 'view' && (
        <div className="space-y-4">
          <div className={`rounded-xl px-4 py-3.5 ${c.soft}`}>
            <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-[14px]">
              <Row label="Crop" value={`${CROP_EMOJI[schedule.crop]} ${titleCase(schedule.crop)}`} />
              <Row label="Variety" value={schedule.variety || '—'} />
              <Row label="Planting date" value={shortDate(schedule.planting_date)} />
              <Row label="Expected harvest" value={shortDate(schedule.harvest_date)} />
              <Row
                label="Days to harvest"
                value={
                  schedule.planting_date && schedule.harvest_date
                    ? `${daysBetween(schedule.planting_date, schedule.harvest_date)} days`
                    : '—'
                }
              />
              <Row
                label="Purok"
                value={puroks.find((p) => p.id === schedule.purok_id)?.name ?? schedule.field_name ?? '—'}
              />
              <Row label="Seed used" value={seedLabel(Number(schedule.seed_kg), schedule.crop)} />
              <Row
                label={
                  schedule.crop === 'rice'
                    ? 'Expected sacks'
                    : `Target ${pieceNoun(schedule.crop)}s`
                }
                value={sacksLabel(schedule.expected_sacks, schedule.crop)}
              />
              <Row
                label="Expected weight"
                value={
                  schedule.crop !== 'rice'
                    ? modelKg == null
                      ? '…'
                      : `${Math.round(modelKg).toLocaleString('en-PH')} kg`
                    : `${(schedule.expected_sacks * KG_PER_SACK).toLocaleString('en-PH')} kg`
                }
              />
              {schedule.actual_sacks != null && (
                <>
                  <Row label="Actual harvest" value={sacksLabel(schedule.actual_sacks, schedule.crop)} />
                  <Row
                    label="Harvested on"
                    value={shortDate(schedule.harvested_at ?? schedule.harvest_date)}
                  />
                </>
              )}
              <Row label="Costs so far" value={peso(spent)} />
            </dl>
          </div>

          {schedule.note && (
            <p className="rounded-lg bg-soil-50 px-3.5 py-3 text-[14px] leading-relaxed text-soil-700">
              {schedule.note}
            </p>
          )}

          {schedule.listed_product_id && (
            <p className="rounded-lg border border-green-200 bg-green-50 px-3.5 py-3 text-[13px] font-medium text-green-800">
              This harvest is listed on the market.
            </p>
          )}

          {schedule.status === 'harvested' ? (
            <div className="border-t border-soil-200 pt-4">
              <span className="flex items-center justify-center rounded-lg bg-green-100 py-2 text-[13px] font-semibold text-green-800">
                Harvested — no further costs can be added
              </span>
            </div>
          ) : (
            <div className="space-y-2 border-t border-soil-200 pt-4">
              <div className="grid grid-cols-2 gap-2">
                <button className="btn-ghost py-2 text-[13px]" onClick={() => setMode('cost')}>
                  Add cost
                </button>
                <button className="btn-primary py-2 text-[13px]" onClick={() => setMode('harvest')}>
                  Record harvest
                </button>
              </div>
              <button
                className="btn-ghost w-full py-2 text-[13px] text-red-600 hover:bg-red-50"
                onClick={() => setMode('cancel')}
              >
                Cancel this planting
              </button>
            </div>
          )}
        </div>
      )}

      {mode === 'harvest' && (
        <div className="space-y-4">
          {(() => {
            const total =
              schedule.planting_date && schedule.harvest_date
                ? Math.max(1, daysBetween(schedule.planting_date, schedule.harvest_date))
                : 0
            const done = schedule.planting_date
              ? Math.min(Math.max(daysBetween(schedule.planting_date, todayISO()), 0), total)
              : 0
            const pct = total ? Math.round((done / total) * 100) : 0
            if (pct >= 100) return null

            return (
              <div className="flex gap-3 rounded-lg border border-amber-300 bg-amber-50 px-3.5 py-3">
                <span className="shrink-0 text-lg" aria-hidden>
                  ⚠️
                </span>
                <span>
                  <span className="block text-[13px] font-bold text-amber-900">
                    This crop has not reached full growth
                  </span>
                  <span className="mt-0.5 block text-[13px] leading-relaxed text-amber-800">
                    It is {pct}% grown, with {total - done} day{total - done === 1 ? '' : 's'} left
                    until {shortDate(schedule.harvest_date)}. Harvesting early usually means fewer
                    and lighter {unitWord(schedule.crop, 2)} than the target.
                  </span>
                </span>
              </div>
            )
          })()}

          <p className="text-[14px] leading-relaxed text-soil-700">
            Enter what you actually harvested.
          </p>
          <SackInput
            label={
              schedule.crop === 'rice'
                ? 'Exact sacks harvested'
                : `Exact ${pieceNoun(schedule.crop)}s harvested`
            }
            unit={unitWord(schedule.crop, 2)}
            min={0}
            value={actual}
            hint={`Estimate was ${sacksLabel(schedule.expected_sacks, schedule.crop)} — enter what you really got`}
            onChange={(e) => setActual(e.target.value)}
          />

          {/^\d+$/.test(actual) && (
            <dl className="space-y-1 rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px]">
              <div className="flex justify-between gap-3">
                <dt className="text-soil-600">Estimated</dt>
                <dd className="num">{sacksLabel(schedule.expected_sacks, schedule.crop)}</dd>
              </div>
              <div className="flex justify-between gap-3 border-t border-soil-200 pt-1">
                <dt className="font-semibold">Actual harvest</dt>
                <dd className="num font-bold text-brand-700">{sacksLabel(actual, schedule.crop)}</dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-soil-600">Difference</dt>
                <dd
                  className={`num font-semibold ${
                    toSacks(actual) >= schedule.expected_sacks ? 'text-green-700' : 'text-red-600'
                  }`}
                >
                  {toSacks(actual) - schedule.expected_sacks > 0 ? '+' : ''}
                  {toSacks(actual) - schedule.expected_sacks} {unitWord(schedule.crop, 2)}
                </dd>
              </div>
            </dl>
          )}
          <p className="rounded-lg bg-soil-50 px-3.5 py-3 text-[13px] leading-relaxed text-soil-600">
            This goes into your inventory. To sell it, open Market and add a listing with the
            number of sacks and the price you want.
          </p>
        </div>
      )}

      {mode === 'cancel' && (
        <div className="space-y-4">
          <p className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-[14px] leading-relaxed text-amber-900">
            This removes the planting from your calendar. Use it when something was scheduled ahead
            and never went into the ground. Costs already recorded against it stay in Finance.
          </p>
          <TextArea
            label="Why is it being cancelled?"
            max={200}
            placeholder="Optional"
            value={cancelReason}
            onChange={(e) => setCancelReason(e.target.value)}
          />
        </div>
      )}

      {mode === 'cost' && (
        <div className="space-y-4">
          <p className="text-[14px] leading-relaxed text-soil-700">
            Costs recorded here belong to this planting, so Finance can show the profit for this
            crop rather than only the farm as a whole.
          </p>
          <Select
            label="What was it for?"
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            options={EXPENSE_CATEGORIES.map((x) => ({ value: x, label: x }))}
          />
          <PesoInput
            label="Amount spent"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
        </div>
      )}
    </Dialog>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-[11px] font-semibold uppercase tracking-wide text-soil-400">{label}</dt>
      <dd className="num mt-0.5 font-semibold text-soil-900">{value}</dd>
    </div>
  )
}

function Chevron({ dir }: { dir: 'left' | 'right' }) {
  return (
    <svg
      width="22"
      height="22"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d={dir === 'left' ? 'M15 18l-6-6 6-6' : 'M9 18l6-6-6-6'} />
    </svg>
  )
}
