import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Field, SectionHeading, Spinner } from '@/components/ui'
import { friendlyError, normalisePhone, validateName, validatePhone } from '@/lib/validation'

export default function OwnerAccount() {
  const { profile, farm, refresh } = useAuth()
  const [form, setForm] = useState<Record<string, string>>({})
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!profile) return
    setForm({
      name: profile.name ?? '',
      phone: profile.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile.phone ?? '',
      email: profile.email ?? '',
      farm_name: farm?.name ?? '',
      address: farm?.address ?? '',
      city: farm?.city ?? '',
      province: farm?.province ?? '',
      zip_code: farm?.zip_code ?? '',
    })
  }, [profile?.id, farm?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile || !farm) return

    const next = { name: validateName(form.name), phone: validatePhone(form.phone) }
    setErrors(next)
    if (next.name || next.phone) return

    const normalised = normalisePhone(form.phone)!

    if (normalised !== profile.phone && (await isPhoneTakenForRole(normalised, 'owner'))) {
      const msg = 'This number is already registered as a Farm Owner. Use a different number.'
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    setBusy(true)
    const [p, f] = await Promise.all([
      supabase
        .from('profiles')
        .update({
          name: form.name.trim(),
          phone: normalised,
          email: form.email.trim() || null,
        })
        .eq('id', profile.id),
      supabase
        .from('farms')
        .update({
          name: form.farm_name.trim() || 'My Farm',
          address: form.address.trim(),
          city: form.city.trim(),
          province: form.province.trim(),
          zip_code: form.zip_code.trim(),
        })
        .eq('id', farm.id),
    ])
    setBusy(false)

    const err = p.error ?? f.error
    if (err) {
      const msg = /profiles_phone_role_key/.test(err.message)
        ? 'This number is already registered as a Farm Owner. Use a different number.'
        : friendlyError(err)
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

      <AccountHeader subtitle={farm?.name} />

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
          <SectionHeading>Your farm</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Farm name" className="sm:col-span-2" value={form.farm_name ?? ''} onChange={(e) => set('farm_name', e.target.value)} />
            <Field label="Address" className="sm:col-span-2" value={form.address ?? ''} onChange={(e) => set('address', e.target.value)} />
            <Field label="City or municipality" value={form.city ?? ''} onChange={(e) => set('city', e.target.value)} />
            <Field label="Province" value={form.province ?? ''} onChange={(e) => set('province', e.target.value)} />
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
