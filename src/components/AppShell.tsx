import { useEffect, useRef, useState } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { useAuth } from '@/context/AuthContext'
import { useNotifications } from '@/context/NotificationsContext'
import { ROLE_LABEL, initials } from '@/lib/format'
import type { Role } from '@/lib/types'

interface NavItem {
  to: string
  label: string
  icon: JSX.Element

}

const I = (d: string) => (
  <svg
    width="21"
    height="21"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="1.8"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d={d} />
  </svg>
)

const NAV: Record<Role, NavItem[]> = {
  owner: [
    { to: '/owner/dashboard', label: 'Home', icon: I('M3 10.5 12 3l9 7.5M5 9.5V21h14V9.5') },
    { to: '/owner/calendar', label: 'Calendar', icon: I('M8 2v4M16 2v4M3 10h18M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z') },
    { to: '/owner/market', label: 'Market', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/owner/finance', label: 'Finance', icon: I('M12 2v20M17 6H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6') },
    { to: '/owner/jobs', label: 'Labor', icon: I('M4 7h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2') },
    { to: '/owner/attendance', label: 'Work Log', icon: I('M9 11l3 3 5-5M8 2v4M16 2v4M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z') },
    { to: '/owner/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
  ],
  farmer: [
    { to: '/farmer/jobs', label: 'Find Jobs', icon: I('M4 7h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2') },
    { to: '/farmer/applications', label: 'Applications', icon: I('M9 12h6M9 16h6M9 8h2M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
    { to: '/farmer/logs', label: 'Time Clock', icon: I('M12 7v5l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z') },
    { to: '/farmer/history', label: 'My Logs', icon: I('M9 11l3 3 5-5M8 2v4M16 2v4M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z') },
  ],
  admin: [
    { to: '/admin/dashboard', label: 'Overview', icon: I('M3 12h6v9H3zM9 3h6v18H9zM15 8h6v13h-6z') },
    { to: '/admin/verifications', label: 'Verify', icon: I('M9 12l2 2 4-4M12 3l7 4v5c0 4.4-3 8.3-7 9.5-4-1.2-7-5.1-7-9.5V7z') },
    { to: '/admin/requests', label: 'Admins', icon: I('M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM19 8v6M22 11h-6') },
    { to: '/admin/users', label: 'Users', icon: I('M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8') },
    { to: '/admin/catalog', label: 'Products', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/admin/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
  ],
  buyer: [
    { to: '/buyer/market', label: 'Market', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/buyer/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
  ],
}

export function AppShell({ role }: { role: Role }) {
  const { profile, signOut } = useAuth()
  const { unread } = useNotifications()
  const navigate = useNavigate()
  const [menuOpen, setMenuOpen] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  const items = NAV[role]


  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    return () => document.documentElement.removeAttribute('data-role')
  }, [role])

  useEffect(() => {
    if (!menuOpen) return
    const onClick = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) setMenuOpen(false)
    }
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setMenuOpen(false)
    document.addEventListener('mousedown', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [menuOpen])

  async function handleSignOut() {
    setMenuOpen(false)
    await signOut()
    toast.success('Signed out')
    navigate('/', { replace: true })
  }


  return (
    <div className="min-h-screen">
      <header className="app-bar sticky top-0 z-30">
        <div className="mx-auto flex max-w-[100rem] items-center justify-between gap-3 px-4 py-2.5 lg:px-8">
          <div className="flex items-center gap-2">
            <LeafMark />
            <div>
              <p className="text-[15px] font-bold leading-none tracking-tight">FARMS</p>
              <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.1em] text-white/70">
                {ROLE_LABEL[role]}
              </p>
            </div>
          </div>

          <nav className="hidden flex-1 items-center justify-center gap-0.5 lg:flex">
            {items.map((it) => (
              <NavLink
                key={it.to}
                to={it.to}
                className={({ isActive }) =>
                  `flex items-center gap-1.5 rounded-lg px-3 py-2 text-[13px] font-semibold transition ${
                    isActive
                      ? 'bg-white/20 text-white'
                      : 'text-white/75 hover:bg-white/10 hover:text-white'
                  }`
                }
              >
                <span className="shrink-0">{it.icon}</span>
                {it.label}
              </NavLink>
            ))}
          </nav>

          <div className="flex items-center gap-1">
            <button
              onClick={() => navigate(`/${role}/notifications`)}
              className="relative rounded-lg p-1.5 text-white/90 transition hover:bg-white/15"
              aria-label={unread > 0 ? `Notifications, ${unread} unread` : 'Notifications'}
            >
              <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
                <path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0" />
              </svg>
              {unread > 0 && (
                <span className="num absolute -right-0.5 -top-0.5 flex h-[17px] min-w-[17px] items-center justify-center rounded-full bg-red-500 px-1 text-[10px] font-bold text-white ring-2 ring-brand-600">
                  {unread > 99 ? '99+' : unread}
                </span>
              )}
            </button>

            <div className="relative" ref={menuRef}>
              <button
                onClick={() => setMenuOpen((v) => !v)}
                aria-expanded={menuOpen}
                aria-haspopup="menu"
                aria-label="Your account"
                className="flex items-center gap-1.5 rounded-full p-0.5 pr-1.5 transition hover:bg-white/15"
              >
                {profile?.avatar_url ? (
                  <img
                    src={profile.avatar_url}
                    alt=""
                    className="h-8 w-8 shrink-0 rounded-full object-cover ring-2 ring-white/30"
                  />
                ) : (
                  <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-white/20 text-[12px] font-bold text-white">
                    {initials(profile?.name ?? '')}
                  </span>
                )}
                <svg
                  className={`text-white/70 transition ${menuOpen ? 'rotate-180' : ''}`}
                  width="14" height="14" viewBox="0 0 24 24" fill="none"
                  stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"
                >
                  <path d="m6 9 6 6 6-6" />
                </svg>
              </button>

              {menuOpen && (
                <div
                  role="menu"
                  className="absolute right-0 top-full z-40 mt-2 w-60 animate-scale-in overflow-hidden
                             rounded-xl border border-soil-200 bg-white shadow-lg"
                >
                  <div className="flex items-center gap-3 border-b border-soil-200 px-4 py-3">
                    {profile?.avatar_url ? (
                      <img
                        src={profile.avatar_url}
                        alt=""
                        className="h-10 w-10 shrink-0 rounded-full object-cover"
                      />
                    ) : (
                      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-600 text-[13px] font-bold text-white">
                        {initials(profile?.name ?? '')}
                      </span>
                    )}
                    <span className="min-w-0">
                      <span className="block truncate text-[14px] font-bold text-soil-900">
                        {profile?.name || 'Your account'}
                      </span>
                      <span className="block truncate text-[12px] text-soil-400">
                        {ROLE_LABEL[role]}
                      </span>
                    </span>
                  </div>

                  <button
                    role="menuitem"
                    onClick={() => {
                      setMenuOpen(false)
                      navigate(`/${role}/account`)
                    }}
                    className="flex w-full items-center gap-2.5 px-4 py-2.5 text-left text-[14px] font-medium text-soil-800 hover:bg-soil-100"
                  >
                    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z" />
                    </svg>
                    My account
                  </button>

                  <button
                    role="menuitem"
                    onClick={handleSignOut}
                    className="flex w-full items-center gap-2.5 border-t border-soil-200 px-4 py-2.5 text-left text-[14px] font-semibold text-red-600 hover:bg-red-50"
                  >
                    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9" />
                    </svg>
                    Log out
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>

        <nav className="scrollbar-none overflow-x-auto border-t border-white/15 lg:hidden">
          <div className="flex min-w-max gap-0.5 px-3 py-1.5">
            {items.map((it) => (
              <NavLink
                key={it.to}
                to={it.to}
                className={({ isActive }) =>
                  `whitespace-nowrap rounded-md px-3 py-1.5 text-[12px] font-semibold transition ${
                    isActive ? 'bg-white/20 text-white' : 'text-white/70'
                  }`
                }
              >
                {it.label}
              </NavLink>
            ))}
          </div>
        </nav>
      </header>

      <main className="mx-auto max-w-[100rem] px-4 pb-10 pt-4 lg:px-8 lg:pt-6">
        <Outlet />
      </main>

    </div>
  )
}

export function LeafMark({ size = 28, solid = false }: { size?: number; solid?: boolean }) {
  return (
    <span
      className={`flex shrink-0 items-center justify-center rounded-full ${
        solid ? 'bg-brand-600 text-white' : 'bg-white/20 text-white'
      }`}
      style={{ width: size, height: size }}
    >
      <svg width={size * 0.55} height={size * 0.55} viewBox="0 0 24 24" fill="currentColor">
        <path d="M20 3c0 9-5.5 14-12 14a7 7 0 0 1-4-1.2C5.6 9.7 11 5.5 20 3z" />
        <path d="M4 21c0-4 2.5-7.5 6-9.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" fill="none" />
      </svg>
    </span>
  )
}

export function Wordmark({ large = false }: { large?: boolean }) {
  return <span className={`font-bold tracking-tight ${large ? 'text-2xl' : 'text-lg'}`}>FARMS</span>
}
