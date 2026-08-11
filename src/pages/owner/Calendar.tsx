import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Dialog, Empty, SackInput, SectionHeading, Select, Spinner } from '@/components/ui'
import {
  CROPS,
  CROP_DURATION,
  CROP_EMOJI,
  addMonths,
  monthLabel,
  titleCase,
} from '@/lib/format'
import { friendlyError, validateWholeNumber } from '@/lib/validation'
import type { Crop, Schedule } from '@/lib/types'

/**
 * Philippine planting seasons, by month index (0 = January).
 * Rice   — wet May–Aug, dry Nov–Feb
 * Corn   — wet Apr–Jun, dry Nov–Jan
 * Melon  — dry Dec–May
 */
const SEASON: Record<Crop, number[]> = {
  rice: [4, 5, 6, 7, 10, 11, 0, 1],
  corn: [3, 4, 5, 10, 11, 0],
  watermelon: [11, 0, 1, 2, 3, 4],
}

const DOT: Record<Crop, string> = {
  rice: 'bg-green-600',
  corn: 'bg-yellow-500',
  watermelon: 'bg-red-500',
}

const SEASON_LABEL: Record<Crop, string> = {
  rice: 'Wet May–Aug · Dry Nov–Feb',
  corn: 'Wet Apr–Jun · Dry Nov–Jan',
  watermelon: 'Dry Dec–May',
}

