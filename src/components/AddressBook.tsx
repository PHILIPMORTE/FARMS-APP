import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Field, Select, SectionHeading, Spinner, TextArea } from '@/components/ui'
import { PurokSelect, usePuroks } from '@/components/PurokSelect'
import type { Purok } from '@/components/PurokSelect'
import {
  displayPhone,
  friendlyError,
  validateName,
  validatePhone,
  validateRequired,
  validateSpecify,
} from '@/lib/validation'
import { OTHER, SpecifyField } from '@/components/SpecifyField'
import type { BuyerAddress } from '@/lib/types'

/** Where a new address starts. The buyer can change every part. */
const START_PLACE = { province: 'Negros Oriental', city: 'Bayawan City', barangay: 'Pagatban' }

const LABEL_TONE: Record<string, 'brand' | 'blue' | 'grey'> = {
  Home: 'brand',
  Work: 'blue',
}

/** The name the buyer typed for "Other" (like Mom's house) is shown as it is, in grey. */
const labelTone = (label: string) => LABEL_TONE[label] ?? 'grey'

const PRESET_LABELS = ['Home', 'Work']

/** "Blk 2 Lot 5, Purok 3, Pagatban, Bayawan City, Negros Oriental" */
export function addressLine(
  a: Pick<BuyerAddress, 'street' | 'barangay' | 'city' | 'province' | 'purok_id'>,
  puroks: Purok[],
): string {
  const purok = puroks.find((p) => p.id === a.purok_id)?.name
  return [a.street, purok, a.barangay, a.city, a.province].filter(Boolean).join(', ')
}

/** The buyer's saved addresses, default first. */
export function useBuyerAddresses() {
  const { profile } = useAuth()
  const [list, setList] = useState<BuyerAddress[] | null>(null)

  const reload = useCallback(async () => {
    if (!profile) return
    const { data } = await supabase
      .from('buyer_addresses')
      .select('*')
      .eq('profile_id', profile.id)
      .order('is_default', { ascending: false })
      .order('created_at', { ascending: false })
    setList((data as BuyerAddress[]) ?? [])
  }, [profile?.id])

  useEffect(() => {
    reload()
  }, [reload])

  return { list, reload }
}

/* -------------------------------------------------------------------------- */
/*  Add / edit one address                                                     */
/* -------------------------------------------------------------------------- */

interface FormState {
  /** Home, Work, or Other. When it is Other, `otherLabel` says what. */
  label: string
  otherLabel: string
  name: string
  phone: string
  province: string
  city: string
  barangay: string
  purok_id: string
  street: string
  note: string
  makeDefault: boolean
}

