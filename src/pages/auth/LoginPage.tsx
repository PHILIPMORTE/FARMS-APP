import { useEffect, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { Dialog } from '@/components/ui'
import { setActiveRole, useAuth } from '@/context/AuthContext'
import { ROLE_HOME, ROLE_LABEL } from '@/lib/format'
import type { Role } from '@/lib/types'
import { friendlyError, validateName, validatePassword, validatePhone } from '@/lib/validation'

const BLURB: Record<Role, string> = {
  owner: 'Manage your farm, crops, market listings and finances',
  farmer: 'Find farm work opportunities and apply for jobs',
  buyer: 'Browse and buy fresh farm products by the sack',
  admin: 'Verify accounts and oversee the whole system',
}

const NEXT_ROLE: Record<Role, { role: Role; label: string }> = {
  owner: { role: 'buyer', label: 'Log in as Buyer' },
  farmer: { role: 'buyer', label: 'Log in as Buyer' },
  buyer: { role: 'owner', label: 'Log in as Farm Owner' },
  admin: { role: 'owner', label: 'Log in as Farm Owner' },
}

type Errors = Record<string, string | null>

export default function LoginPage({ role }: { role: Role }) {
  const { session, profile, signOut, signInWithPhone, registerWithPhone, signInWithGoogle, sendPasswordReset } =
    useAuth()
  const navigate = useNavigate()

  const [tab, setTab] = useState<'signin' | 'register'>('signin')
  const [busy, setBusy] = useState(false)
  const [agreed, setAgreed] = useState(false)
  const [privacyOpen, setPrivacyOpen] = useState(false)
  const [errors, setErrors] = useState<Errors>({})
  const [form, setForm] = useState({ name: '', phone: '', password: '', confirm: '' })

  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    return () => document.documentElement.removeAttribute('data-role')
  }, [role])

  if (session && profile?.role === role) return <Navigate to={ROLE_HOME[role]} replace />

  if (session && !profile) {
    return (
      <div className="auth-wash flex min-h-screen items-center justify-center px-5">
        <div className="auth-card relative z-10 w-full max-w-sm rounded-2xl p-7 text-center">
          <h1 className="text-[18px] font-bold">You are still signed in</h1>
          <p className="mt-1.5 text-[14px] leading-relaxed text-soil-600">
            Continue into your {ROLE_LABEL[role]} account, or sign out to use a different one.
          </p>
          <button
            className="btn-primary mt-5 w-full"
            onClick={() => {
              setActiveRole(role)
              window.location.href = ROLE_HOME[role]
            }}
          >
            Continue as {ROLE_LABEL[role]}
          </button>
          <button
            className="btn-ghost mt-2 w-full"
            onClick={async () => {
              await signOut()
              window.location.reload()
            }}
          >
            Sign out
          </button>
        </div>
      </div>
    )
  }

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
    if (!agreed) {
      setErrors({ form: 'Please read and agree to the Data Privacy Notice first.' })
      return
    }
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
    if (tab === 'register' && !agreed) {
      setErrors({ form: 'Please read and agree to the Data Privacy Notice first.' })
      return
    }
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
    <div className="auth-wash flex min-h-screen flex-col px-5 py-6">
      <Link
        to="/"
        className="relative z-10 inline-flex w-fit items-center gap-2.5 rounded-lg border border-white/20
                   bg-white/10 px-3.5 py-2 text-[13px] font-semibold text-white backdrop-blur
                   transition hover:border-white/40 hover:bg-white/20"
      >
        <span className="flex h-6 w-6 items-center justify-center rounded-md bg-white/15 text-white">
          <SproutIcon size={14} />
        </span>
        FARMS
      </Link>

      <div className="relative z-10 flex flex-1 items-center justify-center py-8">
        <div className="w-full max-w-[26rem]">
          <div className="auth-card animate-fade-up rounded-3xl p-7 sm:p-9">
            <div className="flex flex-col items-center text-center">
              <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white text-brand-700 shadow-[0_4px_14px_-4px_rgba(16,24,40,.25)]">
                <SproutIcon size={26} />
              </span>

              <h1 className="mt-5 text-[26px] font-bold leading-tight tracking-tight">
                Sign in as {ROLE_LABEL[role]}
              </h1>
              <p className="mt-1.5 max-w-[19rem] text-[14px] leading-relaxed text-soil-600">
                {BLURB[role]}
              </p>
            </div>

            <div role="tablist" className="mt-6 grid grid-cols-2 gap-1 rounded-xl bg-white/70 p-1">
              {(['signin', 'register'] as const).map((t) => (
                <button
                  key={t}
                  role="tab"
                  aria-selected={tab === t}
                  onClick={() => switchTab(t)}
                  className={`rounded-lg px-3 py-2 text-[13px] font-semibold transition ${
                    tab === t
                      ? 'bg-white text-soil-900 shadow-sm'
                      : 'text-soil-500 hover:text-soil-900'
                  }`}
                >
                  {t === 'signin' ? 'Sign in' : 'Create account'}
                </button>
              ))}
            </div>

            {errors.form && (
              <div
                role="alert"
                className="mt-4 animate-fade-up rounded-xl border border-red-200 bg-red-50 px-3.5 py-2.5 text-[13px] font-medium text-red-700"
              >
                {errors.form}
              </div>
            )}

            {tab === 'signin' ? (
              <form onSubmit={onSignIn} className="mt-5 space-y-3" noValidate>
                <PhoneRow
                  value={form.phone}
                  error={errors.phone}
                  onChange={(v) => set('phone', v)}
                />
                <PasswordRow
                  value={form.password}
                  error={errors.password}
                  autoComplete="current-password"
                  placeholder="Password"
                  onChange={(v) => set('password', v)}
                />

                <div className="flex justify-end pt-0.5">
                  <button
                    type="button"
                    onClick={onForgot}
                    className="text-[13px] font-medium text-soil-600 hover:text-soil-900 hover:underline"
                  >
                    Forgot password?
                  </button>
                </div>

                <button type="submit" className="btn-dark mt-1" disabled={busy}>
                  {busy ? 'Signing in…' : 'Get Started'}
                </button>
              </form>
            ) : (
              <form onSubmit={onRegister} className="mt-5 space-y-3" noValidate>
                <IconRow
                  icon={<UserIcon />}
                  placeholder="Full name"
                  autoComplete="name"
                  value={form.name}
                  error={errors.name}
                  onChange={(v) => set('name', v)}
                />
                <PhoneRow
                  value={form.phone}
                  error={errors.phone}
                  onChange={(v) => set('phone', v)}
                />
                <PasswordRow
                  value={form.password}
                  error={errors.password}
                  autoComplete="new-password"
                  placeholder="Password (at least 8 characters)"
                  onChange={(v) => set('password', v)}
                />
                <PasswordRow
                  value={form.confirm}
                  error={errors.confirm}
                  autoComplete="new-password"
                  placeholder="Confirm password"
                  onChange={(v) => set('confirm', v)}
                />

                <div className="rounded-xl border border-soil-200 bg-white/70 p-3.5">
                  <button
                    type="button"
                    onClick={() => setPrivacyOpen(true)}
                    className="text-left text-[13px] font-semibold text-brand-700 hover:underline"
                  >
                    Read the Data Privacy Notice
                  </button>

                  <label className="mt-2 flex cursor-pointer items-start gap-2.5">
                    <input
                      type="checkbox"
                      checked={agreed}
                      onChange={(e) => setAgreed(e.target.checked)}
                      className="mt-0.5 h-4 w-4 shrink-0 rounded border-soil-300 text-brand-600
                                 focus:ring-2 focus:ring-brand-600/30"
                    />
                    <span className="text-[13px] leading-relaxed text-soil-700">
                      I have read and agree to the Data Privacy Notice.
                    </span>
                  </label>
                </div>

                <button type="submit" className="btn-dark mt-1" disabled={busy || !agreed}>
                  {busy ? 'Creating account…' : 'Create account'}
                </button>
              </form>
            )}

            <div className="my-5 flex items-center gap-3">
              <span className="dotted-rule h-px flex-1" />
              <span className="text-[12px] text-soil-400">Or sign in with</span>
              <span className="dotted-rule h-px flex-1" />
            </div>

            <button
              onClick={onGoogle}
              disabled={busy}
              className="flex w-full items-center justify-center gap-2.5 rounded-xl border border-soil-200
                         bg-white py-3 text-[14px] font-semibold text-soil-800 transition
                         hover:-translate-y-px hover:shadow-md disabled:opacity-50"
            >
              <GoogleMark />
              Google
            </button>
          </div>

          <div className="mt-5 flex flex-col items-center gap-2.5">
            <Link
              to={`/${other.role}/login`}
              className="inline-flex items-center gap-2 rounded-full bg-white px-5 py-2.5 text-[13px]
                         font-semibold text-soil-800 shadow-sm transition hover:-translate-y-px hover:shadow-md"
            >
              {other.label}
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
                <path d="M5 12h13M13 6l6 6-6 6" />
              </svg>
            </Link>
            <p className="text-center text-[12px] text-white/60">
              One mobile number can hold a separate account for each role.
            </p>
          </div>
        </div>
      </div>
      <PrivacyNotice open={privacyOpen} onClose={() => setPrivacyOpen(false)} />
    </div>
  )
}

