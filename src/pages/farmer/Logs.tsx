import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { PurokMap } from '@/components/PurokMap'
import {
  canRecord,
  checkPlace,
  hasBoundary,
  isPhone,
  metresBetween,
  usesLocationCheck,
  type Verdict,
} from '@/lib/geofence'
import { useAuth } from '@/context/AuthContext'
import { Empty, SectionHeading, Spinner, Stat } from '@/components/ui'
import { hours, todayISO, peso , refreshBadges } from '@/lib/format'
import { friendlyError } from '@/lib/validation'
import type { AttendanceRow } from '@/lib/types'

interface ActiveJob {
  job_id: string
  job_title: string
  farm_id: string
  farm_name: string
  wage: number
  start_time: string
  end_time: string
  clocked: boolean
}

function toMinutes(t: string | null | undefined): number | null {
  if (!t) return null
  const [h, m] = t.split(':').map(Number)
  if (Number.isNaN(h)) return null
  return h * 60 + (m || 0)
}

function clockLabel(t: string | null | undefined): string {
  const mins = toMinutes(t)
  if (mins === null) return ''
  const h = Math.floor(mins / 60)
  const m = mins % 60
  const period = h >= 12 ? 'PM' : 'AM'
  const hour = h % 12 === 0 ? 12 : h % 12
  return `${hour}:${String(m).padStart(2, '0')} ${period}`
}

interface JobPlace {
  job_id: string
  farm_id: string
  farm_name: string
  latitude: number | null
  longitude: number | null
  radius_m: number
  require_gps: boolean
  max_accuracy_m: number
  purok_id: string | null
  purok_name: string | null
  purok_boundary: number[][] | null
}

interface OpenShift {
  id: string
  time_in: string
  work_date: string
  farm: string
  job: string | null
  wage: number
  start_time: string | null
  end_time: string | null
  break_started_at: string | null
  break_minutes: number
  job_id: string | null
}

function clock(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
}

