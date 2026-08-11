import { useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { useAuth } from '@/context/AuthContext'
import { initials } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { ReactNode } from 'react'

export function AccountHeader({ subtitle, extra }: { subtitle?: string; extra?: ReactNode }) {
  const { profile, signOut } = useAuth()
  const navigate = useNavigate()

  async function out() {
    await signOut()
    toast.success('Signed out')
    navigate('/', { replace: true })
  }

  return (
    <div className="card flex flex-wrap items-center gap-4 p-5">
      <span className="num flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-brand-700 text-lg font-bold text-white">
        {initials(profile?.name ?? '')}
      </span>
      <div className="min-w-0 flex-1">
        <h2 className="truncate text-lg font-bold">{profile?.name || 'Your account'}</h2>
        {subtitle && <p className="truncate text-sm text-soil-600">{subtitle}</p>}
        <p className="num text-sm text-soil-400">{displayPhone(profile?.phone)}</p>
        {extra}
      </div>
      <button className="btn-ghost" onClick={out}>
        Log out
      </button>
    </div>
  )
}
