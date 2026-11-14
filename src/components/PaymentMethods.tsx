import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Dialog, Field, Spinner } from '@/components/ui'
import { peso } from '@/lib/format'
import {
  friendlyError,
  validateGcashName,
  validateGcashNumber,
  validateGcashReference,
} from '@/lib/validation'

export type PayMethod = 'cash' | 'gcash'
export const PAY_LABEL: Record<PayMethod, string> = { cash: 'Cash', gcash: 'GCash' }

const GCASH_TONE = 'bg-sky-100 text-sky-800'
const CASH_TONE = 'bg-green-100 text-green-800'

/* -------------------------------------------------------------------------- */
/*  Small chips shown on a listing or an order                                 */
/* -------------------------------------------------------------------------- */

export function PayChips({ cash, gcash }: { cash: boolean; gcash: boolean }) {
  return (
    <span className="flex flex-wrap gap-1">
      {cash && <span className={`chip ${CASH_TONE}`}>Cash</span>}
      {gcash && <span className={`chip ${GCASH_TONE}`}>GCash</span>}
    </span>
  )
}

export function MethodChip({ method }: { method: PayMethod }) {
  return <span className={`chip ${method === 'gcash' ? GCASH_TONE : CASH_TONE}`}>{PAY_LABEL[method]}</span>
}

/* -------------------------------------------------------------------------- */
/*  Farm owner: which methods does this listing accept?                        */
/* -------------------------------------------------------------------------- */

