import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import type { Role } from '@/lib/types'

const line = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.4,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

function SheafIcon() {
  return (
    <svg viewBox="0 0 40 40" className="h-8 w-8" {...line}>
      <path d="M20 34V15" />
      <path d="M20 15c0-3.6-1.5-6.6-4.3-8.7-1.5 3.2-1.3 6.6.6 9.2 1 1.4 2.3 2.4 3.7 3z" />
      <path d="M20 15c0-3.6 1.5-6.6 4.3-8.7 1.5 3.2 1.3 6.6-.6 9.2-1 1.4-2.3 2.4-3.7 3z" />
      <path d="M20 24c-1.6-2.9-4.2-4.7-7.6-5.2.3 3.4 2 6 4.8 7.2 1 .4 1.9.6 2.8.7z" />
      <path d="M20 24c1.6-2.9 4.2-4.7 7.6-5.2-.3 3.4-2 6-4.8 7.2-1 .4-1.9.6-2.8.7z" />
      <path d="M12 34h16" />
    </svg>
  )
}

function WorkerIcon() {
  return (
    <svg viewBox="0 0 40 40" className="h-8 w-8" {...line}>
      <path d="M11 17a9 9 0 0 1 18 0" />
      <path d="M8 17h24" />
      <circle cx="20" cy="23" r="4" />
      <path d="M10 35c0-4.4 4.5-7.5 10-7.5S30 30.6 30 35" />
      <path d="M20 8v2" />
    </svg>
  )
}

function TruckIcon() {
  return (
    <svg viewBox="0 0 40 40" className="h-8 w-8" {...line}>
      <path d="M4 12h17v14H4z" />
      <path d="M21 17h7l5 5v4h-12z" />
      <circle cx="12" cy="29" r="3" />
      <circle cx="27" cy="29" r="3" />
      <path d="M4 26h5M15 26h9" />
    </svg>
  )
}

function ShieldIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" {...line} strokeWidth={1.6}>
      <path d="M12 3l8 3.5v5c0 5-3.4 9.3-8 10.5C7.4 20.8 4 16.5 4 11.5v-5z" />
      <path d="M9 12l2.2 2.2L15.5 10" />
    </svg>
  )
}

const ROLES: {
  role: Role
  title: string
  description: string
  href: string
  icon: JSX.Element
  ring: string
  tint: string
  btn: string
}[] = [
  {
    role: 'owner',
    title: 'Farm Owner',
    description: 'Manage crops, stock, market listings and finances',
    href: '/owner/login',
    icon: <SheafIcon />,
    ring: 'group-hover:border-green-700/40',
    tint: 'bg-green-50 text-green-800',
    btn: 'bg-green-700 hover:bg-green-800',
  },
  {
    role: 'farmer',
    title: 'Farmer',
    description: 'Find farm work, record your hours and track your pay',
    href: '/farmer/login',
    icon: <WorkerIcon />,
    ring: 'group-hover:border-amber-700/40',
    tint: 'bg-amber-50 text-amber-800',
    btn: 'bg-amber-700 hover:bg-amber-800',
  },
  {
    role: 'buyer',
    title: 'Buyer',
    description: 'Buy rice, corn and watermelon direct from the farm',
    href: '/buyer/login',
    icon: <TruckIcon />,
    ring: 'group-hover:border-blue-700/40',
    tint: 'bg-blue-50 text-blue-800',
    btn: 'bg-blue-700 hover:bg-blue-800',
  },
]