function elapsed(from: string, to: Date, minusMinutes = 0): string {
  const ms = to.getTime() - new Date(from).getTime() - minusMinutes * 60000
  if (ms < 0) return '00:00:00'
  const h = Math.floor(ms / 3600000)
  const m = Math.floor((ms % 3600000) / 60000)
  const sec = Math.floor((ms % 60000) / 1000)
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`
}

export default function FarmerLogs() {
  const { profile } = useAuth()
  const [shift, setShift] = useState<OpenShift | null>(null)
  const [jobs, setJobs] = useState<ActiveJob[]>([])
  const [jobId, setJobId] = useState('')
  const [places, setPlaces] = useState<JobPlace[]>([])
  const [here, setHere] = useState<{ lat: number; lng: number; acc: number } | null>(null)
  const [geoError, setGeoError] = useState<string | null>(null)
  const [today, setToday] = useState<AttendanceRow[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [now, setNow] = useState(new Date())

  const load = useCallback(async () => {
    if (!profile) return
    const { data } = await supabase.rpc('my_open_shift')
    setShift((data as OpenShift | null) ?? null)

    const { data: pl } = await supabase.rpc('my_job_locations')
    setPlaces((pl as JobPlace[]) ?? [])

    const { data: js } = await supabase.rpc('my_active_jobs')
    const list = (js as ActiveJob[]) ?? []
    setJobs(list)
    setJobId((prev) => {
      if (prev && list.some((j) => j.job_id === prev && !j.clocked)) return prev
      return list.find((j) => !j.clocked)?.job_id ?? list[0]?.job_id ?? ''
    })

    const { data: rows } = await supabase
      .from('attendance')
      .select('*')
      .eq('farmer_id', profile!.id)
      .eq('work_date', todayISO())
      .order('time_in', { ascending: false })
    setToday((rows as AttendanceRow[]) ?? [])
    setLoading(false)
  }, [profile?.id])

  useEffect(() => {
    load()
    refreshBadges()
  }, [load])

  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 1000)
    return () => clearInterval(t)
  }, [])

  // The position is requested only when a farm you work for uses the location
  // check. Where the owner has switched it off, the phone is never asked.
  const needsLocation = places.some((pl) => usesLocationCheck(pl))

  useEffect(() => {
    if (!needsLocation) {
      setHere(null)
      setGeoError(null)
      return
    }
    if (!navigator.geolocation) {
      setGeoError('This device cannot share its location.')
      return
    }
    const watch = navigator.geolocation.watchPosition(
      (p) => {
        setHere({ lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy })
        setGeoError(null)
      },
      () => setGeoError('Location is off. Turn it on to time in or out.'),
      { enableHighAccuracy: true, maximumAge: 15000, timeout: 20000 },
    )
    return () => navigator.geolocation.clearWatch(watch)
  }, [needsLocation])

  function getPosition(): Promise<GeolocationPosition> {
    return new Promise((resolve, reject) => {
      if (!navigator.geolocation) {
        reject(new Error('This device cannot share its location.'))
        return
      }
      navigator.geolocation.getCurrentPosition(resolve, () =>
        reject(
          new Error(
            'Location is off. Turn it on and allow this site, so the farm can confirm you are on site.',
          ),
        ),
        { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 },
      )
    })
  }

  async function timeIn() {
    if (!jobId) {
      toast.error('Choose the farm you are working at.')
      return
    }

    const checked = usesLocationCheck(places.find((p) => p.job_id === jobId))
    setBusy(true)
    let pos: GeolocationPosition | null = null
    if (checked) {
      try {
        pos = await getPosition()
      } catch (err) {
        setBusy(false)
        toast.error(String((err as Error).message))
        return
      }
    }

    const { error } = await supabase.rpc('farmer_time_in', {
      p_job_id: jobId,
      ...(pos
        ? {
            p_latitude: pos.coords.latitude,
            p_longitude: pos.coords.longitude,
            p_accuracy: pos.coords.accuracy,
            p_device: isPhone() ? 'mobile' : 'desktop',
          }
        : {}),
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Timed in. Have a good shift.')
    load()
  }

  async function pause() {
    setBusy(true)
    const { error } = await supabase.rpc('farmer_pause_shift')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Break started')
    load()
  }

  async function resume() {
    setBusy(true)
    const { error } = await supabase.rpc('farmer_resume_shift')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Back to work')
    load()
  }

  async function timeOut() {
    const checked = usesLocationCheck(places.find((p) => p.job_id === shift?.job_id))
    setBusy(true)
    let pos: GeolocationPosition | null = null
    if (checked) {
      try {
        pos = await getPosition()
      } catch (err) {
        setBusy(false)
        toast.error(String((err as Error).message))
        return
      }
    }

    const { error } = await supabase.rpc('farmer_time_out', pos
      ? {
          p_latitude: pos.coords.latitude,
          p_longitude: pos.coords.longitude,
          p_accuracy: pos.coords.accuracy,
          p_device: isPhone() ? 'mobile' : 'desktop',
        }
      : {})
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Timed out. Your hours have been recorded.')
    load()
  }

  if (loading) return <Spinner label="Checking your shift" />

  const finishedToday = today.filter((r) => r.time_out)

  const onBreak = !!shift?.break_started_at
  const liveBreak = onBreak
    ? (now.getTime() - new Date(shift!.break_started_at!).getTime()) / 60000
    : 0
  const totalBreak = Math.floor((shift?.break_minutes ?? 0) + liveBreak)
  const workedMinutes = totalBreak

  const selected = jobs.find((j) => j.job_id === jobId) ?? null

  const placeFor = (jid: string | null | undefined) =>
    places.find((p) => p.job_id === jid) ?? null

  const inPlace = placeFor(jobId)
  const outPlace = placeFor(shift?.job_id)

  const phoneOk = isPhone()
  const inVerdict: Verdict = checkPlace(inPlace, here)
  const outVerdict: Verdict = checkPlace(outPlace, here)
  const inFenced = usesLocationCheck(inPlace)
  const outFenced = usesLocationCheck(outPlace)

  // A checked place also needs a phone, because the server refuses a computer.
  const canTimeIn = canRecord(inVerdict) && !(inFenced && !phoneOk)
  const canTimeOut = canRecord(outVerdict) && !(outFenced && !phoneOk)

  const activePlace = shift ? outPlace : inPlace
  const verdict: Verdict = shift ? outVerdict : inVerdict
  const activeOk = shift ? canTimeOut : canTimeIn
  const checkedHere = usesLocationCheck(activePlace)

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Time clock</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Tap in when you start and out when you finish. You are paid the agreed wage for the job
          once the day is done.
        </p>
      </div>

      {activePlace && !checkedHere && (
        <div className="rounded-xl border border-soil-200 bg-soil-50 px-4 py-3 text-[13px] leading-relaxed text-soil-600">
          {activePlace.require_gps === false
            ? `${activePlace.farm_name} has geofencing turned off, so you can record your time from anywhere.`
            : 'There is nothing to check your location against for this job, so you can record your time.'}
        </div>
      )}

      {activePlace && checkedHere && (
        <>
          <div
            className={`rounded-xl border px-4 py-3.5 ${
              geoError || !phoneOk
                ? 'border-red-200 bg-red-50'
                : activeOk
                  ? 'border-green-200 bg-green-50'
                  : 'border-amber-200 bg-amber-50'
            }`}
          >
            {geoError ? (
              <p className="text-[13px] font-semibold text-red-700">{geoError}</p>
            ) : !phoneOk ? (
              <>
                <p className="text-[14px] font-bold text-red-800">Use your phone</p>
                <p className="mt-0.5 text-[13px] leading-relaxed text-red-700">
                  Time in and out are accepted from a phone only, because a computer cannot
                  tell where it is accurately enough.
                </p>
              </>
            ) : verdict === 'waiting' || !here ? (
              <p className="text-[13px] text-soil-600">Finding where you are…</p>
            ) : verdict === 'inaccurate' ? (
              <>
                <p className="text-[14px] font-bold text-amber-900">Your location is not accurate enough</p>
                <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
                  It is only accurate to about <span className="num font-semibold">{Math.round(here.acc)} m</span>.
                  Go outside and wait a moment for the GPS to settle. The limit is{' '}
                  {activePlace.max_accuracy_m ?? 75} m.
                </p>
              </>
            ) : (
              <>
                <p className={`text-[14px] font-bold ${activeOk ? 'text-green-800' : 'text-amber-900'}`}>
                  {hasBoundary(activePlace)
                    ? activeOk
                      ? `You are inside ${activePlace.purok_name}`
                      : `You are not inside ${activePlace.purok_name}`
                    : activeOk
                      ? `You are at ${activePlace.farm_name}`
                      : `You are not at ${activePlace.farm_name} yet`}
                </p>
                <p className={`mt-0.5 text-[13px] leading-relaxed ${activeOk ? 'text-green-700' : 'text-amber-800'}`}>
                  {hasBoundary(activePlace) ? (
                    activeOk ? (
                      <>This job is in {activePlace.purok_name}, and you are standing in it.</>
                    ) : (
                      <>
                        This job is in {activePlace.purok_name}. You can record your time only from
                        inside that purok.
                      </>
                    )
                  ) : (
                    <>
                      About{' '}
                      <span className="num font-semibold">
                        {metresBetween(here.lat, here.lng, Number(activePlace.latitude), Number(activePlace.longitude))} m
                      </span>{' '}
                      away.{' '}
                      {activeOk
                        ? 'You are close enough to record your time.'
                        : `Move within ${activePlace.radius_m} m of the farm.`}
                    </>
                  )}
                  <span className="block text-[11px] opacity-70">
                    Location accurate to about {Math.round(here.acc)} m
                  </span>
                </p>
              </>
            )}
          </div>

          <PurokMap
            boundary={activePlace.purok_boundary}
            purokName={activePlace.purok_name}
            here={here}
            inside={activeOk}
            farm={
              activePlace.latitude != null && activePlace.longitude != null
                ? { lat: Number(activePlace.latitude), lng: Number(activePlace.longitude), name: activePlace.farm_name }
                : null
            }
          />
        </>
      )}

      <div className="card p-6 text-center">
        <p className="text-[12px] font-semibold uppercase tracking-wide text-soil-400">
          {new Date().toLocaleDateString('en-PH', {
            weekday: 'long',
            day: 'numeric',
            month: 'long',
          })}
        </p>

        {shift ? (
          <>
            <p
              className={`num mt-3 text-[42px] font-bold leading-none ${
                onBreak ? 'text-amber-600' : 'text-brand-700'
              }`}
            >
              {elapsed(shift.time_in, now, workedMinutes)}
            </p>

            {onBreak && (
              <p className="mt-1 inline-flex items-center gap-1.5 rounded-full bg-amber-100 px-3 py-1 text-[12px] font-bold uppercase tracking-wide text-amber-800">
                On break
              </p>
            )}
            <p className="mt-1.5 text-[13px] text-soil-600">
              Timed in at <span className="num font-semibold">{clock(shift.time_in)}</span>
            </p>
            <p className="mt-0.5 text-[13px] text-soil-400">
              {shift.job ?? 'Work'} · {shift.farm}
            </p>

            {totalBreak > 0 && (
              <p className="mt-1 text-[12px] text-soil-500">
                Break time so far: <span className="num font-semibold">{totalBreak} min</span>
              </p>
            )}

            <div className="mx-auto mt-5 flex w-full max-w-sm flex-col gap-2 sm:flex-row">
              {onBreak ? (
                <button
                  className="btn-primary flex-1 py-3.5 text-[16px]"
                  onClick={resume}
                  disabled={busy}
                >
                  {busy ? 'Saving…' : 'Resume Work'}
                </button>
              ) : (
                <button
                  className="btn-ghost flex-1 py-3.5 text-[16px]"
                  onClick={pause}
                  disabled={busy}
                >
                  {busy ? 'Saving…' : 'Pause'}
                </button>
              )}

              <button
                className="btn-danger flex-1 py-3.5 text-[16px] disabled:opacity-40"
                onClick={timeOut}
                disabled={busy || !canTimeOut}
              >
                {busy ? 'Recording…' : 'Time Out'}
              </button>
            </div>

          </>
        ) : (
          <>
            <p className="num mt-3 text-[42px] font-bold leading-none">
              {now.toLocaleTimeString('en-PH', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true,
              })}
            </p>
            <p className="mt-1.5 text-[13px] text-soil-600">
              {finishedToday.length > 0
                ? 'You have finished your shift for today.'
                : 'You are not timed in yet.'}
            </p>

            {jobs.length === 0 ? (
              <p className="mx-auto mt-5 max-w-sm rounded-lg bg-amber-50 px-4 py-3 text-[13px] leading-relaxed text-amber-900">
                You are not hired for any job yet. Apply on the Find Jobs page, and once a farm
                accepts you the time clock opens here.
              </p>
            ) : (
              <>
                <div className="mx-auto mt-5 max-w-sm text-left">
                  <label className="label" htmlFor="jobpick">
                    Which farm are you working at?
                  </label>
                  <div className="relative">
                    <select
                      id="jobpick"
                      className="field appearance-none bg-white pr-10"
                      value={jobId}
                      onChange={(e) => setJobId(e.target.value)}
                    >
                      {jobs.map((j) => (
                        <option key={j.job_id} value={j.job_id} disabled={j.clocked}>
                          {j.farm_name} — {j.job_title}
                          {j.clocked ? ' (done today)' : ` · ${peso(j.wage)}/day`}
                        </option>
                      ))}
                    </select>
                    <svg
                      aria-hidden
                      className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-soil-400"
                      width="16" height="16" viewBox="0 0 24 24" fill="none"
                      stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
                    >
                      <path d="m6 9 6 6 6-6" />
                    </svg>
                  </div>
                </div>

                <button
                  className="btn-primary mx-auto mt-4 w-full py-3.5 text-[16px] disabled:opacity-40 sm:w-72"
                  onClick={timeIn}
                  disabled={busy || !jobId || jobs.every((j) => j.clocked) || !canTimeIn}
                >
                  {busy ? 'Recording…' : 'Time In'}
                </button>

                {jobs.every((j) => j.clocked) && (
                  <p className="mt-2 text-[12px] text-soil-400">
                    You have finished every shift for today. Come back tomorrow.
                  </p>
                )}
              </>
            )}
          </>
        )}
      </div>

      <section>
        <SectionHeading>Today</SectionHeading>
        {today.length === 0 ? (
          <Empty title="Nothing recorded today" body="Tap Time In above to start your shift." />
        ) : (
          <div className="stagger grid grid-cols-3 gap-3">
            <Stat label="Time in" value={clock(today[0].time_in)} />
            <Stat label="Time out" value={clock(today[0].time_out)} />
            <Stat
              label="Hours"
              value={today[0].time_out ? hours(today[0].hours_worked) : 'Running'}
              accent={today[0].time_out ? 'green' : undefined}
            />
          </div>
        )}
      </section>
    </div>
  )
}
