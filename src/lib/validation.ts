const PH_LOCAL = /^09\d{9}$/
const PH_E164 = /^\+639\d{9}$/

export function normalisePhone(input: string): string | null {
  const raw = input.replace(/[\s()-]/g, '')
  if (PH_E164.test(raw)) return raw
  if (PH_LOCAL.test(raw)) return `+63${raw.slice(1)}`
  if (/^639\d{9}$/.test(raw)) return `+${raw}`
  if (/^9\d{9}$/.test(raw)) return `+63${raw}`
  return null
}

export function displayPhone(e164: string | null | undefined): string {
  if (!e164) return '—'
  const local = e164.startsWith('+63') ? `0${e164.slice(3)}` : e164
  return local.replace(/^(\d{4})(\d{3})(\d{4})$/, '$1 $2 $3')
}

export function validatePhone(input: string): string | null {
  if (!input.trim()) return 'Enter your mobile number.'
  if (!normalisePhone(input))
    return 'Use a Philippine mobile number, like 09171234567 or +639171234567.'
  return null
}

export function validatePassword(input: string): string | null {
  if (!input) return 'Enter a password.'
  if (input.length < 8) return 'Use at least 8 characters.'
  return null
}

export function validateName(input: string): string | null {
  if (!input.trim()) return 'Enter your full name.'
  if (input.trim().length < 2) return 'Enter your full name.'
  return null
}

export function validateSacks(raw: string | number, opts: { min?: number; max?: number } = {}): string | null {
  const { min = 1, max } = opts
  const s = String(raw).trim()
  if (!s) return 'Enter a number of sacks.'
  if (!/^\d+$/.test(s)) return 'Sacks must be a whole number — no decimals.'
  const n = parseInt(s, 10)
  if (n < min) return `Enter at least ${min} sack${min === 1 ? '' : 's'}.`
  if (max !== undefined && n > max) return `Only ${max} sack${max === 1 ? '' : 's'} available.`
  return null
}

export function validateWholeNumber(raw: string | number, min = 0, label = 'value'): string | null {
  const s = String(raw).trim()
  if (!s) return `Enter a ${label}.`
  if (!/^\d+$/.test(s)) return `The ${label} must be a whole number.`
  if (parseInt(s, 10) < min) return `Enter at least ${min}.`
  return null
}

export function validateAmount(raw: string | number, label = 'amount'): string | null {
  const n = Number(raw)
  if (String(raw).trim() === '') return `Enter an ${label}.`
  if (!Number.isFinite(n) || n < 0) return `Enter a valid ${label}.`
  return null
}

export function validateRequired(input: string, label: string): string | null {
  return input.trim() ? null : `${label} is required.`
}

export function friendlyError(error: unknown): string {
  const msg = (error as { message?: string })?.message ?? String(error)
  if (/duplicate key.*profiles_phone_role_key/i.test(msg))
    return 'That number is already registered for this role.'
  if (/duplicate key.*job_applications/i.test(msg))
    return 'You have already applied to this job.'
  if (/Invalid login credentials/i.test(msg))
    return 'That number and password do not match an account.'
  if (/User already registered/i.test(msg))
    return 'That number already has an account. Sign in instead.'
  if (/Password should be/i.test(msg)) return 'Use at least 8 characters.'
  return msg || 'Something went wrong. Try again.'
}
