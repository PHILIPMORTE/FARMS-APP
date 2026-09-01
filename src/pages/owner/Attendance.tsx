import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  Dialog,
  Empty,
  Field,
  SectionHeading,
  Select,
  Spinner,
  Stat,
  TextArea,
} from '@/components/ui'
import {
  ATTENDANCE_LABEL,
  hours,
  peso,
  pesoShort,
  relativeDate,
  shortDate,
  toISODate,
} from '@/lib/format'
import { friendlyError, validateAmount } from '@/lib/validation'
import type { AttendanceRow } from '@/lib/types'


function clockTime(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
}

export default function OwnerAttendance() {
  const { profile, farm } = useAuth()
  const [rows, setRows] = useState<AttendanceRow[] | null>(null)
  const [month, setMonth] = useState(() => new Date().toISOString().slice(0, 7))
  const [paying, setPaying] = useState<string | null>(null)
  const [workerFilter, setWorkerFilter] = useState('all')
  const [staff, setStaff] = useState<{ id: string; name: string }[]>([])
  const [statusFilter, setStatusFilter] = useState('all')
  const [taskFilter, setTaskFilter] = useState('all')
  const [payFilter, setPayFilter] = useState('all')

  async function togglePaid(row: AttendanceRow, send: boolean) {
    setPaying(row.id)
    const { error } = await supabase.rpc('set_attendance_paid', {
      p_attendance_id: row.id,
      p_paid: send,
    })
    setPaying(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(
      send ? 'Marked as sent — waiting for the worker to confirm' : 'Payment cancelled',
    )
    load()
  }

  const load = useCallback(async () => {
    if (!farm || !profile) return

    const start = `${month}-01`
    const [y, m] = month.split('-').map(Number)
    const end = toISODate(new Date(y, m, 0))

    const { data } = await supabase
      .from('attendance')
      .select('*, profiles!attendance_farmer_id_fkey(*), job_posts(title)')
      .eq('farm_id', farm.id)
      .gte('work_date', start)
      .lte('work_date', end)
      .order('work_date', { ascending: false })

    setRows((data as unknown as AttendanceRow[]) ?? [])

    if (profile) {
      const { data: jobs } = await supabase
        .from('job_posts')
        .select('id')
        .eq('owner_id', profile.id)
      const ids = (jobs ?? []).map((j) => j.id)
      if (ids.length) {
        const { data: hired } = await supabase
          .from('job_applications')
          .select('farmer_id, profiles(id, name)')
          .in('job_id', ids)
          .eq('status', 'accepted')
        const seen = new Map<string, string>()
        for (const h of (hired as any[]) ?? []) {
          if (h.profiles?.id) seen.set(h.profiles.id, h.profiles.name)
        }
        setStaff([...seen].map(([id, name]) => ({ id, name })))
      } else {
        setStaff([])
      }
    }

  }, [farm?.id, profile?.id, month])

  useEffect(() => {
    load()
  }, [load])

  const tasks = useMemo(
    () => [...new Set((rows ?? []).map((r) => r.task).filter(Boolean))].sort(),
    [rows],
  )

  const shown = useMemo(
    () =>
      (rows ?? []).filter((r) => {
        if (workerFilter !== 'all' && r.farmer_id !== workerFilter) return false
        if (statusFilter !== 'all' && r.status !== statusFilter) return false
        if (taskFilter !== 'all' && r.task !== taskFilter) return false
        if (payFilter !== 'all' && r.payment_status !== payFilter) return false
        return true
      }),
    [rows, workerFilter, statusFilter, taskFilter, payFilter],
  )

  const totals = useMemo(() => {
    const list = shown
    return {
      hours: list.reduce((s, r) => s + Number(r.hours_worked), 0),
      pay: list.reduce((s, r) => s + Number(r.computed_pay), 0),
      unpaid: list
        .filter((r) => r.payment_status !== 'paid')
        .reduce((s, r) => s + Number(r.computed_pay), 0),
      absent: list.filter((r) => r.status === 'absent').length,
      days: list.length,
    }
  }, [shown])

  if (!rows) return <Spinner label="Loading the work log" />

  return (
    <div className="space-y-6">

      <div className="no-print flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Daily work log</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            Times your workers clocked in and out. Each completed day earns the agreed wage for the
          job, whatever the hours.
          </p>
        </div>

      </div>

      {staff.length > 0 && (
        <div className="no-print">
          <p className="mb-2 text-[13px] font-semibold text-soil-600">Hired workers</p>
          <div className="flex flex-wrap gap-2">
            <button
              onClick={() => setWorkerFilter('all')}
              aria-pressed={workerFilter === 'all'}
              className={`chip border px-3 py-1.5 text-[13px] transition ${
                workerFilter === 'all'
                  ? 'border-brand-600 bg-brand-600 text-white'
                  : 'border-soil-200 bg-white text-soil-700 hover:bg-soil-100'
              }`}
            >
              Everyone
            </button>

            {staff.map((w) => {
              const days = (rows ?? []).filter((r) => r.farmer_id === w.id).length
              const active = workerFilter === w.id
              return (
                <button
                  key={w.id}
                  onClick={() => setWorkerFilter(active ? 'all' : w.id)}
                  aria-pressed={active}
                  className={`chip border px-3 py-1.5 text-[13px] transition ${
                    active
                      ? 'border-brand-600 bg-brand-600 text-white'
                      : 'border-soil-200 bg-white text-soil-700 hover:bg-soil-100'
                  }`}
                >
                  {w.name}
                  {days > 0 && (
                    <span className={`num ml-1 ${active ? 'text-white/80' : 'text-soil-400'}`}>
                      {days}
                    </span>
                  )}
                </button>
              )
            })}
          </div>
        </div>
      )}

      <div className="no-print grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div>
          <label className="label" htmlFor="month">
            Month
          </label>
          <input
            id="month"
            type="month"
            className="field num"
            value={month}
            onChange={(e) => setMonth(e.target.value)}
          />
        </div>
        <Select
          label="Worker"
          value={workerFilter}
          onChange={(e) => setWorkerFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All workers' },
            ...staff.map((w) => ({ value: w.id, label: w.name })),
          ]}
        />
        <Select
          label="Task"
          value={taskFilter}
          onChange={(e) => setTaskFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All tasks' },
            ...tasks.map((t) => ({ value: t, label: t })),
          ]}
        />
        <Select
          label="Attendance"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All' },
            { value: 'present', label: 'Present' },
            { value: 'absent', label: 'Absent' },
            { value: 'half_day', label: 'Half day' },
            { value: 'leave', label: 'On leave' },
          ]}
        />
        <Select
          label="Payment"
          value={payFilter}
          onChange={(e) => setPayFilter(e.target.value)}
          options={[
            { value: 'all', label: 'All' },
            { value: 'unpaid', label: 'Unpaid only' },
            { value: 'paid', label: 'Paid only' },
          ]}
        />
      </div>

      <div className="print-only mb-4">
        <h1 className="text-xl font-bold">{farm?.name ?? 'Farm'} — Daily Work Log</h1>
        <p className="text-[13px] text-soil-600">
          {new Date(`${month}-01`).toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })}
          {' · Standard day: '}
          {hours(farm?.standard_hours ?? 8)} hours
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Days recorded" value={String(totals.days)} />
        <Stat label="Total hours" value={hours(totals.hours)} />
        <Stat label="Absences" value={String(totals.absent)} accent={totals.absent ? 'red' : undefined} />
        <Stat label="Wages earned" value={pesoShort(totals.pay)} accent="green" />
        <Stat
          label="Still unpaid"
          value={pesoShort(totals.unpaid)}
          accent={totals.unpaid > 0 ? 'red' : undefined}
          sub={totals.unpaid > 0 ? 'Owed to workers' : 'All settled'}
        />
      </div>

      {shown.length === 0 ? (
        <Empty
          title="Nothing logged this month"
          body="Record a day for anyone you have hired. Their hours and pay build up here."
        />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[42rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Date</th>
                <th className="px-4 py-2.5 font-semibold">Worker</th>
                <th className="px-4 py-2.5 font-semibold">Task</th>
                <th className="px-4 py-2.5 font-semibold">Time in</th>
                <th className="px-4 py-2.5 font-semibold">Time out</th>
                <th className="px-4 py-2.5 font-semibold">Status</th>
                <th className="px-4 py-2.5 text-right font-semibold">Break</th>
                <th className="px-4 py-2.5 text-right font-semibold">Hours</th>
                <th className="px-4 py-2.5 text-right font-semibold">Daily wage</th>
                <th className="px-4 py-2.5 text-right font-semibold">Pay earned</th>
                <th className="px-4 py-2.5 text-center font-semibold">Payment</th>
                <th className="no-print px-4 py-2.5 text-right font-semibold">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {shown.map((r) => {
                return (
                  <tr key={r.id} className={r.status === 'absent' ? 'bg-red-50/60' : ''}>
                    <td className="num px-4 py-2.5">{shortDate(r.work_date)}</td>
                    <td className="px-4 py-2.5 font-semibold">{r.profiles?.name ?? '—'}</td>
                    <td className="px-4 py-2.5 text-soil-600">
                      {r.task || r.job_posts?.title || '—'}
                    </td>
                    <td className="num px-4 py-2.5">{clockTime(r.time_in)}</td>
                    <td className="num px-4 py-2.5">
                      {r.time_out ? (
                        clockTime(r.time_out)
                      ) : r.time_in ? (
                        <span className="text-amber-600">Still in</span>
                      ) : (
                        '—'
                      )}
                    </td>
                    <td className="px-4 py-2.5">
                      <Badge
                        tone={
                          r.status === 'present'
                            ? 'green'
                            : r.status === 'absent'
                              ? 'red'
                              : r.status === 'half_day'
                                ? 'amber'
                                : 'grey'
                        }
                      >
                        {ATTENDANCE_LABEL[r.status]}
                      </Badge>
                    </td>
                    <td className="num px-4 py-2.5 text-right text-soil-500">
                      {r.break_minutes > 0 ? `${Math.round(r.break_minutes)}m` : '—'}
                    </td>
                    <td className="num px-4 py-2.5 text-right font-semibold">
                      {hours(r.hours_worked)}
                    </td>
                    <td className="num px-4 py-2.5 text-right text-soil-600">
                      {peso(r.daily_wage)}
                    </td>
                    <td className="num px-4 py-2.5 text-right font-bold">
                      {peso(r.computed_pay)}
                      {r.status === 'half_day' && (
                        <span className="block text-[11px] font-medium text-amber-700">
                          Half day
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-2.5 text-center">
                      {Number(r.computed_pay) <= 0 ? (
                        <span className="text-[12px] text-soil-400">—</span>
                      ) : r.payment_status === 'paid' ? (
                        <Badge tone="green">Paid</Badge>
                      ) : r.payment_status === 'pending' ? (
                        <Badge tone="amber">Pending</Badge>
                      ) : (
                        <Badge tone="grey">Unpaid</Badge>
                      )}
                    </td>
                    <td className="no-print px-4 py-2.5 text-right">
                      {Number(r.computed_pay) <= 0 ? null : r.payment_status === 'paid' ? (
                        <span className="text-[12px] text-soil-400">
                          Confirmed {r.payment_confirmed_at ? relativeDate(r.payment_confirmed_at) : ''}
                        </span>
                      ) : r.payment_status === 'pending' ? (
                        <span className="inline-flex flex-col items-end gap-1">
                          <span className="text-[12px] text-amber-700">
                            Waiting for the worker to confirm
                          </span>
                          <button
                            disabled={paying === r.id}
                            onClick={() => togglePaid(r, false)}
                            className="btn-sm border border-soil-200 text-soil-600 hover:bg-soil-100"
                          >
                            {paying === r.id ? '…' : 'Cancel'}
                          </button>
                        </span>
                      ) : (
                        <button
                          disabled={paying === r.id}
                          onClick={() => togglePaid(r, true)}
                          className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                        >
                          {paying === r.id ? '…' : 'Mark paid'}
                        </button>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
            <tfoot className="border-t-2 border-soil-200 bg-soil-50 font-bold">
              <tr>
                <td className="px-4 py-2.5" colSpan={7}>
                  Total
                </td>
                <td className="num px-4 py-2.5 text-right">{hours(totals.hours)}</td>
                <td />
                <td className="num px-4 py-2.5 text-right">{peso(totals.pay)}</td>
                <td colSpan={2} />
              </tr>
            </tfoot>
          </table>
        </div>
      )}

      <div className="print-only mt-10 grid grid-cols-2 gap-12 text-[13px]">
        <div>
          <div className="h-10 border-b border-soil-800" />
          <p className="mt-1">Prepared by</p>
        </div>
        <div>
          <div className="h-10 border-b border-soil-800" />
          <p className="mt-1">Received by</p>
        </div>
      </div>

    </div>
  )
}
