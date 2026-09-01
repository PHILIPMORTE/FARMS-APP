import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, DataTable, Empty, SectionHeading, Spinner, Stat } from '@/components/ui'
import { hours, peso, pesoShort, shortDate, titleCase } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { JobApplication } from '@/lib/types'

interface PayrollRow {
  farmer_id: string
  worker_name: string
  phone: string
  days_present: number
  days_absent: number
  days_half: number
  days_leave: number
  total_hours: number
  total_pay: number
}

export default function OwnerPayroll() {
  const { profile, farm } = useAuth()
  const [month, setMonth] = useState(() => new Date().toISOString().slice(0, 7))
  const [rows, setRows] = useState<PayrollRow[] | null>(null)
  const [staff, setStaff] = useState<JobApplication[]>([])
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!profile) return

    const { data, error: rpcError } = await supabase.rpc('payroll_summary', { p_month: month })
    if (rpcError) {
      setError(rpcError.message)
      setRows([])
    } else {
      setError(null)
      setRows((data as PayrollRow[]) ?? [])
    }

    const { data: jobs } = await supabase.from('job_posts').select('id').eq('owner_id', profile.id)
    const ids = (jobs ?? []).map((j) => j.id)
    if (ids.length) {
      const { data: hired } = await supabase
        .from('job_applications')
        .select('*, job_posts(*), profiles(*)')
        .in('job_id', ids)
        .eq('status', 'accepted')
        .order('updated_at', { ascending: false })
      setStaff((hired as unknown as JobApplication[]) ?? [])
    } else {
      setStaff([])
    }
  }, [profile?.id, month])

  useEffect(() => {
    load()
  }, [load])

  const totals = useMemo(() => {
    const list = rows ?? []
    return {
      workers: list.length,
      hours: list.reduce((s, r) => s + Number(r.total_hours), 0),
      pay: list.reduce((s, r) => s + Number(r.total_pay), 0),
      absences: list.reduce((s, r) => s + r.days_absent, 0),
    }
  }, [rows])

  if (!rows) return <Spinner label="Loading payroll" />

  const monthName = new Date(`${month}-01`).toLocaleDateString('en-PH', {
    month: 'long',
    year: 'numeric',
  })

  return (
    <div className="space-y-6">
      <div className="no-print flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Payroll &amp; workforce</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            Wages owed this month, worked out from the daily work log.
          </p>
        </div>
        <button className="btn-ghost" onClick={() => window.print()}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
            <path d="M6 9V2h12v7M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2M6 14h12v8H6z" />
          </svg>
          Print payslip sheet
        </button>
      </div>

      <div className="no-print max-w-xs">
        <label className="label" htmlFor="pm">
          Payroll month
        </label>
        <input
          id="pm"
          type="month"
          className="field num"
          value={month}
          onChange={(e) => setMonth(e.target.value)}
        />
      </div>

      <div className="print-only mb-4">
        <h1 className="text-xl font-bold">{farm?.name ?? 'Farm'} — Payroll Summary</h1>
        <p className="text-[13px] text-soil-600">{monthName}</p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
          {error}
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Workers paid" value={String(totals.workers)} />
        <Stat label="Total hours" value={hours(totals.hours)} />
        <Stat
          label="Absences"
          value={String(totals.absences)}
          accent={totals.absences ? 'red' : undefined}
        />
        <Stat label="Total wages" value={pesoShort(totals.pay)} accent="green" />
      </div>

      <section>
        <SectionHeading>Payroll for {monthName}</SectionHeading>
        {rows.length === 0 ? (
          <Empty
            title="No wages this month"
            body="Record days in the Work Log and each worker's pay is totalled here."
          />
        ) : (
          <DataTable
            minWidth="48rem"
            headers={[
              { label: 'Worker' },
              { label: 'Present', align: 'right' },
              { label: 'Half day', align: 'right' },
              { label: 'Leave', align: 'right' },
              { label: 'Absent', align: 'right' },
              { label: 'Hours', align: 'right' },
              { label: 'Wages due', align: 'right' },
            ]}
          >
            {rows.map((r) => (
              <tr key={r.farmer_id}>
                <td className="px-4 py-3">
                  <span className="block font-semibold">{r.worker_name}</span>
                  <span className="num block text-[12px] text-soil-400">
                    {displayPhone(r.phone)}
                  </span>
                </td>
                <td className="num px-4 py-3 text-right">{r.days_present}</td>
                <td className="num px-4 py-3 text-right">{r.days_half}</td>
                <td className="num px-4 py-3 text-right">{r.days_leave}</td>
                <td
                  className={`num px-4 py-3 text-right ${
                    r.days_absent > 0 ? 'font-bold text-red-600' : ''
                  }`}
                >
                  {r.days_absent}
                </td>
                <td className="num px-4 py-3 text-right font-semibold">{hours(r.total_hours)}</td>
                <td className="num px-4 py-3 text-right font-bold text-brand-700">
                  {peso(r.total_pay)}
                </td>
              </tr>
            ))}
            <tr className="bg-soil-50 font-bold">
              <td className="px-4 py-3">Total</td>
              <td className="num px-4 py-3 text-right">
                {rows.reduce((s, r) => s + r.days_present, 0)}
              </td>
              <td className="num px-4 py-3 text-right">
                {rows.reduce((s, r) => s + r.days_half, 0)}
              </td>
              <td className="num px-4 py-3 text-right">
                {rows.reduce((s, r) => s + r.days_leave, 0)}
              </td>
              <td className="num px-4 py-3 text-right">{totals.absences}</td>
              <td className="num px-4 py-3 text-right">{hours(totals.hours)}</td>
              <td className="num px-4 py-3 text-right">{peso(totals.pay)}</td>
            </tr>
          </DataTable>
        )}
      </section>

      <section className="no-print">
        <SectionHeading>Workforce</SectionHeading>
        {staff.length === 0 ? (
          <Empty
            title="No one hired yet"
            body="Accept an application on the Labor page and the worker appears here."
          />
        ) : (
          <DataTable
            minWidth="46rem"
            headers={[
              { label: 'Worker' },
              { label: 'Contact' },
              { label: 'Position' },
              { label: 'Daily rate', align: 'right' },
              { label: 'Hired' },
              { label: 'Skills' },
            ]}
          >
            {staff.map((a) => (
              <tr key={a.id}>
                <td className="px-4 py-3 font-semibold">{a.profiles?.name ?? 'Worker'}</td>
                <td className="px-4 py-3">
                  {a.profiles?.phone && (
                    <a
                      href={`tel:${a.profiles.phone}`}
                      className="num text-[12px] text-brand-700 underline"
                    >
                      {displayPhone(a.profiles.phone)}
                    </a>
                  )}
                </td>
                <td className="px-4 py-3 text-soil-600">{a.job_posts?.title ?? '—'}</td>
                <td className="num px-4 py-3 text-right font-semibold">
                  {peso(a.job_posts?.wage ?? 0)}
                </td>
                <td className="num px-4 py-3 text-soil-600">{shortDate(a.updated_at)}</td>
                <td className="px-4 py-3">
                  <Badge tone="brand">{titleCase(a.job_posts?.type ?? 'seasonal')}</Badge>
                </td>
              </tr>
            ))}
          </DataTable>
        )}
      </section>

      <div className="print-only mt-10 grid grid-cols-2 gap-12 text-[13px]">
        <div>
          <div className="h-10 border-b border-soil-800" />
          <p className="mt-1">Prepared by</p>
        </div>
        <div>
          <div className="h-10 border-b border-soil-800" />
          <p className="mt-1">Approved by</p>
        </div>
      </div>
    </div>
  )
}
