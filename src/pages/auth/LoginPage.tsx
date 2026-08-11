import { useEffect, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { useAuth } from '@/context/AuthContext'
import { PhoneField, SoftField, SoftPasswordField } from '@/components/ui'
import { ROLE_HOME, ROLE_LABEL } from '@/lib/format'
import type { Role } from '@/lib/types'
import { friendlyError, validateName, validatePassword, validatePhone } from '@/lib/validation'

/** Where the "other role" link at the foot of the card points. */
const NEXT_ROLE: Record<Role, { role: Role; label: string }> = {
  owner: { role: 'buyer', label: 'Log in as Buyer' },
  farmer: { role: 'buyer', label: 'Log in as Buyer' },
  buyer: { role: 'owner', label: 'Log in as Farm Owner' },
}

type Errors = Record<string, string | null>

export default function LoginPage({ role }: { role: Role }) {
  const { session, profile, signInWithPhone, registerWithPhone, signInWithGoogle, sendPasswordReset } =
    useAuth()
  const navigate = useNavigate()

  const [tab, setTab] = useState<'signin' | 'register'>('signin')
  const [busy, setBusy] = useState(false)
  const [errors, setErrors] = useState<Errors>({})
  const [form, setForm] = useState({ name: '', phone: '', password: '', confirm: '' })

  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    return () => document.documentElement.removeAttribute('data-role')
  }, [role])

  if (session && profile?.role === role) return <Navigate to={ROLE_HOME[role]} replace />

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    if (errors[k]) setErrors((e) => ({ ...e, [k]: null }))
  }

  function switchTab(next: 'signin' | 'register') {
    setTab(next)
    setErrors({})
  }

  async function onSignIn(e: React.FormEvent) {
    e.preventDefault()
    const next: Errors = {
      phone: validatePhone(form.phone),
      password: form.password ? null : 'Enter your password.',
    }
    setErrors(next)
    if (next.phone || next.password) return

    setBusy(true)
    try {
      await signInWithPhone(role, form.phone, form.password)
      toast.success(`Signed in as ${ROLE_LABEL[role]}`)
      navigate(ROLE_HOME[role], { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  async function onRegister(e: React.FormEvent) {
    e.preventDefault()
    const next: Errors = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      password: validatePassword(form.password),
      confirm: form.password !== form.confirm ? 'Both passwords must match.' : null,
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    try {
      await registerWithPhone(role, form.name.trim(), form.phone, form.password)
      toast.success(`${ROLE_LABEL[role]} account created`)
      navigate(ROLE_HOME[role], { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  async function onGoogle() {
    setBusy(true)
    try {
      await signInWithGoogle(role)
    } catch (err) {
      setErrors({ form: friendlyError(err) })
      setBusy(false)
    }
  }

  async function onForgot() {
    if (validatePhone(form.phone)) {
      setErrors({ phone: 'Enter your mobile number first, then tap Forgot password.' })
      return
    }
    try {
      await sendPasswordReset(form.phone)
      toast.success('Password reset link sent to the email on this account.')
    } catch (err) {
      toast.error(friendlyError(err))
    }
  }

  const other = NEXT_ROLE[role]

  return (
    <div className="auth-wash flex min-h-screen flex-col items-center justify-center px-5 py-10">
      <div className="w-full max-w-md">
        <div className="card animate-fade-up rounded-2xl p-7 shadow-lg sm:p-9">
          {/* Brand */}
          <div className="flex flex-col items-center text-center">
            <span className="flex h-16 w-16 items-center justify-center rounded-full bg-brand-600 text-white">
              <SproutIcon />
            </span>
            <h1 className="mt-4 text-[34px] font-extrabold leading-none tracking-tight">FARMS</h1>
            <p className="mt-2 text-[15px] text-soil-600">Farm Management System</p>
            <span className="mt-3 rounded-full bg-brand-50 px-3 py-1 text-[11px] font-bold uppercase tracking-wide text-brand-700">
              {ROLE_LABEL[role]}
            </span>
          </div>

          {/* Google first, as in the design */}
          <button onClick={onGoogle} className="btn-ghost mt-7 w-full py-3" disabled={busy}>
            <GoogleMark />
            Continue with Google
          </button>

          <div className="my-5 flex items-center gap-3">
            <span className="h-px flex-1 bg-soil-200" />
            <span className="text-[12px] font-semibold text-soil-400">OR</span>
            <span className="h-px flex-1 bg-soil-200" />
          </div>

          {/* Sign in / Create account */}
          <div role="tablist" className="grid grid-cols-2 gap-1 rounded-lg bg-soil-100 p-1">
            {(['signin', 'register'] as const).map((t) => (
              <button
                key={t}
                role="tab"
                aria-selected={tab === t}
                onClick={() => switchTab(t)}
                className={`rounded-md px-3 py-2 text-[13px] font-semibold transition ${
                  tab === t ? 'bg-white text-soil-900 shadow-sm' : 'text-soil-600 hover:text-soil-900'
                }`}
              >
                {t === 'signin' ? 'Sign in' : 'Create account'}
              </button>
            ))}
          </div>

          {errors.form && (
            <div
              role="alert"
              className="mt-4 rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-[13px] font-medium text-red-700"
            >
              {errors.form}
            </div>
          )}

          {tab === 'signin' ? (
            <form onSubmit={onSignIn} className="mt-5 space-y-4" noValidate>
              <PhoneField
                value={form.phone}
                error={errors.phone}
                onChange={(e) => set('phone', e.target.value)}
              />
              <SoftPasswordField
                label="Password"
                autoComplete="current-password"
                placeholder="Your password"
                value={form.password}
                error={errors.password}
                onChange={(e) => set('password', e.target.value)}
              />
              <button type="submit" className="btn-primary w-full py-3" disabled={busy}>
                {busy ? 'Signing in…' : `Sign In as ${ROLE_LABEL[role]}`}
              </button>
              <div className="text-center">
                <button
                  type="button"
                  onClick={onForgot}
                  className="text-[13px] font-semibold text-brand-700 hover:underline"
                >
                  Forgot password?
                </button>
              </div>
            </form>
          ) : (
            <form onSubmit={onRegister} className="mt-5 space-y-4" noValidate>
              <SoftField
                label="Full Name"
                autoComplete="name"
                placeholder="Juan dela Cruz"
                value={form.name}
                error={errors.name}
                onChange={(e) => set('name', e.target.value)}
              />
              <PhoneField
                value={form.phone}
                error={errors.phone}
                onChange={(e) => set('phone', e.target.value)}
              />
              <SoftPasswordField
                label="Password"
                autoComplete="new-password"
                placeholder="At least 8 characters"
                value={form.password}
                error={errors.password}
                onChange={(e) => set('password', e.target.value)}
              />
              <SoftPasswordField
                label="Confirm Password"
                autoComplete="new-password"
                placeholder="Type it again"
                value={form.confirm}
                error={errors.confirm}
                onChange={(e) => set('confirm', e.target.value)}
              />
              <button type="submit" className="btn-primary w-full py-3" disabled={busy}>
                {busy ? 'Creating account…' : `Create ${ROLE_LABEL[role]} Account`}
              </button>
            </form>
          )}

          <p className="mt-5 text-center text-[12px] leading-relaxed text-soil-400">
            The same mobile number can hold a separate account for each role.
          </p>
        </div>

        {/* Jump straight to another role's login */}
        <div className="mt-5 flex justify-center">
          <Link
            to={`/${other.role}/login`}
            className="inline-flex items-center gap-2 rounded-full bg-white px-5 py-2.5 text-[14px]
                       font-semibold text-soil-800 shadow-sm transition hover:shadow-md"
          >
            {other.label}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
              <path d="M5 12h13M13 6l6 6-6 6" />
            </svg>
          </Link>
        </div>

        <div className="mt-3 text-center">
          <Link to="/" className="text-[13px] font-medium text-soil-600 hover:text-soil-900">
            Choose a different role
          </Link>
        </div>
      </div>
    </div>
  )
}

function SproutIcon() {
  return (
    <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 21V11" />
      <path d="M12 11C12 7.5 9.5 5 6 5c0 3.5 2.5 6 6 6z" fill="currentColor" stroke="none" />
      <path d="M12 12c0-3.5 2.5-6 6-6 0 3.5-2.5 6-6 6z" fill="currentColor" stroke="none" />
    </svg>
  )
}

function GoogleMark() {
  return (
    <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden>
      <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.6l6.7-6.7C35.6 2.6 30.2 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.8 6.1C12.3 13.2 17.6 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.6 24.6c0-1.6-.1-3.2-.4-4.6H24v9.1h12.7c-.6 3-2.3 5.5-4.8 7.2l7.5 5.8c4.4-4.1 7.2-10.1 7.2-17.5z" />
      <path fill="#FBBC05" d="M10.4 28.7c-.5-1.5-.8-3-.8-4.7s.3-3.2.8-4.7l-7.8-6.1C1 16.4 0 20.1 0 24s1 7.6 2.6 10.8l7.8-6.1z" />
      <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.5-5.8c-2.1 1.4-4.8 2.3-8.4 2.3-6.4 0-11.7-3.7-13.6-9.8l-7.8 6.1C6.5 42.6 14.6 48 24 48z" />
    </svg>
  )
}
