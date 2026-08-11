import { useEffect } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router-dom'
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
    { to: '/owner/account', label: 'Account', icon: I('M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z') },
  ],
  farmer: [
    { to: '/farmer/jobs', label: 'Find Jobs', icon: I('M4 7h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2') },
    { to: '/farmer/applications', label: 'Applications', icon: I('M9 12h6M9 16h6M9 8h2M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
    { to: '/farmer/account', label: 'Account', icon: I('M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z') },
  ],
  buyer: [
    { to: '/buyer/market', label: 'Market', icon: I('M3 9h18l-1.5 11a2 2 0 0 1-2 2H6.5a2 2 0 0 1-2-2zM8 9V6a4 4 0 0 1 8 0v3') },
    { to: '/buyer/orders', label: 'Orders', icon: I('M9 12h6M9 16h6M7 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z') },
    { to: '/buyer/account', label: 'Account', icon: I('M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z') },
  ],
}

export function AppShell({ role }: { role: Role }) {
  const { profile, farm } = useAuth()
  const { unread } = useNotifications()
  const navigate = useNavigate()
  const items = NAV[role]

  useEffect(() => {
    document.documentElement.setAttribute('data-role', role)
    return () => document.documentElement.removeAttribute('data-role')
  }, [role])

  const subtitle = role === 'owner' ? farm?.name ?? 'Farm Owner' : ROLE_LABEL[role]

  return (
    <div className="min-h-screen lg:flex">
      {/* Sidebar — laptop and up */}
      <aside className="hidden lg:flex lg:w-60 lg:flex-col lg:border-r lg:border-soil-200 lg:bg-white">
        <div className="app-bar flex items-center gap-2 px-5 py-4">
          <LeafMark />
          <div>
            <p className="text-[16px] font-bold leading-none tracking-tight">FARMS</p>
            <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.1em] text-white/70">
              {ROLE_LABEL[role]}
            </p>
          </div>
        </div>
        <nav className="flex-1 space-y-0.5 p-3">
          {items.map((it) => (
            <NavLink
              key={it.to}
              to={it.to}
              className={({ isActive }) =>
                `flex items-center gap-3 rounded-lg px-3 py-2.5 text-[14px] font-medium transition ${
                  isActive
                    ? 'bg-brand-50 font-semibold text-brand-700'
                    : 'text-soil-600 hover:bg-soil-100 hover:text-soil-900'
                }`
              }
            >
              {it.icon}
              {it.label}
            </NavLink>
          ))}
        </nav>
        <div className="border-t border-soil-200 p-3">
          <NavLink
            to={`/${role}/account`}
            className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-soil-100"
          >
            <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-brand-600 text-[13px] font-semibold text-white">
              {initials(profile?.name ?? '')}
            </span>
            <span className="min-w-0">
              <span className="block truncate text-[13px] font-semibold">{profile?.name}</span>
              <span className="block truncate text-[12px] text-soil-400">{subtitle}</span>
            </span>
          </NavLink>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Solid brand bar */}
        <header className="app-bar sticky top-0 z-30 flex items-center justify-between gap-3 px-4 py-3 lg:px-8">
          <div className="flex items-center gap-2 lg:hidden">
            <LeafMark />
            <div>
              <p className="text-[15px] font-bold leading-none tracking-tight">FARMS</p>
              <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.1em] text-white/70">
                {ROLE_LABEL[role]}
              </p>
            </div>
          </div>
          <p className="hidden truncate text-[14px] font-semibold text-white/90 lg:block">
            {subtitle}
          </p>

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
        </header>

        <main className="flex-1 px-4 pb-24 pt-4 lg:px-8 lg:pb-10 lg:pt-6">
          <Outlet />
        </main>
      </div>

      {/* Bottom tabs — phone and tablet */}
      <nav
        className="fixed inset-x-0 bottom-0 z-30 grid border-t border-soil-200 bg-white pb-[env(safe-area-inset-bottom)] lg:hidden"
        style={{ gridTemplateColumns: `repeat(${items.length}, minmax(0, 1fr))` }}
      >
        {items.map((it) => (
          <NavLink
            key={it.to}
            to={it.to}
            className={({ isActive }) =>
              `flex flex-col items-center gap-0.5 py-2 text-[10px] font-medium transition ${
                isActive ? 'text-brand-600' : 'text-soil-400'
              }`
            }
          >
            {it.icon}
            <span className="truncate px-0.5">{it.label}</span>
          </NavLink>
        ))}
      </nav>
    </div>
  )
}

/** The leaf badge used on the header bar and on the auth cards. */
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
