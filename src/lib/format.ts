import type { Crop, JobCrop, Role } from './types'

export const KG_PER_SACK = 25

export const CROP_EMOJI: Record<JobCrop, string> = {
  rice: '🌾',
  corn: '🌽',
  watermelon: '🍉',
  general: '🧑‍🌾',
}

export const CROPS: Crop[] = ['rice', 'corn', 'watermelon']

/** Duration in months from planting to harvest, per crop. */
export const CROP_DURATION: Record<Crop, number> = { rice: 4, corn: 3, watermelon: 3 }

export const ROLE_HOME: Record<Role, string> = {
  owner: '/owner/dashboard',
  farmer: '/farmer/jobs',
  buyer: '/buyer/market',
}

export const ROLE_LABEL: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
}

/**
 * The one place sacks become a number. Everything that reads a sack value from
 * a form, a database row, or a calculation goes through here, so a decimal can
 * never reach the UI or the database.
 */
export function toSacks(value: unknown): number {
  const n = typeof value === 'number' ? value : parseInt(String(value ?? ''), 10)
  if (!Number.isFinite(n)) return 0
  return Math.floor(n)
}

/** Renders a sack count. Always an integer, never a trailing .0 */
export function sacks(value: unknown): string {
  return toSacks(value).toLocaleString('en-PH', { maximumFractionDigits: 0 })
}

/** "12 sacks" / "1 sack" */
export function sacksLabel(value: unknown): string {
  const n = toSacks(value)
  return `${sacks(n)} ${n === 1 ? 'sack' : 'sacks'}`
}

/** "12 sacks = 300 kg" */
export function weightNote(value: unknown): string {
  const n = toSacks(value)
  return `${sacks(n)} ${n === 1 ? 'sack' : 'sacks'} = ${(n * KG_PER_SACK).toLocaleString('en-PH')} kg`
}

/** Philippine Peso. Money is genuinely decimal, unlike sacks. */
export function peso(value: number | string | null | undefined): string {
  const n = Number(value ?? 0)
  return `₱${(Number.isFinite(n) ? n : 0).toLocaleString('en-PH', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`
}

/** Compact peso for stat tiles: ₱1.2M, ₱45.5K */
export function pesoShort(value: number | null | undefined): string {
  const n = Number(value ?? 0)
  if (Math.abs(n) >= 1_000_000) return `₱${(n / 1_000_000).toFixed(1)}M`
  if (Math.abs(n) >= 10_000) return `₱${(n / 1000).toFixed(1)}K`
  return peso(n)
}

export function shortDate(value: string | null | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleDateString('en-PH', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
}

export function relativeDate(value: string): string {
  const diff = Date.now() - new Date(value).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'Just now'
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `${hrs}h ago`
  const days = Math.floor(hrs / 24)
  if (days < 7) return `${days}d ago`
  return shortDate(value)
}

export function monthLabel(ym: string): string {
  const [y, m] = ym.split('-').map(Number)
  if (!y || !m) return ym
  return new Date(y, m - 1, 1).toLocaleDateString('en-PH', { month: 'long', year: 'numeric' })
}

/** Adds `months` to a 'YYYY-MM' string and returns the same format. */
export function addMonths(ym: string, months: number): string {
  const [y, m] = ym.split('-').map(Number)
  const d = new Date(y, m - 1 + months, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
}

export function initials(name: string): string {
  return (
    name
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((w) => w[0]?.toUpperCase() ?? '')
      .join('') || '?'
  )
}

export function titleCase(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}
