import { Navigate, useLocation } from 'react-router-dom'
import { useAuth, getActiveRole } from '@/context/AuthContext'
import { ROLE_HOME } from '@/lib/format'
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
    return <Navigate to={`/${role}/login`} replace />
  }

  if (profile.role !== role) return <Navigate to={ROLE_HOME[profile.role]} replace />

  return <>{children}</>
}
