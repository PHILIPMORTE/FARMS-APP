import { useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import { Dialog, Field, PasswordField, Spinner } from '@/components/ui'
import { friendlyError, validatePassword } from '@/lib/validation'
import {
  explainFailure,
  explainRequest,
  requestPasswordReset,
  resetPasswordWithCode,
} from '@/lib/passwordReset'

type Step = 'sending' | 'enter' | 'blocked'

/**
 * Forgot password, in two steps: a 6-digit code is emailed to the address saved on the
 * account, then the code and a new password are entered here. The page shows this only
 * while it is wanted, so it asks for the code once, when it opens.
 */
export function ForgotPasswordDialog({
  phone,
  onClose,
  onDone,
}: {
  phone: string
  onClose(): void
  onDone(): void
}) {
  const [step, setStep] = useState<Step>('sending')
  const [notice, setNotice] = useState('')
  const [hint, setHint] = useState<string | null>(null)
  const [cooldown, setCooldown] = useState(0)
  const [code, setCode] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)
  const started = useRef(false)

  async function ask(first: boolean) {
    try {
      const r = await requestPasswordReset(phone)
      if (r.status === 'sent') {
        setHint(r.email_hint)
        setCooldown(60)
        setStep('enter')
        if (!first) toast.success('A new code was sent.')
      } else if (r.status === 'wait') {
        setCooldown(r.seconds)
        setStep('enter')
        setNotice('A code was sent a moment ago. Check your email, including the spam folder.')
      } else if (first) {
        setNotice(explainRequest(r))
        setStep('blocked')
      } else {
        toast.error(explainRequest(r))
      }
    } catch (err) {
      if (first) {
        setNotice(friendlyError(err))
        setStep('blocked')
      } else {
        toast.error(friendlyError(err))
      }
    }
  }

  useEffect(() => {
    if (started.current) return
    started.current = true
    void ask(true)
  }, [])

  useEffect(() => {
    if (cooldown <= 0) return
    const t = window.setTimeout(() => setCooldown((c) => c - 1), 1000)
    return () => window.clearTimeout(t)
  }, [cooldown])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      code: /^\d{6}$/.test(code) ? null : 'Enter the 6-digit code from the email.',
      password: validatePassword(password),
      confirm: password !== confirm ? 'Both passwords must match.' : null,
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    try {
      const r = await resetPasswordWithCode(phone, code, password)
      if (r.ok) {
        onDone()
        return
      }
      setErrors({ code: explainFailure(r) })
      if (r.reason !== 'wrong') setCode('')
    } catch (err) {
      setErrors({ code: friendlyError(err) })
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title="Reset your password"
      description={step === 'enter' && hint ? `We sent a 6-digit code to ${hint}.` : undefined}
      footer={
        step === 'enter' ? (
          <>
            <button
              type="button"
              className="btn-ghost"
              disabled={cooldown > 0 || busy}
              onClick={() => void ask(false)}
            >
              {cooldown > 0 ? `Resend in ${cooldown}s` : 'Send a new code'}
            </button>
            <button type="submit" form="reset-form" className="btn-primary" disabled={busy}>
              {busy ? 'Saving…' : 'Change password'}
            </button>
          </>
        ) : (
          <button type="button" className="btn-primary" onClick={onClose}>
            Close
          </button>
        )
      }
    >
      {step === 'sending' && <Spinner label="Sending your code" />}

      {step === 'blocked' && (
        <p className="text-[14px] leading-relaxed text-soil-800">{notice}</p>
      )}

      {step === 'enter' && (
        <form id="reset-form" onSubmit={submit} className="space-y-4" noValidate>
          {notice && (
            <p className="rounded-lg bg-sky-50 px-3 py-2 text-[13px] text-sky-800">{notice}</p>
          )}
          <p className="text-[13px] text-soil-600">
            The code works once and expires in 15 minutes.
          </p>
          <Field
            label="6-digit code"
            inputMode="numeric"
            autoComplete="one-time-code"
            autoFocus
            maxLength={6}
            placeholder="123456"
            value={code}
            error={errors.code}
            onChange={(e) => {
              setCode(e.target.value.replace(/\D/g, ''))
              setErrors((x) => ({ ...x, code: null }))
            }}
          />
          <PasswordField
            label="New password"
            autoComplete="new-password"
            hint="At least 8 characters."
            value={password}
            error={errors.password}
            onChange={(e) => {
              setPassword(e.target.value)
              setErrors((x) => ({ ...x, password: null }))
            }}
          />
          <PasswordField
            label="Confirm new password"
            autoComplete="new-password"
            value={confirm}
            error={errors.confirm}
            onChange={(e) => {
              setConfirm(e.target.value)
              setErrors((x) => ({ ...x, confirm: null }))
            }}
          />
        </form>
      )}
    </Dialog>
  )
}
