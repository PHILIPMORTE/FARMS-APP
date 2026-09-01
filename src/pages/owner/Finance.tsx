import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Empty, Field, PesoInput, Select, Spinner, Stat } from '@/components/ui'
import { Link } from 'react-router-dom'
import { CROP_COLOR, CROP_EMOJI, peso, pesoShort, shortDate, titleCase, todayISO } from '@/lib/format'
import { friendlyError, validateAmount } from '@/lib/validation'
import type { Transaction, TxnType } from '@/lib/types'

const INCOME_CATEGORIES = ['Crop Sales', 'Livestock Sales', 'Government Subsidy', 'Other Income']
const EXPENSE_CATEGORIES = [
  'Labor',
  'Seeds',
  'Fertilizer',
  'Pesticides',
  'Equipment',
  'Fuel',
  'Water',
  'Electricity',
  'Other',
]

export default function OwnerFinance() {
  const { farm } = useAuth()
  const [rows, setRows] = useState<Transaction[] | null>(null)
  const [dialog, setDialog] = useState<TxnType | null>(null)

  async function load() {
    if (!farm) return
    const { data } = await supabase
      .from('transactions')
      .select('*')
      .eq('farm_id', farm.id)
      .order('date', { ascending: false })
      .order('created_at', { ascending: false })
    setRows((data as Transaction[]) ?? [])

  }

  useEffect(() => {
    load()
  }, [farm?.id])

  if (!rows) return <Spinner label="Loading your books" />

  const income = rows.filter((r) => r.type === 'income').reduce((s, r) => s + Number(r.amount), 0)
  const expenses = rows.filter((r) => r.type === 'expense').reduce((s, r) => s + Number(r.amount), 0)
  const net = income - expenses

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Finance</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Sales from the buyer market and costs from each planting flow in here automatically.
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-3">
        <Stat label="Total income" value={pesoShort(income)} accent="green" />
        <Stat label="Total expenses" value={pesoShort(expenses)} accent="red" />
        <Stat
          label="Net profit"
          value={pesoShort(net)}
          accent={net >= 0 ? 'green' : 'red'}
          sub={net >= 0 ? 'In the black' : 'Spending exceeds income'}
        />
      </div>

      <div className="grid gap-3 sm:grid-cols-[1fr_auto]">
        <div className="rounded-xl border border-soil-200 bg-white px-4 py-3.5">
          <p className="text-[13px] font-semibold text-soil-800">
            Costs are recorded on the crop they belong to
          </p>
          <p className="mt-0.5 text-[13px] leading-relaxed text-soil-600">
            Open a planting in the{' '}
            <Link to="/owner/calendar" className="font-semibold text-brand-700 hover:underline">
              Calendar
            </Link>{' '}
            and use Add cost, so seeds, fertilizer and labour count toward that crop's profit and
            are never entered twice.
          </p>
        </div>
        <button className="btn-primary self-start px-5 py-3" onClick={() => setDialog('income')}>
          Add other income
        </button>
      </div>

      {rows.length === 0 ? (
        <Empty
          title="No entries yet"
          body="Record what you earn and what you spend to see your net profit build up."
        />
      ) : (
        <ul className="card divide-y divide-soil-200/70">
          {rows.map((t) => (
            <li key={t.id} className="flex items-center justify-between gap-3 px-4 py-3.5">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={t.type === 'income' ? 'green' : 'red'}>{t.category}</Badge>
                  {t.crop && (
                    <span className={`chip ${CROP_COLOR[t.crop].chip}`}>
                      {CROP_EMOJI[t.crop]} {titleCase(t.crop)}
                    </span>
                  )}
                  <span className="text-[12px] text-soil-400">{shortDate(t.date)}</span>
                </div>
                {t.description && (
                  <p className="mt-1 truncate text-[13px] text-soil-600">{t.description}</p>
                )}
              </div>
              <span
                className={`num shrink-0 text-sm font-bold ${
                  t.type === 'income' ? 'text-green-700' : 'text-red-600'
                }`}
              >
                {t.type === 'income' ? '+' : '−'}
                {peso(t.amount)}
              </span>
            </li>
          ))}
        </ul>
      )}

      <TxnDialog
        type={dialog}
        farmId={farm?.id ?? ''}
        onClose={() => setDialog(null)}
        onSaved={() => {
          setDialog(null)
          load()
        }}
      />
    </div>
  )
}

function TxnDialog({
  type,
  farmId,
  onClose,
  onSaved,
}: {
  type: TxnType | null
  farmId: string
  onClose(): void
  onSaved(): void
}) {
  const isIncome = type !== 'expense'
  const categories = isIncome ? INCOME_CATEGORIES : EXPENSE_CATEGORIES

  const [form, setForm] = useState({
    category: categories[0],
    amount: '',
    description: '',
    date: todayISO(),
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (type) {
      setForm({
        category: (isIncome ? INCOME_CATEGORIES : EXPENSE_CATEGORIES)[0],
        amount: '',
        description: '',
        date: todayISO(),
      })
      setErrors({})
    }
  }, [type])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = { amount: validateAmount(form.amount, 'amount') }
    setErrors(next)
    if (next.amount) return

    setBusy(true)
    const { error } = await supabase.from('transactions').insert({
      farm_id: farmId,
      type,
      category: form.category,
      amount: Number(form.amount),
      description: form.description.trim(),
      date: form.date,
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(isIncome ? 'Income added' : 'Expense added')
    onSaved()
  }

  return (
    <Dialog
      open={type !== null}
      onClose={onClose}
      title={isIncome ? 'Add income' : 'Add expense'}
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className={isIncome ? 'btn-primary' : 'btn-danger'} onClick={submit} disabled={busy}>
            {busy ? 'Saving…' : isIncome ? 'Add income' : 'Add expense'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Category"
            value={form.category}
            onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
            options={categories.map((c) => ({ value: c, label: c }))}
          />
          <PesoInput
            label="Amount"
            placeholder="0.00"
            value={form.amount}
            error={errors.amount}
            onChange={(e) => setForm((f) => ({ ...f, amount: e.target.value }))}
          />
        </div>
        <div>
          <label className="label" htmlFor="txn-date">
            Date
          </label>
          <input
            id="txn-date"
            type="date"
            className="field num"
            value={form.date}
            onChange={(e) => setForm((f) => ({ ...f, date: e.target.value }))}
          />
        </div>
        <Field
          label="Description"
          placeholder="Optional note"
          value={form.description}
          onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
        />
      </form>
    </Dialog>
  )
}
