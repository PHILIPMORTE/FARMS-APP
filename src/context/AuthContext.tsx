import { createContext, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import type { Farm, Profile, Role } from '@/lib/types'
import { normalisePhone } from '@/lib/validation'

interface AuthState {
  session: Session | null

  profile: Profile | null

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

const ROLE_KEY = 'farms.active-role'
export const getActiveRole = (): Role | null => {
  const stored =
    localStorage.getItem(ROLE_KEY) ?? sessionStorage.getItem(ROLE_KEY)
  return (stored as Role | null) ?? null
}

export const setActiveRole = (r: Role | null) => {
  if (r) {
    localStorage.setItem(ROLE_KEY, r)
    sessionStorage.setItem(ROLE_KEY, r)
  } else {
    localStorage.removeItem(ROLE_KEY)
    sessionStorage.removeItem(ROLE_KEY)
  }
}

class AuthError extends Error {}

async function phoneTaken(phone: string, role: Role): Promise<boolean> {
  const { data, error } = await supabase.rpc('phone_role_taken', {
    p_phone: phone,
    p_role: role,
  })

  if (error) return false
  return data === true
}

function aliasEmail(phoneE164: string): string {
  return `p${phoneE164.replace(/\D/g, '')}@phone.farms.ph`
}

function hasSession(res: { data?: { session?: unknown } | null }): boolean {
  return !!res?.data?.session
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [farm, setFarm] = useState<Farm | null>(null)
  const [loading, setLoading] = useState(true)
  const [profileLoading, setProfileLoading] = useState(false)
  const mounted = useRef(true)
  const loadSeq = useRef(0)
  const signingIn = useRef(false)

  async function loadProfile(userId: string, role: Role | null) {
    const seq = ++loadSeq.current
    const stale = () => !mounted.current || seq !== loadSeq.current

    let wanted = role

    if (!wanted) {
      const { data: mine } = await supabase
        .from('profiles')
        .select('role')
        .eq('user_id', userId)
        .order('created_at')

      if (stale()) return

      const roles = ((mine as { role: Role }[]) ?? []).map((r) => r.role)
      if (roles.length === 1) {
        wanted = roles[0]
        setActiveRole(wanted)
      } else {
        setProfile(null)
        setFarm(null)
        return
      }
    }

    const { data: prof } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', userId)
      .eq('role', wanted)
      .maybeSingle()

    if (stale()) return
    setProfile((prof as Profile) ?? null)

    if (prof && wanted === 'owner') {
      let { data: f } = await supabase
        .from('farms')
        .select('*')
        .eq('owner_id', (prof as Profile).id)
        .maybeSingle()

      if (!f) {
        const { data: created } = await supabase
          .from('farms')
          .insert({ owner_id: (prof as Profile).id, name: `${(prof as Profile).name}'s Farm` })
          .select()
          .single()
        f = created
      }
      if (!stale()) setFarm((f as Farm) ?? null)
    } else if (!stale()) {
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

      if (signingIn.current) return

      if (s) {
        setProfileLoading(true)
        try {
          await loadProfile(s.user.id, getActiveRole())
        } finally {
          if (mounted.current) setProfileLoading(false)
        }
      } else {
        setProfile(null)
        setFarm(null)
        setProfileLoading(false)
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

  async function signInWithPhone(role: Role, phoneInput: string, password: string) {
    signingIn.current = true
    try {
      return await doSignInWithPhone(role, phoneInput, password)
    } finally {
      signingIn.current = false
    }
  }

  async function doSignInWithPhone(role: Role, phoneInput: string, password: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')

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

  async function registerWithPhone(role: Role, name: string, phoneInput: string, password: string) {
    signingIn.current = true
    try {
      return await doRegisterWithPhone(role, name, phoneInput, password)
    } finally {
      signingIn.current = false
    }
  }

  async function doRegisterWithPhone(
    role: Role,
    name: string,
    phoneInput: string,
    password: string,
  ) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')

    if (await phoneTaken(phone, role)) {
      throw new AuthError(
        `This number is already registered as a ${ROLE_WORD_TITLE[role]}. Use a different number or sign in.`,
      )
    }

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
            'This number already has an account. Enter that account’s password to add this role to it.',
          )
        } else if (viaAlias.data?.user && !viaAlias.data.session) {
          throw new AuthError(
            'Account created but not signed in. In Supabase go to Authentication → Providers → Email and turn OFF “Confirm email”, then sign in.',
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
          prompt: 'select_account',
        },
      },
    })
    if (error) throw new AuthError(error.message)
  }

  async function completeGoogleProfile(role: Role, name: string, phoneInput: string) {
    const phone = normalisePhone(phoneInput)
    if (!phone) throw new AuthError('Use a Philippine mobile number, like 09171234567.')
    const { data: s } = await supabase.auth.getSession()
    if (!s.session) throw new AuthError('Your sign-in expired. Try again.')

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
      loading: loading || profileLoading,
      signInWithPhone,
      registerWithPhone,
      signInWithGoogle,
      completeGoogleProfile,
      sendPasswordReset,
      refresh,
      signOut,
    }),
    [session, profile, farm, loading, profileLoading],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

const ROLE_WORD: Record<Role, string> = {
  owner: 'farm owner',
  farmer: 'farmer',
  buyer: 'buyer',
  admin: 'administrator',
}
const ROLE_WORD_TITLE: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
  admin: 'Administrator',
}

export async function isPhoneTakenForRole(phone: string, role: Role) {
  return phoneTaken(phone, role)
}

export function useAuth() {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>')
  return ctx
}
