import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Field, SectionHeading, Spinner } from '@/components/ui'
import {
  friendlyError,
  normalisePhone,
  validateName,
  validatePhone,
  validateRequired,
} from '@/lib/validation'

export default function BuyerAccount() {
  const { profile, refresh } = useAuth()
  const [form, setForm] = useState<Record<string, string>>({})
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!profile) return
    setForm({
      name: profile.name ?? '',
      phone: profile.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile.phone ?? '',
      email: profile.email ?? '',
      company: profile.company ?? '',
      address: profile.address ?? '',
      city: profile.city ?? '',
      zip_code: profile.zip_code ?? '',
    })
  }, [profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    // Farm owners deliver to this address and call this number, so both are
    // required rather than optional.
    const next = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      address: validateRequired(form.address, 'Delivery address'),
      city: validateRequired(form.city, 'City or municipality'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    const normalised = normalisePhone(form.phone)!

    // Changing to a number already registered under this role must be blocked
    // here, not just by the database, so the person sees which field is wrong.
    if (normalised !== profile.phone && (await isPhoneTakenForRole(normalised, 'buyer'))) {
      const msg = 'This number is already registered as a Buyer. Use a different number.'
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    setBusy(true)
    const { error } = await supabase
      .from('profiles')
      .update({
        name: form.name.trim(),
        phone: normalised,
        email: form.email.trim() || null,
        company: form.company.trim() || null,
        address: form.address.trim(),
        city: form.city.trim(),
        zip_code: form.zip_code.trim(),
      })
      .eq('id', profile.id)
    setBusy(false)

    if (error) {
      const msg = /profiles_phone_role_key/.test(error.message)
        ? 'This number is already registered as a Buyer. Use a different number.'
        : friendlyError(error)
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    toast.success('Account saved')
    await refresh()
  }

  if (!profile) return <Spinner />

  return (
    <div className="space-y-6">
      <h1 className="text-[22px] font-bold">Account</h1>

      <AccountHeader subtitle={profile.company ?? 'Buyer'} />

      <form onSubmit={save} className="space-y-5" noValidate>
        <section>
          <SectionHeading>Your details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Full name" value={form.name ?? ''} error={errors.name} onChange={(e) => set('name', e.target.value)} />
            <Field
              label="Mobile number"
              type="tel"
              inputMode="tel"
              value={form.phone ?? ''}
              error={errors.phone}
              onChange={(e) => set('phone', e.target.value)}
            />
            <Field
              label="Email"
              type="email"
              placeholder="Needed for password resets"
              className="sm:col-span-2"
              value={form.email ?? ''}
              onChange={(e) => set('email', e.target.value)}
            />
          </div>
        </section>

        <section>
          <SectionHeading>Delivery details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Company name" className="sm:col-span-2" value={form.company ?? ''} onChange={(e) => set('company', e.target.value)} />
            <Field
              label="Delivery address"
              className="sm:col-span-2"
              placeholder="Purok / street, barangay"
              hint="Farm owners see this on a map when you order."
              value={form.address ?? ''}
              error={errors.address}
              onChange={(e) => set('address', e.target.value)}
            />
            <Field
              label="City or municipality"
              value={form.city ?? ''}
              error={errors.city}
              onChange={(e) => set('city', e.target.value)}
            />
            <Field label="ZIP code" inputMode="numeric" value={form.zip_code ?? ''} onChange={(e) => set('zip_code', e.target.value)} />
          </div>
        </section>

        <button className="btn-primary w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </form>
    </div>
  )
}
