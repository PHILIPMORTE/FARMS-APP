import { createContext, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import type { Farm, Profile, Role } from '@/lib/types'
import { normalisePhone } from '@/lib/validation'

interface AuthState {
  session: Session | null
  /** The profile for the role the person is currently signed in under. */
  profile: Profile | null
  /** The owner's farm. Null for other roles. */
  farm: Farm | null
  loading: boolean
  signInWithPhone(role: Role, phone: string, password: string): Promise<void>
  registerWithPhone(role: Role, name: string, phone: string, password: string): Promise<void>
  signInWithGoogle(role: Role): Promise<void>
  completeGoogleProfile(role: Role, name: string, phone: string): Promise<void>
  sendPasswordReset(phone: string): Promise<void>
  refresh(): Promise<void>
  signOut(): Promise<void>
}

const Ctx = createContext<AuthState | null>(null)

/** Role currently being used. Kept in sessionStorage — it is navigation state,
 *  not application data, and it must not survive as a stale cross-tab default. */
const ROLE_KEY = 'farms.active-role'
export const getActiveRole = (): Role | null =>
  (sessionStorage.getItem(ROLE_KEY) as Role | null) ?? null
export const setActiveRole = (r: Role | null) =>
  r ? sessionStorage.setItem(ROLE_KEY, r) : sessionStorage.removeItem(ROLE_KEY)

class AuthError extends Error {}

/**
 * Supabase Auth needs one credential it recognises. Phone auth is ideal but
 * depends on the Phone provider being switched on AND "Confirm phone" being
 * off — two dashboard settings that often are not. So every account also has
 * a derived email alias, letting sign in work whichever way the project is
 * configured.
 *
 * The person NEVER needs an email address and never sees this value. It is
 * built from the phone number they typed and used only as an internal login
 * key. Nothing is ever sent to it.
 *
 * The domain must use a real TLD — Supabase rejects reserved suffixes such as
 * .local and .invalid as malformed, which is why this is a .ph subdomain.
 */
/**
 * Is this number already registered under this role? Runs through an RPC
 * because during registration the person is not signed in yet, and the
 * profiles table is only readable by authenticated users.
 */
async function phoneTaken(phone: string, role: Role): Promise<boolean> {
  const { data, error } = await supabase.rpc('phone_role_taken', {
    p_phone: phone,
    p_role: role,
  })
  // If the check itself fails, let the unique constraint be the backstop
  // rather than blocking a legitimate registration.
  if (error) return false
  return data === true
}

function aliasEmail(phoneE164: string): string {
  return `p${phoneE164.replace(/\D/g, '')}@phone.farms.ph`
}

/** True when Supabase returned a usable session. */
function hasSession(res: { data?: { session?: unknown } | null }): boolean {
  return !!res?.data?.session
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [farm, setFarm] = useState<Farm | null>(null)
  const [loading, setLoading] = useState(true)
  const mounted = useRef(true)

  /** Loads the profile row for the role we are operating under. */
  async function loadProfile(userId: string, role: Role | null) {
    if (!role) {
      setProfile(null)
      setFarm(null)
      return
    }
    const { data: prof } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', userId)
      .eq('role', role)
      .maybeSingle()

    if (!mounted.current) return
    setProfile((prof as Profile) ?? null)

    if (prof && role === 'owner') {
      let { data: f } = await supabase
        .from('farms')
        .select('*')
        .eq('owner_id', (prof as Profile).id)
        .maybeSingle()

      // Every owner needs a farm to hang inventory, jobs and finance off.
      if (!f) {
        const { data: created } = await supabase
          .from('farms')
          .insert({ owner_id: (prof as Profile).id, name: `${(prof as Profile).name}'s Farm` })
          .select()
          .single()
        f = created
      }
      if (mounted.current) setFarm((f as Farm) ?? null)
    } else {
      setFarm(null)
    }
  }

  useEffect(() => {
    mounted.current = true

    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session)
      if (data.session) await loadProfile(data.session.user.id, getActiveRole())
      if (mounted.current) setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange(async (_event, s) => {
      setSession(s)
      if (s) await loadProfile(s.user.id, getActiveRole())
      else {
        setProfile(null)
        setFarm(null)
      }
    })

    return () => {
      mounted.current = false
      sub.subscription.unsubscribe()
    }
  }, [])

  async function refresh() {
    const { data } = await supabase.auth.getSession()
    if (data.session) await loadProfile(data.session.user.id, getActiveRole())
  }

  /** Sign in to a specific role. Having an account under another role is not
   *  enough — the profile for THIS role has to exist. */
  async function signInWithPhone(role: Role, phoneInput: string, password: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')

    // Try phone auth first, then the email alias. One of the two will match
    // however the Supabase project happens to be configured.
    let data = null as Awaited<ReturnType<typeof supabase.auth.signInWithPassword>>['data'] | null

    const byPhone = await supabase.auth.signInWithPassword({ phone, password })
    if (hasSession(byPhone)) {
      data = byPhone.data
    } else {
      const byAlias = await supabase.auth.signInWithPassword({
        email: aliasEmail(phone),
        password,
      })
      if (hasSession(byAlias)) data = byAlias.data
    }

    if (!data?.user || !data.session) {
      throw new AuthError('That number and password do not match an account.')
    }

    const { data: prof } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', data.user.id)
      .eq('role', role)
      .maybeSingle()

    if (!prof) {
      await supabase.auth.signOut()
      throw new AuthError(
        `That number has no ${ROLE_WORD[role]} account yet. Open the Create account tab to add one.`,
      )
    }

    setActiveRole(role)
    setSession(data.session)
    await loadProfile(data.user.id, role)
  }

  /** Register under a role. If the number already has an account under a
   *  different role, the same password signs it in and a second profile is
   *  added — which is how one phone ends up holding up to three roles. */
  async function registerWithPhone(role: Role, name: string, phoneInput: string, password: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')

    // Is this number already taken for this exact role? Checked before any
    // auth user is created, so a duplicate never leaves anything behind.
    if (await phoneTaken(phone, role)) {
      throw new AuthError(
        `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
      )
    }

    // The number may already have an account under a different role. Try to
    // sign into it so this role can be added to the same auth user.
    let userId: string | null = null

    const existingPhone = await supabase.auth.signInWithPassword({ phone, password })
    if (hasSession(existingPhone)) {
      userId = existingPhone.data.user!.id
      setSession(existingPhone.data.session)
    } else {
      const existingAlias = await supabase.auth.signInWithPassword({
        email: aliasEmail(phone),
        password,
      })
      if (hasSession(existingAlias)) {
        userId = existingAlias.data.user!.id
        setSession(existingAlias.data.session)
      }
    }

    if (!userId) {
      // No account yet. Create one, trying phone auth first and falling back
      // to the email alias when the Phone provider is off or still confirming.
      const viaPhone = await supabase.auth.signUp({
        phone,
        password,
        options: { data: { name } },
      })

      if (hasSession(viaPhone)) {
        userId = viaPhone.data.user!.id
        setSession(viaPhone.data.session)
      } else {
        const viaAlias = await supabase.auth.signUp({
          email: aliasEmail(phone),
          password,
          options: { data: { name, phone } },
        })

        if (hasSession(viaAlias)) {
          userId = viaAlias.data.user!.id
          setSession(viaAlias.data.session)
        } else if (viaAlias.error && /already registered|already been/i.test(viaAlias.error.message)) {
          throw new AuthError(
            'This number already has an account. Enter that account\u2019s password to add this role to it.',
          )
        } else if (viaAlias.data?.user && !viaAlias.data.session) {
          // Account exists but Supabase withheld the session pending confirmation.
          throw new AuthError(
            'Account created but not signed in. In Supabase go to Authentication \u2192 Providers \u2192 Email and turn OFF \u201cConfirm email\u201d, then sign in.',
          )
        } else {
          throw new AuthError(viaAlias.error?.message ?? viaPhone.error?.message ?? 'Could not create the account.')
        }
      }
    }

    await createProfile(userId!, role, name, phone, null)
    setActiveRole(role)
    await loadProfile(userId!, role)
  }

  async function signInWithGoogle(role: Role) {
    setActiveRole(role)
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback?role=${role}`,
        queryParams: {
          // Always show Google's account chooser. Without this, Google silently
          // reuses whichever account is already signed in on the device — bad
          // here, where one person may keep separate accounts per role, and
          // worse on a shared phone.
          prompt: 'select_account',
        },
      },
    })
    if (error) throw new AuthError(error.message)
  }

  /** Google gives us a name and email but never a Philippine phone number,
   *  so a first-time Google user finishes the profile by hand. */
  async function completeGoogleProfile(role: Role, name: string, phoneInput: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')
    const { data: s } = await supabase.auth.getSession()
    if (!s.session) throw new AuthError('Your sign-in expired. Try again.')

    // Same rule for Google: a number already registered under this role cannot
    // be claimed again, no matter which sign-in method is used.
    if (await phoneTaken(phone, role)) {
      throw new AuthError(
        `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
      )
    }

    await createProfile(s.session.user.id, role, name, phone, s.session.user.email ?? null)
    setActiveRole(role)
    await loadProfile(s.session.user.id, role)
  }

  async function createProfile(
    userId: string,
    role: Role,
    name: string,
    phone: string,
    email: string | null,
  ) {
    const { data, error } = await supabase
      .from('profiles')
      .insert({ user_id: userId, role, name, phone, email })
      .select()
      .single()

    if (error) {
      if (/profiles_phone_role_key/.test(error.message)) {
        throw new AuthError(
          `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
        )
      }
      throw new AuthError(error.message)
    }

    const p = data as Profile
    if (role === 'owner') {
      await supabase.from('farms').insert({ owner_id: p.id, name: `${name}'s Farm` })
    }
    if (role === 'farmer') {
      await supabase.from('farmer_profiles').insert({ id: p.id, availability: 'available' })
    }
  }

  /** Password reset runs over email, so it only works where an email is on file. */
  async function sendPasswordReset(phoneInput: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Enter your mobile number first.')

    const { data } = await supabase
      .from('profiles')
      .select('email')
      .eq('phone', phone)
      .not('email', 'is', null)
      .limit(1)
      .maybeSingle()

    if (!data?.email) {
      throw new AuthError(
        'No email is attached to this number, so a reset link cannot be sent. Ask your farm administrator to reset it.',
      )
    }

    const { error } = await supabase.auth.resetPasswordForEmail(data.email, {
      redirectTo: `${window.location.origin}/auth/reset`,
    })
    if (error) throw new AuthError(error.message)
  }

  async function signOut() {
    await supabase.auth.signOut()
    setActiveRole(null)
    setProfile(null)
    setFarm(null)
    setSession(null)
  }

  const value = useMemo<AuthState>(
    () => ({
      session,
      profile,
      farm,
      loading,
      signInWithPhone,
      registerWithPhone,
      signInWithGoogle,
      completeGoogleProfile,
      sendPasswordReset,
      refresh,
      signOut,
    }),
    [session, profile, farm, loading],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

const ROLE_WORD: Record<Role, string> = {
  owner: 'farm owner',
  farmer: 'farmer',
  buyer: 'buyer',
}
const ROLE_WORD_TITLE: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
}

/** Exported so the account pages can check before saving a changed number. */
export async function isPhoneTakenForRole(phone: string, role: Role) {
  return phoneTaken(phone, role)
}

export function useAuth() {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>')
  return ctx
}