function PrivacyNotice({ open, onClose }: { open: boolean; onClose(): void }) {
  if (!open) return null
  return (
    <Dialog
      open
      onClose={onClose}
      title="Data Privacy Notice"
      description="How FARMS handles your information"
      footer={
        <button className="btn-primary" onClick={onClose}>
          I understand
        </button>
      }
    >
      <div className="space-y-3 text-[14px] leading-relaxed text-soil-700">
        <p>
          FARMS collects your name, mobile number, and a photo of a valid ID so that an
          administrator can confirm you are a real person before your account is activated. Farm
          owners also give their farm name and location, and buyers give a delivery address.
        </p>
        <p>
          Your ID photo and selfie are stored privately. Only you and the system administrator can
          open them, and they are used solely to verify your identity.
        </p>
        <p>
          Other users see only what is needed to deal with you: your name, your mobile number when
          you have an active order or job together, and your rating. Nobody else sees your ID.
        </p>
        <p>
          Records of orders, work logs, and wages are kept as the shared account of what happened
          between you and the other party, so both sides can rely on them.
        </p>
        <p>
          You may ask the administrator to correct your details or to remove your account. This
          system is a student capstone project for Barangay Pagatban and is handled in line with
          the Data Privacy Act of 2012 (RA 10173).
        </p>
      </div>
    </Dialog>
  )
}

