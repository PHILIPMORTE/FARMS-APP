import { Navigate, useLocation } from 'react-router-dom'
import { useAuth, getActiveRole } from '@/context/AuthContext'
import { ROLE_HOME } from '@/lib/format'
import type { Role } from '@/lib/types'
import { Spinner } from '@/components/ui'
import type { ReactNode } from 'react'

/**
 * Guards a role's section. Someone signed in as a buyer who types /owner/market
 * lands back on their own market rather than seeing an error.
 */
export function ProtectedRoute({ role, children }: { role: Role; children: ReactNode }) {
  const { session, profile, loading } = useAuth()
  const location = useLocation()

  if (loading) return <Spinner label="Checking your account" />

  if (!session) {
    return <Navigate to={`/${role}/login`} state={{ from: location.pathname }} replace />
  }

  // Signed in, but the profile for this role has not loaded or does not exist.
  if (!profile) {
    const active = getActiveRole()
    if (active && active !== role) return <Navigate to={ROLE_HOME[active]} replace />
    return <Navigate to={`/${role}/login`} replace />
  }

  if (profile.role !== role) return <Navigate to={ROLE_HOME[profile.role]} replace />

  return <>{children}</>
}
