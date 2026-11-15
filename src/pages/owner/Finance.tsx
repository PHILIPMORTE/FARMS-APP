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

/** How many of the owner's own income entries can still be edited, newest first. */
const EDITABLE_INCOME_COUNT = 3

/**
 * Sales that come from buyer orders are booked by the system ("12 sacks of Dinorado sold to ...").
 * They mirror a real order, so they are never edited by hand. Everything else in income is
 * something the owner typed in.
 */
const isOrderSale = (t: Transaction) => t.category === 'Crop Sales' && / sold to /i.test(t.description ?? '')

export default function OwnerFinance() {
  const { farm } = useAuth()
  const [rows, setRows] = useState<Transaction[] | null>(null)
  const [dialog, setDialog] = useState<TxnType | null>(null)
  const [editing, setEditing] = useState<Transaction | null>(null)

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

  // The 3 income entries the owner added most recently. Add a new one and it takes a place,
  // while the oldest of the three loses its Edit button. Ranked by when it was added, not by
  // the date typed in, so an entry dated last week is still editable right after it is added.
  const editableIds = new Set(
    rows
      .filter((r) => r.type === 'income' && !isOrderSale(r))
      .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))
      .slice(0, EDITABLE_INCOME_COUNT)
      .map((r) => r.id),
  )

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Finance</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Sales from the buyer market and costs from each planting flow in here automatically.
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-3">
        <Stat label="Total sales" value={pesoShort(income)} accent="green" />
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
        <div className="flex flex-col gap-2 self-start">
          <button className="btn-primary px-5 py-3" onClick={() => setDialog('income')}>
            Add other income
          </button>
          <button
            className="btn px-5 py-3 bg-red-600 text-white hover:bg-red-700"
            onClick={() => setDialog('expense')}
          >
            Add expense
          </button>
        </div>
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
              <div className="flex shrink-0 items-center gap-3">
                <span
                  className={`num text-sm font-bold ${
                    t.type === 'income' ? 'text-green-700' : 'text-red-600'
                  }`}
                >
                  {t.type === 'income' ? '+' : '−'}
                  {peso(t.amount)}
                </span>
                {editableIds.has(t.id) && (
                  <button
                    type="button"
                    onClick={() => setEditing(t)}
                    aria-label={`Edit income of ${peso(t.amount)} on ${shortDate(t.date)}`}
                    className="inline-flex items-center gap-1 rounded-lg border border-soil-200 px-2.5 py-1.5
                               text-[12px] font-semibold text-soil-800 transition hover:bg-soil-50"
                  >
                    <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                      <path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z" />
                      <path d="M13.5 6.5l4 4" />
                    </svg>
                    Edit
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
      {editableIds.size > 0 && (
        <p className="-mt-3 text-[12px] text-soil-400">
          Edit is on the {EDITABLE_INCOME_COUNT} latest income entries you added. Sales from buyer orders are
          recorded by the system and cannot be edited.
        </p>
      )}

      <TxnDialog
        type={editing ? 'income' : dialog}
        editing={editing}
        farmId={farm?.id ?? ''}
        onClose={() => {
          setDialog(null)
          setEditing(null)
        }}
        onSaved={() => {
          setDialog(null)
          setEditing(null)
          load()
        }}
      />
    </div>
  )
}

function TxnDialog({
  type,
  editing,
  farmId,
  onClose,
  onSaved,
}: {
  type: TxnType | null
  editing: Transaction | null
  farmId: string
  onClose(): void
  onSaved(): void
}) {
  const isIncome = type !== 'expense'
  const baseCategories = isIncome ? INCOME_CATEGORIES : EXPENSE_CATEGORIES
  const categories =
    editing && !baseCategories.includes(editing.category) ? [editing.category, ...baseCategories] : baseCategories

  const [form, setForm] = useState({
    category: categories[0],
    amount: '',
    description: '',
    date: todayISO(),
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (editing) {
      setForm({
        category: editing.category,
        amount: String(editing.amount),
        description: editing.description ?? '',
        date: editing.date,
      })
      setErrors({})
    } else if (type) {
      setForm({
        category: (isIncome ? INCOME_CATEGORIES : EXPENSE_CATEGORIES)[0],
        amount: '',
        description: '',
        date: todayISO(),
      })
      setErrors({})
    }
  }, [type, editing?.id])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      amount:
        validateAmount(form.amount, 'amount') ??
        (Number(form.amount) > 0 ? null : 'Enter an amount greater than zero.'),
    }
    setErrors(next)
    if (next.amount) return

    setBusy(true)
    if (editing) {
      // Only this farm's own income row can be changed here.
      const { data, error } = await supabase
        .from('transactions')
        .update({
          category: form.category,
          amount: Number(form.amount),
          description: form.description.trim(),
          date: form.date,
        })
        .eq('id', editing.id)
        .eq('farm_id', farmId)
        .eq('type', 'income')
        .select('id')
      setBusy(false)

      if (error) {
        toast.error(friendlyError(error))
        return
      }
      if (!data || data.length === 0) {
        toast.error('That entry could not be changed. Reload the page and try again.')
        return
      }
      toast.success('Income updated')
      onSaved()
      return
    }

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
      title={editing ? 'Edit income' : isIncome ? 'Add income' : 'Add expense'}
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className={isIncome ? 'btn-primary' : 'btn-danger'} onClick={submit} disabled={busy}>
            {busy ? 'Saving…' : editing ? 'Save changes' : isIncome ? 'Add income' : 'Add expense'}
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
