import { Link } from 'react-router-dom'
import { LeafMark } from '@/components/AppShell'
import type { Role } from '@/lib/types'

const ROLES: {
  role: Role
  title: string
  description: string
  href: string
  emoji: string
  tint: string
  btn: string
}[] = [
  {
    role: 'owner',
    title: 'Farm Owner',
    description: 'Manage your farm, crops, market listings, and finances',
    href: '/owner/login',
    emoji: '🌾',
    tint: 'bg-green-100',
    btn: 'bg-green-600 hover:bg-green-700',
  },
  {
    role: 'farmer',
    title: 'Farmer',
    description: 'Find farm work opportunities and apply for jobs',
    href: '/farmer/login',
    emoji: '🧑‍🌾',
    tint: 'bg-amber-100',
    btn: 'bg-amber-600 hover:bg-amber-700',
  },
  {
    role: 'buyer',
    title: 'Buyer',
    description: 'Browse and purchase fresh farm products',
    href: '/buyer/login',
    emoji: '🚚',
    tint: 'bg-blue-100',
    btn: 'bg-blue-600 hover:bg-blue-700',
  },
]

export default function Landing() {
  return (
    <div className="hero-photo hero-photo-img relative min-h-screen">
      {/* Scrim keeps the white text readable whatever photo is used */}
      <div className="hero-scrim absolute inset-0" aria-hidden />

      <div className="relative flex min-h-screen flex-col">
        {/* Brand */}
        <header className="flex items-center gap-2.5 px-5 py-5">
          <LeafMark size={34} />
          <div>
            <p className="text-[19px] font-bold leading-none tracking-tight text-white">FARMS</p>
            <p className="mt-1 text-[11px] font-medium text-white/75">
              Barangay Pagatban, Bayawan City
            </p>
          </div>
        </header>

        {/* Role choice */}
        <main className="flex flex-1 items-center justify-center px-5 pb-10">
          <div className="w-full max-w-3xl">
            <h1 className="text-center text-[22px] font-bold text-white drop-shadow-sm sm:text-[26px]">
              Welcome to FARMS
            </h1>
            <p className="mt-1.5 text-center text-[14px] text-white/85">
              Pumili kung paano mo gagamitin ang FARMS
            </p>

            <div className="mt-6 grid gap-3.5 sm:grid-cols-3">
              {ROLES.map((r, i) => (
                <Link
                  key={r.role}
                  to={r.href}
                  style={{ animationDelay: `${i * 70}ms` }}
                  className="card group flex animate-fade-up flex-col items-center gap-3 rounded-2xl
                             p-6 text-center transition hover:-translate-y-1 hover:shadow-xl"
                >
                  <span
                    className={`flex h-16 w-16 items-center justify-center rounded-full text-3xl ${r.tint}`}
                    aria-hidden
                  >
                    {r.emoji}
                  </span>
                  <div>
                    <h2 className="text-[17px] font-bold leading-snug">{r.title}</h2>
                    <p className="mt-1.5 text-[13px] leading-relaxed text-soil-600">
                      {r.description}
                    </p>
                  </div>
                  <span
                    className={`btn mt-auto w-full justify-center py-3 text-white ${r.btn}`}
                  >
                    Sign In
                  </span>
                </Link>
              ))}
            </div>
          </div>
        </main>
      </div>
    </div>
  )
}