export default function OwnerCalendar() {
  const { farm } = useAuth()
  const [cursor, setCursor] = useState(() => new Date())
  const [schedules, setSchedules] = useState<Schedule[] | null>(null)
  const [open, setOpen] = useState(false)

  async function load() {
    if (!farm) return
    const { data } = await supabase
      .from('schedules')
      .select('*')
      .eq('farm_id', farm.id)
      .order('planting_month', { ascending: true })
    setSchedules((data as Schedule[]) ?? [])
  }

  useEffect(() => {
    load()
  }, [farm?.id])

  const grid = useMemo(() => buildMonth(cursor), [cursor])
  const monthCrops = CROPS.filter((c) => SEASON[c].includes(cursor.getMonth()))

  if (!schedules) return <Spinner label="Loading your calendar" />

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Harvest calendar</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            Coloured dots mark the months each crop is normally planted in the Philippines.
          </p>
        </div>
        <button className="btn-primary" onClick={() => setOpen(true)}>
          Add schedule
        </button>
      </div>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_20rem]">
        {/* Calendar */}
        <div className="card p-4 sm:p-5">
          <div className="mb-4 flex items-center justify-between">
            <button
              className="rounded-lg p-2 text-soil-600 hover:bg-soil-100"
              aria-label="Previous month"
              onClick={() => setCursor((d) => new Date(d.getFullYear(), d.getMonth() - 1, 1))}
            >
              <Chevron dir="left" />
            </button>
            <h2 className="text-base font-bold">
              {cursor.toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
            </h2>
            <button
              className="rounded-lg p-2 text-soil-600 hover:bg-soil-100"
              aria-label="Next month"
              onClick={() => setCursor((d) => new Date(d.getFullYear(), d.getMonth() + 1, 1))}
            >
              <Chevron dir="right" />
            </button>
          </div>

          <div className="grid grid-cols-7 gap-1 text-center">
            {['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d, i) => (
              <div key={i} className="pb-2 text-[11px] font-bold uppercase text-soil-400">
                {d}
              </div>
            ))}
            {grid.map((day, i) => (
              <div
                key={i}
                className={`aspect-square rounded-lg p-1 ${
                  day ? 'bg-soil-50' : ''
                } ${isToday(day, cursor) ? 'ring-2 ring-brand-600' : ''}`}
              >
                {day && (
                  <>
                    <span className="num block text-[13px] font-semibold leading-tight">{day}</span>
                    <span className="mt-0.5 flex justify-center gap-0.5">
                      {monthCrops.map((c) => (
                        <span key={c} className={`h-1.5 w-1.5 rounded-full ${DOT[c]}`} />
                      ))}
                    </span>
                  </>
                )}
              </div>
            ))}
          </div>

          <div className="mt-5 space-y-2 border-t border-soil-200/70 pt-4">
            {CROPS.map((c) => (
              <div key={c} className="flex items-center gap-2.5 text-[13px]">
                <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${DOT[c]}`} />
                <span className="font-semibold">
                  {CROP_EMOJI[c]} {titleCase(c)}
                </span>
                <span className="text-soil-400">{SEASON_LABEL[c]}</span>
              </div>
            ))}
          </div>
        </div>

        {/* Schedules */}
        <div>
          <SectionHeading>Planting schedules</SectionHeading>
          {schedules.length === 0 ? (
            <Empty
              title="No schedules yet"
              body="Add a planting month and FARMS works out the harvest window for you."
              action={
                <button className="btn-primary" onClick={() => setOpen(true)}>
                  Add schedule
                </button>
              }
            />
          ) : (
            <ul className="space-y-2.5">
              {schedules.map((s) => (
                <li key={s.id} className="card px-4 py-3.5">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-sm font-bold">
                        {CROP_EMOJI[s.crop]} {titleCase(s.crop)}
                      </p>
                      <p className="mt-0.5 text-[13px] text-soil-600">
                        Planted {monthLabel(s.planting_month)}
                      </p>
                      <p className="text-[13px] font-semibold text-brand-700">
                        Harvest around {monthLabel(addMonths(s.planting_month, s.estimated_months))}
                      </p>
                    </div>
                    <button
                      onClick={async () => {
                        await supabase.from('schedules').delete().eq('id', s.id)
                        toast.success('Schedule removed')
                        load()
                      }}
                      className="shrink-0 rounded-lg p-1.5 text-soil-400 hover:bg-red-50 hover:text-red-600"
                      aria-label={`Remove ${s.crop} schedule`}
                    >
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                        <path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6" />
                      </svg>
                    </button>
                  </div>
                  <p className="num mt-2 text-[12px] text-soil-400">
                    {s.estimated_months} months to harvest
                  </p>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      <AddScheduleDialog
        open={open}
        onClose={() => setOpen(false)}
        farmId={farm?.id ?? ''}
        onSaved={() => {
          setOpen(false)
          load()
        }}
      />
    </div>
  )
}

function AddScheduleDialog({
  open,
  onClose,
  farmId,
  onSaved,
}: {
  open: boolean
  onClose(): void
  farmId: string
  onSaved(): void
}) {
  const thisMonth = new Date().toISOString().slice(0, 7)
  const [crop, setCrop] = useState<Crop>('rice')
  const [month, setMonth] = useState(thisMonth)
  const [months, setMonths] = useState(String(CROP_DURATION.rice))
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  // Duration is auto-filled per crop but stays editable.
  function pickCrop(c: Crop) {
    setCrop(c)
    setMonths(String(CROP_DURATION[c]))
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      month: /^\d{4}-\d{2}$/.test(month) ? null : 'Pick a planting month.',
      months: validateWholeNumber(months, 1, 'duration'),
    }
    setErrors(next)
    if (next.month || next.months) return

    setBusy(true)
    const { error } = await supabase.from('schedules').insert({
      farm_id: farmId,
      crop,
      planting_month: month,
      estimated_months: parseInt(months, 10),
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Schedule added')
    onSaved()
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Add a planting schedule"
      description="FARMS estimates the harvest month from the crop's growing time."
      footer={
        <>
          <button className="btn-ghost" onClick={onClose} type="button">
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Saving…' : 'Add schedule'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <Select
          label="Crop"
          value={crop}
          onChange={(e) => pickCrop(e.target.value as Crop)}
          options={CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` }))}
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label className="label" htmlFor="pm">
              Planting month
            </label>
            <input
              id="pm"
              type="month"
              className={`field num ${errors.month ? 'field-error' : ''}`}
              value={month}
              onChange={(e) => setMonth(e.target.value)}
            />
            {errors.month && <p className="err">{errors.month}</p>}
          </div>
          <div>
            <label className="label" htmlFor="dur">
              Months to harvest
            </label>
            <input
              id="dur"
              type="number"
              step="1"
              min="1"
              inputMode="numeric"
              className={`field num ${errors.months ? 'field-error' : ''}`}
              value={months}
              onChange={(e) => setMonths(e.target.value)}
            />
            {errors.months ? (
              <p className="err">{errors.months}</p>
            ) : (
              <p className="mt-1.5 text-[13px] text-soil-400">
                Filled in for {crop}: {CROP_DURATION[crop]} months
              </p>
            )}
          </div>
        </div>
        {/^\d{4}-\d{2}$/.test(month) && /^\d+$/.test(months) && (
          <p className="rounded-xl bg-brand-50 px-4 py-3 text-sm font-semibold text-brand-900">
            Expected harvest: {monthLabel(addMonths(month, parseInt(months, 10)))}
          </p>
        )}
      </form>
    </Dialog>
  )
}

function buildMonth(d: Date): (number | null)[] {
  const first = new Date(d.getFullYear(), d.getMonth(), 1).getDay()
  const days = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()
  return [...Array(first).fill(null), ...Array.from({ length: days }, (_, i) => i + 1)]
}

function isToday(day: number | null, cursor: Date) {
  if (!day) return false
  const t = new Date()
  return (
    t.getDate() === day && t.getMonth() === cursor.getMonth() && t.getFullYear() === cursor.getFullYear()
  )
}

function Chevron({ dir }: { dir: 'left' | 'right' }) {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
      <path d={dir === 'left' ? 'M15 18l-6-6 6-6' : 'M9 18l6-6-6-6'} />
    </svg>
  )
}
