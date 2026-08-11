import { useEffect, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, setActiveRole } from '@/context/AuthContext'
import { Field, Spinner } from '@/components/ui'
import { Wordmark } from '@/components/AppShell'
import { ROLE_HOME, ROLE_LABEL } from '@/lib/format'
import type { Role } from '@/lib/types'
import { friendlyError, validateName, validatePhone } from '@/lib/validation'

/**
 * Where Google sends people back to. Google supplies a name and email but never
 * a Philippine mobile number, so a first-time user for this role finishes the
 * profile here before entering the app.
 */
export default function AuthCallback() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { completeGoogleProfile, refresh } = useAuth()

  const role = (params.get('role') as Role) ?? 'owner'
  const [checking, setChecking] = useState(true)
  const [googleEmail, setGoogleEmail] = useState('')
  const [form, setForm] = useState({ name: '', phone: '' })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    ;(async () => {
      const { data } = await supabase.auth.getSession()
      if (!data.session) {
        navigate(`/${role}/login`, { replace: true })
        return
      }
      setActiveRole(role)

      const { data: prof } = await supabase
        .from('profiles')
        .select('id')
        .eq('user_id', data.session.user.id)
        .eq('role', role)
        .maybeSingle()

      if (prof) {
        await refresh()
        navigate(ROLE_HOME[role], { replace: true })
        return
      }

      // First time in this role — prefill what Google gave us.
      const meta = data.session.user.user_metadata as { full_name?: string; name?: string }
      setGoogleEmail(data.session.user.email ?? '')
      setForm((f) => ({ ...f, name: meta.full_name ?? meta.name ?? '' }))
      setChecking(false)
    })()
  }, [role])

  /** Sign out and bounce back to the role's login so Google asks again. */
  async function switchAccount() {
    await supabase.auth.signOut()
    navigate(`/${role}/login`, { replace: true })
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    const next = { name: validateName(form.name), phone: validatePhone(form.phone) }
    setErrors(next)
    if (next.name || next.phone) return

    setBusy(true)
    try {
      await completeGoogleProfile(role, form.name.trim(), form.phone)
      toast.success(`${ROLE_LABEL[role]} account ready`)
      navigate(ROLE_HOME[role], { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  if (checking) return <Spinner label="Finishing sign in" />

  return (
    <div className="min-h-screen bg-soil-50">
      <div className="mx-auto max-w-md px-5 py-10">
        <Wordmark large />
        <p className="mt-1 text-[12px] font-bold uppercase tracking-[0.14em] text-brand-700">
          {ROLE_LABEL[role]}
        </p>
        <h1 className="mt-6 text-2xl font-bold">Finish your profile</h1>
        <p className="mt-2 text-[15px] leading-relaxed text-soil-600">
          Google does not share a mobile number. Add yours so farms and buyers can reach you.
        </p>

        {/* Show which account came back, so a wrong pick is caught before
            a profile is created against it. */}
        {googleEmail && (
          <div className="mt-4 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-soil-200 bg-white px-4 py-3">
            <span className="min-w-0">
              <span className="block text-[11px] font-semibold uppercase tracking-wide text-soil-400">
                Signed in with Google as
              </span>
              <span className="block truncate text-[14px] font-semibold">{googleEmail}</span>
            </span>
            <button
              type="button"
              onClick={switchAccount}
              className="text-[13px] font-semibold text-brand-700 hover:underline"
            >
              Use another account
            </button>
          </div>
        )}

        {errors.form && (
          <div role="alert" className="mt-5 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-700">
            {errors.form}
          </div>
        )}

        <form onSubmit={onSubmit} className="mt-6 space-y-4" noValidate>
          <Field
            label="Full name"
            value={form.name}
            error={errors.name}
            onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
          />
          <Field
            label="Mobile number"
            type="tel"
            inputMode="tel"
            placeholder="09171234567"
            value={form.phone}
            error={errors.phone}
            onChange={(e) => setForm((f) => ({ ...f, phone: e.target.value }))}
          />
          <button className="btn-primary w-full" disabled={busy}>
            {busy ? 'Saving…' : 'Enter FARMS'}
          </button>
        </form>
      </div>
    </div>
  )
}