function ToggleCard({
  on,
  onClick,
  icon,
  title,
  body,
}: {
  on: boolean
  onClick(): void
  icon: string
  title: string
  body: string
}) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={on}
      onClick={onClick}
      className={`flex items-start gap-3 rounded-xl border-2 p-3 text-left transition ${
        on ? 'border-brand-600 bg-brand-50' : 'border-soil-200 bg-white hover:border-soil-300'
      }`}
    >
      <span className="text-[22px] leading-none" aria-hidden>
        {icon}
      </span>
      <span className="flex-1">
        <span className="block text-[14px] font-bold text-soil-900">{title}</span>
        <span className="block text-[12px] leading-snug text-soil-600">{body}</span>
      </span>
      <span
        className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded border-2 text-[12px] font-bold ${
          on ? 'border-brand-600 bg-brand-600 text-white' : 'border-soil-300 text-transparent'
        }`}
        aria-hidden
      >
        ✓
      </span>
    </button>
  )
}

export function PayMethodPicker({
  cash,
  gcash,
  onChange,
}: {
  cash: boolean
  gcash: boolean
  onChange(cash: boolean, gcash: boolean): void
}) {
  // At least one way to pay must stay on.
  const toggleCash = () => (cash && !gcash ? null : onChange(!cash, gcash))
  const toggleGcash = () => (gcash && !cash ? null : onChange(cash, !gcash))

  return (
    <div>
      <div className="grid gap-2 sm:grid-cols-2">
        <ToggleCard
          on={cash}
          onClick={toggleCash}
          icon="💵"
          title="Cash"
          body="Paid when the buyer picks it up or you deliver it."
        />
        <ToggleCard
          on={gcash}
          onClick={toggleGcash}
          icon="📱"
          title="GCash"
          body="The buyer sends the payment to your GCash number."
        />
      </div>
      <p className="mt-1.5 text-[12px] text-soil-500">
        Choose one or both. Buyers can only pay in a way you accept.
      </p>
    </div>
  )
}

export function GcashFields({
  number,
  name,
  onNumber,
  onName,
  errors,
}: {
  number: string
  name: string
  onNumber(v: string): void
  onName(v: string): void
  errors?: { number?: string | null; name?: string | null }
}) {
  return (
    <div className="mt-3 space-y-3 rounded-xl border border-sky-200 bg-sky-50/60 p-3.5">
      <Field
        label="GCash number"
        placeholder="09XX XXX XXXX"
        inputMode="tel"
        value={number}
        error={errors?.number ?? undefined}
        onChange={(e) => onNumber(e.target.value)}
      />
      <Field
        label="Name on the GCash account"
        placeholder="e.g. Juan D. Cruz"
        value={name}
        error={errors?.name ?? undefined}
        onChange={(e) => onName(e.target.value)}
      />
      <p className="text-[12px] leading-relaxed text-sky-900/70">
        Buyers see this only after they place an order with you. FARMS does not take the payment.
        The buyer pays from their own GCash app and you confirm it in yours.
      </p>
    </div>
  )
}

/** Loads the farm's saved GCash details so the form can start filled in. */
export function useGcashDetails(active: boolean) {
  const [number, setNumber] = useState('')
  const [name, setName] = useState('')
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    if (!active) return
    let alive = true
    supabase.rpc('my_gcash_details').then(({ data }) => {
      if (!alive) return
      const d = data as { gcash_number: string | null; gcash_name: string | null } | null
      if (d?.gcash_number) {
        setNumber(d.gcash_number)
        setName(d.gcash_name ?? '')
        setSaved(true)
      }
    })
    return () => {
      alive = false
    }
  }, [active])

  return { number, name, setNumber, setName, saved }
}

export function checkGcashFields(number: string, name: string) {
  return { number: validateGcashNumber(number), name: validateGcashName(name) }
}

/* -------------------------------------------------------------------------- */
/*  Buyer: pick how to pay when ordering                                       */
/* -------------------------------------------------------------------------- */

export function BuyerPayPicker({
  cash,
  gcash,
  value,
  onChange,
}: {
  cash: boolean
  gcash: boolean
  value: PayMethod
  onChange(m: PayMethod): void
}) {
  const options: { m: PayMethod; icon: string; title: string; body: string }[] = []
  if (cash)
    options.push({ m: 'cash', icon: '💵', title: 'Cash', body: 'Pay when you receive your order.' })
  if (gcash)
    options.push({
      m: 'gcash',
      icon: '📱',
      title: 'GCash',
      body: "You'll get the farm's GCash number after you order.",
    })

  return (
    <div>
      <p className="label">How would you like to pay?</p>
      <div className="grid gap-2" role="radiogroup" aria-label="Payment method">
        {options.map((o) => {
          const on = value === o.m
          return (
            <button
              key={o.m}
              type="button"
              role="radio"
              aria-checked={on}
              onClick={() => onChange(o.m)}
              className={`flex items-center gap-3 rounded-xl border-2 p-3 text-left transition ${
                on ? 'border-brand-600 bg-brand-50' : 'border-soil-200 bg-white hover:border-soil-300'
              }`}
            >
              <span className="text-[22px] leading-none" aria-hidden>
                {o.icon}
              </span>
              <span className="flex-1">
                <span className="block text-[14px] font-bold text-soil-900">{o.title}</span>
                <span className="block text-[12px] leading-snug text-soil-600">{o.body}</span>
              </span>
              <span
                className={`h-4 w-4 shrink-0 rounded-full border-2 ${
                  on ? 'border-brand-600 bg-brand-600 ring-2 ring-white ring-inset' : 'border-soil-300'
                }`}
                aria-hidden
              />
            </button>
          )
        })}
      </div>
      {options.length === 1 && (
        <p className="mt-1.5 text-[12px] text-soil-500">
          This farm accepts {options[0].title === 'Cash' ? 'cash' : 'GCash'} only.
        </p>
      )}
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/*  One order's payment: instructions for the buyer, a record for the farm     */
/* -------------------------------------------------------------------------- */

interface PayInfo {
  method: PayMethod
  paid: boolean
  amount: number
  farm_name: string
  stage: string
  reference: string | null
  reference_at: string | null
  gcash_number: string | null
  gcash_name: string | null
}

export function OrderPaymentDialog({
  orderId,
  role,
  onClose,
  onChanged,
}: {
  orderId: string | null
  role: 'buyer' | 'owner'
  onClose(): void
  onChanged?(): void
}) {
  const [info, setInfo] = useState<PayInfo | null>(null)
  const [ref, setRef] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function load() {
    if (!orderId) return
    const { data, error: e } = await supabase.rpc('order_payment_info', { p_order_id: orderId })
    if (e) {
      toast.error(friendlyError(e))
      onClose()
      return
    }
    setInfo(data as PayInfo)
  }

  useEffect(() => {
    setInfo(null)
    setRef('')
    setError(null)
    if (orderId) load()
  }, [orderId])

  async function sendReference() {
    const err = validateGcashReference(ref)
    setError(err)
    if (err || !orderId) return
    setBusy(true)
    const { error: e } = await supabase.rpc('submit_gcash_reference', {
      p_order_id: orderId,
      p_reference: ref.replace(/\s/g, ''),
    })
    setBusy(false)
    if (e) {
      toast.error(friendlyError(e))
      return
    }
    toast.success('Reference sent to the farm')
    setRef('')
    await load()
    onChanged?.()
  }

  async function copy(text: string, what: string) {
    try {
      await navigator.clipboard.writeText(text)
      toast.success(`${what} copied`)
    } catch {
      toast.error('Could not copy. Select it and copy by hand.')
    }
  }

  const gcash = info?.method === 'gcash'

  return (
    <Dialog
      open={!!orderId}
      onClose={onClose}
      title="Payment"
      description={info ? `${PAY_LABEL[info.method]} · ${peso(info.amount)}` : undefined}
      footer={
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      }
    >
      {!info ? (
        <div className="py-6 text-center">
          <Spinner />
        </div>
      ) : (
        <div className="space-y-4">
          <div className="flex items-center justify-between rounded-xl bg-soil-50 px-4 py-3">
            <div>
              <p className="text-[12px] text-soil-500">Amount</p>
              <p className="num text-[20px] font-bold text-brand-700">{peso(info.amount)}</p>
            </div>
            {info.paid ? (
              <span className="chip bg-green-100 text-green-800">✓ Paid</span>
            ) : (
              <span className="chip bg-amber-100 text-amber-800">Not yet paid</span>
            )}
          </div>

          {!gcash && (
            <p className="text-[14px] leading-relaxed text-soil-700">
              {role === 'buyer'
                ? `Pay ${info.farm_name} in cash when you receive your order.`
                : 'The buyer will pay in cash. Mark the order as paid once you have the money.'}
            </p>
          )}

          {gcash && role === 'buyer' && !info.paid && (
            <>
              <div className="rounded-xl border-2 border-sky-200 bg-sky-50 p-4">
                <p className="text-[12px] font-semibold uppercase tracking-wide text-sky-900/70">
                  Step 1 · Send the exact amount to
                </p>
                <p className="mt-1.5 text-[16px] font-bold text-soil-900">{info.gcash_name}</p>
                <div className="mt-0.5 flex items-center gap-2">
                  <p className="num text-[20px] font-bold tracking-wide text-sky-900">
                    {info.gcash_number}
                  </p>
                  <button
                    type="button"
                    className="rounded-md border border-sky-300 bg-white px-2 py-1 text-[12px] font-semibold text-sky-800"
                    onClick={() => copy(info.gcash_number ?? '', 'Number')}
                  >
                    Copy
                  </button>
                </div>
                <p className="mt-2 text-[12px] leading-relaxed text-sky-900/70">
                  Open your GCash app, choose Send Money, and enter this number and{' '}
                  {peso(info.amount)}.
                </p>
              </div>

              <div>
                <p className="text-[12px] font-semibold uppercase tracking-wide text-soil-500">
                  Step 2 · Enter your reference number
                </p>
                {info.reference && (
                  <p className="mt-1.5 rounded-lg bg-green-50 px-3 py-2 text-[13px] text-green-900">
                    You sent reference <span className="num font-bold">{info.reference}</span>. The
                    farm will confirm it. Send a new one only if it was wrong.
                  </p>
                )}
                <div className="mt-2">
                  <Field
                    label="GCash reference number"
                    placeholder="From your GCash receipt"
                    value={ref}
                    error={error ?? undefined}
                    onChange={(e) => {
                      setRef(e.target.value)
                      setError(null)
                    }}
                  />
                </div>
                <button className="btn-primary mt-3 w-full" onClick={sendReference} disabled={busy}>
                  {busy ? 'Sending…' : info.reference ? 'Send a new reference' : 'Send reference'}
                </button>
              </div>
            </>
          )}

          {gcash && role === 'owner' && !info.paid && (
            <div className="rounded-xl border border-sky-200 bg-sky-50 p-4 text-[14px] leading-relaxed text-sky-900">
              {info.reference ? (
                <>
                  The buyer reports GCash reference{' '}
                  <span className="num font-bold">{info.reference}</span>. Open your GCash, check
                  that {peso(info.amount)} arrived under this reference, then mark the order as paid.
                </>
              ) : (
                <>The buyer has not sent a reference yet. Check your GCash before marking it paid.</>
              )}
            </div>
          )}

          {gcash && info.paid && info.reference && (
            <p className="text-[13px] text-soil-600">
              GCash reference <span className="num font-semibold">{info.reference}</span>
            </p>
          )}
        </div>
      )}
    </Dialog>
  )
}
