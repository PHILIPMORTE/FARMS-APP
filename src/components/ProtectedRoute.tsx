import { useEffect, useState } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth, getActiveRole, setActiveRole } from '@/context/AuthContext'
import { ROLE_HOME, ROLE_LABEL } from '@/lib/format'
import type { Role } from '@/lib/types'
import { Spinner } from '@/components/ui'
import type { ReactNode } from 'react'

export function ProtectedRoute({ role, children }: { role: Role; children: ReactNode }) {
  const { session, profile, loading } = useAuth()
  const location = useLocation()

  if (loading) return <Spinner label="Checking your account" />

  if (!session) {
    return <Navigate to={`/${role}/login`} state={{ from: location.pathname }} replace />
  }

  if (!profile) {
    const active = getActiveRole()
    if (active && active !== role) return <Navigate to={ROLE_HOME[active]} replace />
    return <ResumeSession role={role} />
  }

  if (profile.role !== role) return <Navigate to={ROLE_HOME[profile.role]} replace />

  return <>{children}</>
}

function ResumeSession({ role }: { role: Role }) {
  const { session, refresh } = useAuth()
  const [roles, setRoles] = useState<Role[] | null>(null)

  useEffect(() => {
    if (!session) return
    supabase
      .from('profiles')
      .select('role')
      .eq('user_id', session.user.id)
      .order('created_at')
      .then(({ data }) => {
        const found = ((data as { role: Role }[]) ?? []).map((r) => r.role)
        if (found.includes(role)) {
          setActiveRole(role)
          refresh()
          return
        }
        setRoles(found)
      })
  }, [session?.user.id, role])

  if (roles === null) return <Spinner label="Loading your account" />

  if (roles.length === 0) {
    return (
      <div className="auth-wash flex min-h-screen items-center justify-center px-5">
        <div className="auth-card relative z-10 w-full max-w-sm rounded-2xl p-7 text-center">
          <h1 className="text-[18px] font-bold">No {ROLE_LABEL[role]} account</h1>
          <p className="mt-1.5 text-[14px] leading-relaxed text-soil-600">
            You are signed in, but this number has no {ROLE_LABEL[role]} account yet.
          </p>
          <a href={`/${role}/login`} className="btn-primary mt-5 w-full">
            Create one
          </a>
        </div>
      </div>
    )
  }

  return (
    <div className="auth-wash flex min-h-screen items-center justify-center px-5">
      <div className="auth-card relative z-10 w-full max-w-sm rounded-2xl p-7">
        <h1 className="text-center text-[18px] font-bold">Which account?</h1>
        <p className="mt-1.5 text-center text-[14px] leading-relaxed text-soil-600">
          You are already signed in. Choose the account you want to open.
        </p>
        <div className="mt-5 space-y-2">
          {roles.map((r) => (
            <button
              key={r}
              onClick={() => {
                setActiveRole(r)
                window.location.href = ROLE_HOME[r]
              }}
              className="btn-ghost w-full justify-between py-3"
            >
              {ROLE_LABEL[r]}
              <span aria-hidden>→</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