export default function Landing() {
  const navigate = useNavigate()
  const [leaving, setLeaving] = useState<string | null>(null)

  function go(href: string, key: string) {
    if (leaving) return
    setLeaving(key)
    window.setTimeout(() => navigate(href), 320)
  }

  return (
    <div className="hero-photo hero-photo-img relative min-h-screen overflow-hidden">
      <div className="hero-scrim absolute inset-0" aria-hidden />

      <div
        className={`relative flex min-h-screen flex-col transition-all duration-300 ${
          leaving ? 'scale-[.98] opacity-0' : 'opacity-100'
        }`}
      >
        <header className="flex items-center gap-3 px-6 py-6 lg:px-12">
          <span className="flex h-9 w-9 items-center justify-center rounded-lg border border-white/25 bg-white/10 text-white backdrop-blur">
            <svg viewBox="0 0 24 24" className="h-5 w-5" {...line} strokeWidth={1.6}>
              <path d="M12 21V11" />
              <path d="M12 11c0-3.9 2.8-6.8 7-7 .2 4.2-2.7 7-7 7z" />
              <path d="M12 15c-3.4 0-5.8-2.3-6-5.8 3.5.2 5.8 2.4 6 5.8z" />
            </svg>
          </span>
          <div>
            <p className="text-[15px] font-semibold leading-none tracking-tight text-white">
              FARMS
            </p>
            <p className="mt-1 text-[11px] tracking-wide text-white/65">
              Barangay Pagatban · Bayawan City
            </p>
          </div>
        </header>

        <main className="flex flex-1 items-center px-6 pb-14 lg:px-12">
          <div className="mx-auto w-full max-w-5xl">
            <div className="max-w-xl animate-fade-up">
              <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-white/60">
                Farm Management System
              </p>
              <h1 className="mt-3 text-[34px] font-semibold leading-[1.1] tracking-tight text-white sm:text-[44px]">
                Plan the harvest.
                <br />
                Sell by the sack.
              </h1>
              <p className="mt-4 max-w-md text-[15px] leading-relaxed text-white/75">
                One system for the farms, workers and buyers of Barangay Pagatban.
                Pumili kung paano mo gagamitin ang FARMS.
              </p>
            </div>

            <div className="mt-10 grid gap-3 sm:grid-cols-3">
              {ROLES.map((r, i) => (
                <button
                  key={r.role}
                  onClick={() => go(r.href, r.role)}
                  style={{ animationDelay: `${120 + i * 80}ms` }}
                  className={`group animate-fade-up rounded-xl border border-white/15 bg-white/95 p-5 text-left
                              backdrop-blur transition duration-200 hover:-translate-y-1 hover:bg-white
                              hover:shadow-[0_18px_40px_-12px_rgba(8,20,12,.45)]
                              focus-visible:-translate-y-1 ${r.ring} ${
                                leaving === r.role ? 'scale-[1.03] ring-2 ring-white' : ''
                              }`}
                >
                  <span
                    className={`inline-flex h-12 w-12 items-center justify-center rounded-lg ${r.tint}`}
                  >
                    {r.icon}
                  </span>

                  <h2 className="mt-4 text-[17px] font-semibold tracking-tight text-soil-900">
                    {r.title}
                  </h2>
                  <p className="mt-1 text-[13px] leading-relaxed text-soil-600">{r.description}</p>

                  <span
                    className={`mt-4 flex w-full items-center justify-center gap-1.5 rounded-lg py-2.5
                                text-[14px] font-semibold text-white transition ${r.btn}`}
                  >
                    {leaving === r.role ? 'Opening…' : 'Sign In'}
                    {leaving !== r.role && (
                      <svg
                        className="transition group-hover:translate-x-0.5"
                        viewBox="0 0 24 24"
                        width="15"
                        height="15"
                        {...line}
                        strokeWidth={2.2}
                      >
                        <path d="M5 12h13M13 6l6 6-6 6" />
                      </svg>
                    )}
                  </span>
                </button>
              ))}
            </div>

            <div className="mt-8 flex animate-fade-up items-center gap-4" style={{ animationDelay: '380ms' }}>
              <span className="h-px flex-1 bg-white/20" />
              <button
                onClick={() => go('/admin/login', 'admin')}
                className="group inline-flex items-center gap-2 rounded-lg border border-white/20 px-4 py-2
                           text-[13px] font-medium text-white/80 transition hover:border-white/40 hover:bg-white/10 hover:text-white"
              >
                <ShieldIcon />
                Administrator access
                <svg
                  className="opacity-60 transition group-hover:translate-x-0.5 group-hover:opacity-100"
                  viewBox="0 0 24 24" width="14" height="14" {...line} strokeWidth={2}
                >
                  <path d="M5 12h13M13 6l6 6-6 6" />
                </svg>
              </button>
              <span className="h-px flex-1 bg-white/20" />
            </div>
          </div>
        </main>
      </div>
    </div>
  )
}