function IconRow({
  icon,
  error,
  onChange,
  ...props
}: {
  icon: React.ReactNode
  error?: string | null
  onChange(v: string): void
} & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'onChange'>) {
  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-soil-400">
          {icon}
        </span>
        <input
          className={`field-icon ${error ? 'border-red-300 bg-red-50/50' : ''}`}
          aria-invalid={!!error}
          onChange={(e) => onChange(e.target.value)}
          {...props}
        />
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

function PhoneRow({
  value,
  error,
  onChange,
}: {
  value: string
  error?: string | null
  onChange(v: string): void
}) {
  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 flex items-center gap-1.5">
          <PhoneIcon />
          <span className="text-[14px] font-semibold text-soil-500">+63</span>
        </span>
        <input
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          placeholder="917 123 4567"
          className={`field-icon pl-[5.2rem] ${error ? 'border-red-300 bg-red-50/50' : ''}`}
          aria-invalid={!!error}
          aria-label="Mobile number"
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
      </div>
      {error ? (
        <p className="err">{error}</p>
      ) : (
        <p className="mt-1 pl-1 text-[12px] text-soil-400">Your 10-digit mobile number</p>
      )}
    </div>
  )
}

function PasswordRow({
  value,
  error,
  placeholder,
  autoComplete,
  onChange,
}: {
  value: string
  error?: string | null
  placeholder: string
  autoComplete: string
  onChange(v: string): void
}) {
  const [shown, setShown] = useState(false)
  return (
    <div>
      <div className="relative">
        <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-soil-400">
          <LockIcon />
        </span>
        <input
          type={shown ? 'text' : 'password'}
          autoComplete={autoComplete}
          placeholder={placeholder}
          className={`field-icon pr-11 ${error ? 'border-red-300 bg-red-50/50' : ''}`}
          aria-invalid={!!error}
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
        <button
          type="button"
          onClick={() => setShown((v) => !v)}
          aria-label={shown ? 'Hide password' : 'Show password'}
          aria-pressed={shown}
          className="absolute right-3 top-1/2 -translate-y-1/2 text-soil-400 transition hover:text-soil-800"
        >
          {shown ? <EyeOffIcon /> : <EyeIcon />}
        </button>
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

const stroke = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.9,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

function UserIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" {...stroke}>
      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z" />
    </svg>
  )
}

function PhoneIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" {...stroke}>
      <rect x="6" y="2" width="12" height="20" rx="2.5" />
      <path d="M11 18.5h2" />
    </svg>
  )
}

function LockIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" {...stroke}>
      <rect x="4" y="10" width="16" height="11" rx="2.5" />
      <path d="M8 10V7a4 4 0 0 1 8 0v3" />
    </svg>
  )
}

function EyeIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" {...stroke}>
      <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  )
}

function EyeOffIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" {...stroke}>
      <path d="M10.6 6.2A9.9 9.9 0 0 1 12 6c6.4 0 10 6 10 6a17 17 0 0 1-3 3.6M6.5 7.8A17 17 0 0 0 2 12s3.6 6 10 6a9.6 9.6 0 0 0 4-.8" />
      <path d="M3 3l18 18" />
      <path d="M9.9 10.1a3 3 0 0 0 4.1 4.2" />
    </svg>
  )
}

function SproutIcon({ size = 26 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
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
