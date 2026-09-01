import { useEffect, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { useAuth } from '@/context/AuthContext'
import { ROLE_HOME } from '@/lib/format'
import { friendlyError, validatePhone } from '@/lib/validation'

const line = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

export default function AdminLoginPage() {
  const { session, profile, signInWithPhone, signInWithGoogle } = useAuth()
  const navigate = useNavigate()

  const [phone, setPhone] = useState('')
  const [password, setPassword] = useState('')
  const [shown, setShown] = useState(false)
  const [busy, setBusy] = useState(false)
  const [errors, setErrors] = useState<Record<string, string | null>>({})

  useEffect(() => {
    document.documentElement.setAttribute('data-role', 'admin')
    return () => document.documentElement.removeAttribute('data-role')
  }, [])

  if (session && profile?.role === 'admin') return <Navigate to={ROLE_HOME.admin} replace />

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      phone: validatePhone(phone),
      password: password ? null : 'Enter your password.',
    }
    setErrors(next)
    if (next.phone || next.password) return

    setBusy(true)
    try {
      await signInWithPhone('admin', phone, password)
      toast.success('Signed in as Administrator')
      navigate(ROLE_HOME.admin, { replace: true })
    } catch (err) {
      setErrors({ form: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  async function onGoogle() {
    setBusy(true)
    try {
      await signInWithGoogle('admin')
    } catch (err) {
      setErrors({ form: friendlyError(err) })
      setBusy(false)
    }
  }

  return (
    <div className="admin-login flex min-h-screen items-center justify-center px-5 py-10">
      <div className="w-full max-w-[24rem]">
        <div className="admin-card relative animate-fade-up overflow-hidden rounded-2xl">
          <div className="relative z-10 px-8 pt-9">
            <div className="flex flex-col items-center text-center">
              <span className="flex h-14 w-14 items-center justify-center rounded-xl bg-white/10 text-white ring-1 ring-white/15">
                <svg viewBox="0 0 24 24" className="h-7 w-7" {...line}>
                  <path d="M12 3l8 3.5v5c0 5-3.4 9.3-8 10.5C7.4 20.8 4 16.5 4 11.5v-5z" />
                  <path d="M9 12l2.2 2.2L15.5 10" />
                </svg>
              </span>

              <h1 className="mt-5 text-[20px] font-bold uppercase tracking-[0.14em] text-white">
                Admin Panel
              </h1>
              <p className="mt-1 text-[13px] text-white/45">FARMS control panel login</p>
            </div>

            {errors.form && (
              <div
                role="alert"
                className="mt-6 rounded-lg border border-red-400/30 bg-red-500/15 px-3.5 py-2.5 text-[13px] font-medium text-red-200"
              >
                {errors.form}
              </div>
            )}

            <form onSubmit={onSubmit} className="mt-7 space-y-5" noValidate>
              <div>
                <div className="flex items-center gap-3 border-b border-white/20 pb-2 transition focus-within:border-white/60">
                  <span className="text-blue-400">
                    <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
                      <circle cx="12" cy="7" r="4" />
                    </svg>
                  </span>
                  <span className="text-[14px] font-medium text-white/40">+63</span>
                  <input
                    type="tel"
                    inputMode="tel"
                    autoComplete="tel"
                    placeholder="917 123 4567"
                    aria-label="Mobile number"
                    aria-invalid={!!errors.phone}
                    value={phone}
                    onChange={(e) => {
                      setPhone(e.target.value)
                      setErrors((x) => ({ ...x, phone: null }))
                    }}
                    className="w-full bg-transparent text-[15px] text-white placeholder:text-white/25 focus:outline-none"
                  />
                </div>
                {errors.phone && (
                  <p className="mt-1.5 text-[12px] font-medium text-red-300">{errors.phone}</p>
                )}
              </div>

              <div>
                <div className="flex items-center gap-3 border-b border-white/20 pb-2 transition focus-within:border-white/60">
                  <span className="text-blue-400">
                    <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                      <circle cx="8" cy="14" r="4" />
                      <path d="M11 12l8-8 2 2-2 2 2 2-3 3-2-2-2 2" />
                    </svg>
                  </span>
                  <input
                    type={shown ? 'text' : 'password'}
                    autoComplete="current-password"
                    placeholder="Password"
                    aria-invalid={!!errors.password}
                    value={password}
                    onChange={(e) => {
                      setPassword(e.target.value)
                      setErrors((x) => ({ ...x, password: null }))
                    }}
                    className="w-full bg-transparent text-[15px] text-white placeholder:text-white/25 focus:outline-none"
                  />
                  <button
                    type="button"
                    onClick={() => setShown((v) => !v)}
                    aria-label={shown ? 'Hide password' : 'Show password'}
                    className="shrink-0 text-white/35 transition hover:text-white/80"
                  >
                    {shown ? (
                      <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                        <path d="M10.6 6.2A9.9 9.9 0 0 1 12 6c6.4 0 10 6 10 6a17 17 0 0 1-3 3.6M6.5 7.8A17 17 0 0 0 2 12s3.6 6 10 6a9.6 9.6 0 0 0 4-.8" />
                        <path d="M3 3l18 18" />
                      </svg>
                    ) : (
                      <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" {...line}>
                        <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7z" />
                        <circle cx="12" cy="12" r="3" />
                      </svg>
                    )}
                  </button>
                </div>
                {errors.password && (
                  <p className="mt-1.5 text-[12px] font-medium text-red-300">{errors.password}</p>
                )}
              </div>

              <button
                type="submit"
                disabled={busy}
                className="mt-2 w-full rounded-full bg-amber-400 py-3 text-[15px] font-bold text-slate-900
                           shadow-[0_6px_18px_-6px_rgba(251,191,36,.7)] transition
                           hover:-translate-y-px hover:bg-amber-300 disabled:opacity-50"
              >
                {busy ? 'Signing in…' : 'Login'}
              </button>
            </form>

            <button
              onClick={onGoogle}
              disabled={busy}
              className="mt-4 flex w-full items-center justify-center gap-2.5 rounded-full border border-white/15
                         py-2.5 text-[13px] font-semibold text-white/70 transition
                         hover:border-white/35 hover:bg-white/5 hover:text-white disabled:opacity-50"
            >
              <svg width="15" height="15" viewBox="0 0 48 48" aria-hidden>
                <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.6l6.7-6.7C35.6 2.6 30.2 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.8 6.1C12.3 13.2 17.6 9.5 24 9.5z" />
                <path fill="#4285F4" d="M46.6 24.6c0-1.6-.1-3.2-.4-4.6H24v9.1h12.7c-.6 3-2.3 5.5-4.8 7.2l7.5 5.8c4.4-4.1 7.2-10.1 7.2-17.5z" />
                <path fill="#FBBC05" d="M10.4 28.7c-.5-1.5-.8-3-.8-4.7s.3-3.2.8-4.7l-7.8-6.1C1 16.4 0 20.1 0 24s1 7.6 2.6 10.8l7.8-6.1z" />
                <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.5-5.8c-2.1 1.4-4.8 2.3-8.4 2.3-6.4 0-11.7-3.7-13.6-9.8l-7.8 6.1C6.5 42.6 14.6 48 24 48z" />
              </svg>
              Continue with Google
            </button>
          </div>

          <svg
            className="relative z-0 -mt-10 block w-full"
            viewBox="0 0 400 150"
            preserveAspectRatio="none"
            aria-hidden
          >
            <path
              d="M0 92c48-30 96 6 144-4s96-52 144-30 76 34 112 22v70H0z"
              fill="#1e3a8a"
              opacity="0.55"
            />
            <path
              d="M0 108c52-24 88 10 140 2s92-40 140-24 84 30 120 20v44H0z"
              fill="#2547a8"
              opacity="0.8"
            />
            <path d="M0 124c56-20 96 8 148 0s96-30 148-16 76 20 104 14v28H0z" fill="#3b62e8" />
          </svg>
        </div>

        <div className="mt-6 flex flex-col items-center gap-2 text-center">
          <Link
            to="/admin/request"
            className="text-[13px] font-medium text-white/55 transition hover:text-white"
          >
            Need administrator access? Request it
          </Link>
          <Link
            to="/"
            className="text-[13px] font-medium text-white/40 transition hover:text-white/80"
          >
            Back to role selection
          </Link>
        </div>
      </div>
    </div>
  )
}