export function AddressFormDialog({
  open,
  editing,
  isFirst,
  onClose,
  onSaved,
}: {
  open: boolean
  editing: BuyerAddress | null
  /** True when the buyer has no address yet; the first one is always the default. */
  isFirst: boolean
  onClose(): void
  onSaved(id: string): void
}) {
  const { profile } = useAuth()
  const [form, setForm] = useState<FormState | null>(null)
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!open) return
    setErrors({})
    if (editing) {
      // A label that is not Home or Work is one the buyer typed, so it opens as Other with
      // that text in the box. An older address that says only "Other" opens with an empty
      // box, so the buyer can say what it is.
      const custom = !PRESET_LABELS.includes(editing.label)
      setForm({
        label: custom ? OTHER : editing.label,
        otherLabel: custom && editing.label !== OTHER ? editing.label : '',
        name: editing.recipient_name,
        phone: editing.phone.startsWith('+63') ? `0${editing.phone.slice(3)}` : editing.phone,
        province: editing.province,
        city: editing.city,
        barangay: editing.barangay,
        purok_id: editing.purok_id ?? '',
        street: editing.street,
        note: editing.note ?? '',
        makeDefault: editing.is_default,
      })
    } else {
      setForm({
        label: 'Home',
        otherLabel: '',
        name: profile?.name ?? '',
        phone: profile?.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile?.phone ?? '',
        province: profile?.province?.trim() || START_PLACE.province,
        city: profile?.city?.trim() || START_PLACE.city,
        barangay: START_PLACE.barangay,
        purok_id: '',
        street: '',
        note: '',
        makeDefault: isFirst,
      })
    }
  }, [open, editing?.id])

  if (!form) return <Dialog open={false} onClose={onClose} title="">{null}</Dialog>

  const set = <K extends keyof FormState>(k: K, v: FormState[K]) => {
    setForm((f) => (f ? { ...f, [k]: v } : f))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  const lockedDefault = isFirst || !!editing?.is_default

  async function save() {
    if (!form) return
    const next = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      province: validateRequired(form.province, 'Province'),
      city: validateRequired(form.city, 'City or municipality'),
      barangay: validateRequired(form.barangay, 'Barangay'),
      street:
        form.street.trim().length >= 3
          ? null
          : 'Enter the street, house number or a landmark so the farm can find you.',
      otherLabel:
        form.label === OTHER ? validateSpecify(form.otherLabel, 'a name for this address, like Mom’s house') : null,
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    const { data, error } = await supabase.rpc('save_buyer_address', {
      p_id: editing?.id ?? null,
      // What the buyer typed is the label, so it never reads just "Other".
      p_label: form.label === OTHER ? form.otherLabel.trim() : form.label,
      p_name: form.name.trim(),
      p_phone: form.phone,
      p_province: form.province.trim(),
      p_city: form.city.trim(),
      p_barangay: form.barangay.trim(),
      p_purok_id: form.purok_id || null,
      p_street: form.street.trim(),
      p_note: form.note.trim(),
      p_default: lockedDefault ? true : form.makeDefault,
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(editing ? 'Address updated' : 'Address saved')
    onSaved(data as string)
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={editing ? 'Edit address' : 'New address'}
      description="The farm uses this to know where to deliver your order."
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="btn-primary" onClick={save} disabled={busy}>
            {busy ? 'Saving…' : 'Save address'}
          </button>
        </>
      }
    >
      <form
        className="space-y-4"
        noValidate
        onSubmit={(e) => {
          e.preventDefault()
          save()
        }}
      >
        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            label="Full name"
            placeholder="Who receives the order"
            value={form.name}
            error={errors.name}
            onChange={(e) => set('name', e.target.value)}
          />
          <Field
            label="Mobile number"
            type="tel"
            inputMode="tel"
            placeholder="09171234567"
            value={form.phone}
            error={errors.phone}
            onChange={(e) => set('phone', e.target.value)}
          />
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            label="Province"
            value={form.province}
            error={errors.province}
            onChange={(e) => set('province', e.target.value)}
          />
          <Field
            label="City or municipality"
            value={form.city}
            error={errors.city}
            onChange={(e) => set('city', e.target.value)}
          />
          <Field
            label="Barangay"
            value={form.barangay}
            error={errors.barangay}
            onChange={(e) => set('barangay', e.target.value)}
          />
          <PurokSelect
            label="Purok (optional)"
            value={form.purok_id}
            onChange={(id) => set('purok_id', id)}
          />
        </div>

        <Field
          label="Street, house number or landmark"
          placeholder="e.g. Blk 2 Lot 5, beside the chapel"
          value={form.street}
          error={errors.street}
          onChange={(e) => set('street', e.target.value)}
        />

        <TextArea
          label="Note for the farm (optional)"
          max={200}
          rows={2}
          placeholder="e.g. Blue gate, call when you arrive"
          value={form.note}
          onChange={(e) => set('note', e.target.value)}
        />

        <Select
          label="Label as"
          value={form.label}
          onChange={(e) => set('label', e.target.value)}
          options={[
            { value: 'Home', label: 'Home' },
            { value: 'Work', label: 'Work' },
            { value: OTHER, label: 'Other' },
          ]}
        />
        {form.label === OTHER && (
          <SpecifyField
            label="Name this address"
            placeholder="e.g. Mom’s house, Farm stall"
            max={30}
            value={form.otherLabel}
            error={errors.otherLabel}
            onChange={(v) => set('otherLabel', v)}
          />
        )}

        <label className="flex items-center gap-2.5 text-[14px]">
          <input
            type="checkbox"
            className="h-4 w-4 rounded border-soil-300 text-brand-600"
            checked={lockedDefault ? true : form.makeDefault}
            disabled={lockedDefault}
            onChange={(e) => set('makeDefault', e.target.checked)}
          />
          <span>
            Use as my default address
            {lockedDefault && <span className="text-soil-400"> (it is your default now)</span>}
          </span>
        </label>
      </form>
    </Dialog>
  )
}

/* -------------------------------------------------------------------------- */
/*  One address, shown the same way everywhere                                 */
/* -------------------------------------------------------------------------- */

function AddressText({ a, puroks }: { a: BuyerAddress; puroks: Purok[] }) {
  return (
    <>
      <div className="flex flex-wrap items-center gap-1.5">
        <Badge tone={labelTone(a.label)}>{a.label}</Badge>
        {a.is_default && <Badge tone="green">Default</Badge>}
      </div>
      <p className="mt-1.5 text-[14px] font-bold">
        {a.recipient_name} <span className="num font-normal text-soil-600">· {displayPhone(a.phone)}</span>
      </p>
      <p className="mt-0.5 text-[13px] leading-relaxed text-soil-600">{addressLine(a, puroks)}</p>
      {a.note && <p className="mt-0.5 text-[12px] italic text-soil-400">Note: {a.note}</p>}
    </>
  )
}

/* -------------------------------------------------------------------------- */
/*  Account page: the buyer's address book                                     */
/* -------------------------------------------------------------------------- */

export function AddressBookSection() {
  const { list, reload } = useBuyerAddresses()
  const puroks = usePuroks()
  const [form, setForm] = useState<{ editing: BuyerAddress | null } | null>(null)
  const [deleting, setDeleting] = useState<BuyerAddress | null>(null)
  const [busy, setBusy] = useState(false)

  async function makeDefault(a: BuyerAddress) {
    const { error } = await supabase.rpc('set_default_buyer_address', { p_id: a.id })
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Default address changed')
    reload()
  }

  async function remove() {
    if (!deleting) return
    setBusy(true)
    const { error } = await supabase.rpc('delete_buyer_address', { p_id: deleting.id })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Address deleted')
    setDeleting(null)
    reload()
  }

  return (
    <section>
      <SectionHeading
        action={
          list && list.length < 10 ? (
            <button
              type="button"
              onClick={() => setForm({ editing: null })}
              className="text-[13px] font-semibold text-brand-700 hover:underline"
            >
              + Add new address
            </button>
          ) : undefined
        }
      >
        My delivery addresses
      </SectionHeading>

      {list === null ? (
        <Spinner />
      ) : list.length === 0 ? (
        <div className="card flex flex-col items-center px-6 py-8 text-center">
          <h3 className="text-[15px] font-bold">No address yet</h3>
          <p className="mt-1 max-w-sm text-[13px] text-soil-600">
            Add where you want your orders delivered. You pick one each time you order, and the farm
            sees it.
          </p>
          <button type="button" className="btn-primary mt-4" onClick={() => setForm({ editing: null })}>
            Add delivery address
          </button>
        </div>
      ) : (
        <ul className="space-y-3">
          {list.map((a) => (
            <li key={a.id} className="card p-4">
              <AddressText a={a} puroks={puroks} />
              <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[13px] font-semibold">
                <button
                  type="button"
                  className="text-brand-700 hover:underline"
                  onClick={() => setForm({ editing: a })}
                  aria-label={`Edit ${a.label} address`}
                >
                  Edit
                </button>
                {!a.is_default && (
                  <button type="button" className="text-brand-700 hover:underline" onClick={() => makeDefault(a)}>
                    Set as default
                  </button>
                )}
                <button
                  type="button"
                  className="text-red-600 hover:underline"
                  onClick={() => setDeleting(a)}
                  aria-label={`Delete ${a.label} address`}
                >
                  Delete
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      <AddressFormDialog
        open={form !== null}
        editing={form?.editing ?? null}
        isFirst={(list?.length ?? 0) === 0}
        onClose={() => setForm(null)}
        onSaved={() => {
          setForm(null)
          reload()
        }}
      />

      <Dialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        title="Delete this address?"
        footer={
          <>
            <button type="button" className="btn-ghost" onClick={() => setDeleting(null)}>
              Keep it
            </button>
            <button type="button" className="btn-danger" onClick={remove} disabled={busy}>
              {busy ? 'Deleting…' : 'Delete'}
            </button>
          </>
        }
      >
        <p className="text-[14px] leading-relaxed text-soil-700">
          Orders you already placed keep the address they were sent to.
        </p>
      </Dialog>
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/*  Checkout: "Deliver to"                                                     */
/* -------------------------------------------------------------------------- */

export function DeliveryPicker({
  list,
  value,
  onChange,
  onAdd,
  onEdit,
}: {
  list: BuyerAddress[] | null
  value: string | null
  onChange(id: string): void
  onAdd(): void
  onEdit(a: BuyerAddress): void
}) {
  const puroks = usePuroks()
  const [choosing, setChoosing] = useState(false)

  if (list === null) {
    return (
      <div className="rounded-xl border border-soil-200 px-4 py-4 text-[13px] text-soil-400">
        Loading your addresses…
      </div>
    )
  }

  if (list.length === 0) {
    return (
      <div className="rounded-xl border-2 border-dashed border-amber-300 bg-amber-50 px-4 py-4">
        <p className="text-[14px] font-bold text-amber-900">Where should we deliver this?</p>
        <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
          Add a delivery address first. The farm will see it on your order.
        </p>
        <button type="button" className="btn-primary mt-3 w-full" onClick={onAdd}>
          Add delivery address
        </button>
      </div>
    )
  }

  const chosen = list.find((a) => a.id === value) ?? null

  return (
    <div>
      <div className="flex items-center justify-between">
        <p className="label !mb-0">Deliver to</p>
        <button
          type="button"
          className="text-[13px] font-semibold text-brand-700 hover:underline"
          onClick={() => setChoosing((v) => !v)}
          aria-expanded={choosing}
        >
          {choosing ? 'Done' : 'Change'}
        </button>
      </div>

      {!choosing && chosen && (
        <div className="mt-1.5 rounded-xl border-2 border-brand-600 bg-brand-50 p-3.5">
          <AddressText a={chosen} puroks={puroks} />
        </div>
      )}

      {!choosing && !chosen && (
        <p className="mt-1.5 rounded-xl bg-amber-50 px-3.5 py-3 text-[13px] text-amber-800">
          Choose where this order goes.
        </p>
      )}

      {choosing && (
        <div className="mt-1.5 space-y-2" role="radiogroup" aria-label="Delivery address">
          {list.map((a) => {
            const on = a.id === value
            return (
              <div
                key={a.id}
                className={`rounded-xl border-2 p-3.5 transition ${
                  on ? 'border-brand-600 bg-brand-50' : 'border-soil-200 bg-white hover:border-soil-300'
                }`}
              >
                <button
                  type="button"
                  role="radio"
                  aria-checked={on}
                  className="block w-full text-left"
                  onClick={() => {
                    onChange(a.id)
                    setChoosing(false)
                  }}
                >
                  <AddressText a={a} puroks={puroks} />
                </button>
                <button
                  type="button"
                  className="mt-2 text-[12px] font-semibold text-brand-700 hover:underline"
                  onClick={() => onEdit(a)}
                >
                  Edit
                </button>
              </div>
            )
          })}
          {list.length < 10 && (
            <button
              type="button"
              className="w-full rounded-xl border-2 border-dashed border-soil-300 px-3.5 py-3 text-[13px] font-semibold text-brand-700 hover:bg-soil-50"
              onClick={onAdd}
            >
              + Add new address
            </button>
          )}
        </div>
      )}
    </div>
  )
}
