import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/validation'
import { Badge, DataTable, Dialog, Empty, Spinner, Stat } from '@/components/ui'
import { ATTENDANCE_LABEL, hours, peso, pesoShort, shortDate,
  toISODate,
  todayISO,
} from '@/lib/format'
import type { AttendanceRow } from '@/lib/types'

function clock(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  })
}

export default function FarmerHistory() {
  const [rows, setRows] = useState<AttendanceRow[] | null>(null)
  const [month, setMonth] = useState(() => todayISO().slice(0, 7))
  const [confirming, setConfirming] = useState<string | null>(null)
  const [pendingRow, setPendingRow] = useState<AttendanceRow | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  async function confirmPayment() {
    if (!pendingRow) return
    setConfirming(pendingRow.id)
    const { error } = await supabase.rpc('farmer_confirm_payment', {
      p_attendance_id: pendingRow.id,
    })
    setConfirming(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Payment confirmed')
    setPendingRow(null)
    setReloadKey((k) => k + 1)
  }

  useEffect(() => {
    ;(async () => {
      setRows(null)
      const [y, m] = month.split('-').map(Number)
      const start = `${month}-01`
      const end = toISODate(new Date(y, m, 0))

      const { data } = await supabase
        .from('attendance')
        .select('*, farms(name)')
        .gte('work_date', start)
        .lte('work_date', end)
        .order('work_date', { ascending: false })

      setRows((data as unknown as AttendanceRow[]) ?? [])
    })()
  }, [month, reloadKey])

  const totals = useMemo(() => {
    const list = rows ?? []
    return {
      days: list.length,
      hours: list.reduce((s, r) => s + Number(r.hours_worked), 0),
      earned: list.reduce((s, r) => s + Number(r.computed_pay), 0),
      unpaid: list
        .filter((r) => r.payment_status !== 'paid')
        .reduce((s, r) => s + Number(r.computed_pay), 0),
    }
  }, [rows])

  if (!rows) return <Spinner label="Loading your work history" />

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">My work history</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every shift you have recorded, with the hours and pay for each.
        </p>
      </div>

      <div className="max-w-xs">
        <label className="label" htmlFor="hm">
          Month
        </label>
        <input
          id="hm"
          type="month"
          className="field num"
          value={month}
          onChange={(e) => setMonth(e.target.value)}
        />
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Days worked" value={String(totals.days)} />
        <Stat label="Total hours" value={hours(totals.hours)} />
        <Stat label="Total earned" value={pesoShort(totals.earned)} accent="green" />
        <Stat
          label="Not yet paid"
          value={pesoShort(totals.unpaid)}
          accent={totals.unpaid > 0 ? 'red' : undefined}
          sub={totals.unpaid > 0 ? 'Still owed to you' : 'All settled'}
        />
      </div>

      {rows.length === 0 ? (
        <Empty
          title="Nothing recorded this month"
          body="Use the Time Clock page to time in when you start work."
        />
      ) : (
        <DataTable
          minWidth="46rem"
          headers={[
            { label: 'Date' },
            { label: 'Farm' },
            { label: 'Time in' },
            { label: 'Time out' },
            { label: 'Break', align: 'right' },
            { label: 'Hours', align: 'right' },
            { label: 'Pay', align: 'right' },
            { label: 'Payment' },
            { label: '', align: 'right' },
          ]}
        >
          {rows.map((r) => (
            <tr key={r.id}>
              <td className="num px-4 py-3">{shortDate(r.work_date)}</td>
              <td className="px-4 py-3 text-soil-600">
                {(r as any).farms?.name ?? '—'}
              </td>
              <td className="num px-4 py-3">{clock(r.time_in)}</td>
              <td className="num px-4 py-3">
                {r.time_out ? (
                  clock(r.time_out)
                ) : (
                  <span className="text-amber-600">Still in</span>
                )}
              </td>
              <td className="num px-4 py-3 text-right text-soil-500">
                {r.break_minutes > 0 ? `${Math.round(r.break_minutes)}m` : '—'}
              </td>
              <td className="num px-4 py-3 text-right font-semibold">{hours(r.hours_worked)}</td>
              <td className="num px-4 py-3 text-right font-bold">{peso(r.computed_pay)}</td>
              <td className="px-4 py-3">
                <span className="flex flex-wrap gap-1">
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
                  {Number(r.computed_pay) > 0 && (
                    <Badge
                      tone={
                        r.payment_status === 'paid'
                          ? 'green'
                          : r.payment_status === 'pending'
                            ? 'amber'
                            : 'grey'
                      }
                    >
                      {r.payment_status === 'paid'
                        ? 'Received'
                        : r.payment_status === 'pending'
                          ? 'Sent to you'
                          : 'Not yet paid'}
                    </Badge>
                  )}
                </span>
              </td>
              <td className="px-4 py-3 text-right">
                {r.payment_status === 'pending' ? (
                  <button
                    className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                    disabled={confirming === r.id}
                    onClick={() => setPendingRow(r)}
                  >
                    {confirming === r.id ? '…' : 'Payment received'}
                  </button>
                ) : r.payment_status === 'paid' ? (
                  <span className="text-[12px] text-soil-400">
                    {r.payment_confirmed_at ? shortDate(r.payment_confirmed_at) : 'Confirmed'}
                  </span>
                ) : (
                  <span className="text-[12px] text-soil-400">—</span>
                )}
              </td>
            </tr>
          ))}
        </DataTable>
      )}

      <Dialog
        open={pendingRow !== null}
        onClose={() => setPendingRow(null)}
        title="Confirm you received this payment?"
        description={pendingRow ? shortDate(pendingRow.work_date) : undefined}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setPendingRow(null)}>
              Not yet
            </button>
            <button
              className="btn-primary"
              onClick={confirmPayment}
              disabled={confirming !== null}
            >
              {confirming ? 'Confirming…' : 'Yes, I received it'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            Confirm only once the money is actually in your hands. This cannot be undone, and it is
            the record both you and the farm owner rely on.
          </p>
          {pendingRow && (
            <p className="rounded-lg bg-brand-50 px-4 py-3 text-center">
              <span className="block text-[12px] font-semibold uppercase tracking-wide text-brand-900/70">
                Amount
              </span>
              <span className="num block text-[22px] font-bold text-brand-900">
                {peso(pendingRow.computed_pay)}
              </span>
            </p>
          )}
        </div>
      </Dialog>
    </div>
  )
}
