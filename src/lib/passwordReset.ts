import { supabase } from '@/lib/supabase'
import { normalisePhone } from '@/lib/validation'

/** What the server says when a code is asked for (see migration-48.sql). */
export type ResetRequest =
  | { status: 'sent'; email_hint: string }
  | { status: 'wait'; seconds: number }
  | { status: 'not_found' | 'no_email' | 'use_google' | 'too_many' | 'email_failed' }

/** What the server says when a code and a new password are handed in. */
export type ResetResult =
  | { ok: true }
  | { ok: false; reason: 'no_code' | 'expired' | 'wrong' | 'locked'; remaining?: number }

export async function requestPasswordReset(phoneInput: string): Promise<ResetRequest> {
  const phone = normalisePhone(phoneInput)
  if (!phone) throw new Error('Use a Philippine mobile number, like 09171234567.')
  const { data, error } = await supabase.rpc('request_password_reset', { p_phone: phone })
  if (error) throw new Error(error.message)
  return data as ResetRequest
}

export async function resetPasswordWithCode(
  phoneInput: string,
  code: string,
  newPassword: string,
): Promise<ResetResult> {
  const phone = normalisePhone(phoneInput)
  if (!phone) throw new Error('Use a Philippine mobile number, like 09171234567.')
  const { data, error } = await supabase.rpc('reset_password_with_code', {
    p_phone: phone,
    p_code: code,
    p_new_password: newPassword,
  })
  if (error) throw new Error(error.message)
  return data as ResetResult
}

/** Plain words for a request that did not end in a code being sent. */
export function explainRequest(r: ResetRequest): string {
  switch (r.status) {
    case 'not_found':
      return 'No account uses this number. Check the number, or create an account.'
    case 'no_email':
      return 'This account has no email saved, so a code cannot be sent. Ask the farm administrator to reset your password.'
    case 'use_google':
      return 'This account signs in with Google and has no password. Close this and tap Continue with Google.'
    case 'too_many':
      return 'Too many codes were asked for. Wait about 15 minutes, then try again.'
    case 'email_failed':
      return 'The email could not be sent right now. Try again in a few minutes.'
    default:
      return ''
  }
}

/** Plain words for a code that did not work. */
export function explainFailure(r: Extract<ResetResult, { ok: false }>): string {
  switch (r.reason) {
    case 'wrong':
      return `That code is not right. ${r.remaining ?? 0} ${r.remaining === 1 ? 'try' : 'tries'} left.`
    case 'locked':
      return 'Too many wrong tries. Ask for a new code.'
    case 'expired':
      return 'That code has expired. Ask for a new one.'
    default:
      return 'There is no active code for this number. Ask for a new one.'
  }
}
