import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Field, SectionHeading, Spinner } from '@/components/ui'
import { AddressBookSection } from '@/components/AddressBook'
import {
  friendlyError,
  normalisePhone,
  validateEmail,
  validateName,
  validatePhone,
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
    })
  }, [profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    const next = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      email: validateEmail(form.email ?? ''),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    const normalised = normalisePhone(form.phone)!

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
              placeholder="For password resets and email notices"
              className="sm:col-span-2"
              value={form.email ?? ''}
              error={errors.email}
              onChange={(e) => set('email', e.target.value)}
            />
            <Field
              label="Company name (optional)"
              placeholder="e.g. your rice mill or store"
              className="sm:col-span-2"
              value={form.company ?? ''}
              onChange={(e) => set('company', e.target.value)}
            />
          </div>
        </section>

        <button className="btn-primary w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </form>

      <AddressBookSection />
    </div>
  )
}
