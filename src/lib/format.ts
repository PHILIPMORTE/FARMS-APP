import type { AttendanceStatus, Crop, JobCrop, OrderStage, OrderStatus, Role } from './types'

export const KG_PER_SACK = 25

export const CROP_EMOJI: Record<JobCrop, string> = {
  rice: '🌾',
  corn: '🌽',
  watermelon: '🍉',
  general: '🧑‍🌾',
}

export const CROPS: Crop[] = ['rice', 'corn', 'watermelon']

export const VARIETIES: Record<Crop, string[]> = {
  rice: [
    'Dinorado',
    'Sinandomeng',
    'Jasmine',
    'Milagrosa',
    'IR64',
    'NSIC Rc222 (Tubigan 18)',
    'NSIC Rc160',
    'Angelica',
    'Black Rice',
    'Red Rice',
    'Malagkit (Glutinous)',
  ],
  corn: [
    'Sweet Corn',
    'White Corn',
    'Yellow Corn',
    'Glutinous Corn (Pilit)',
    'IPB Var 6',
    'Bt Corn',
    'Popcorn',
  ],
  watermelon: [
    'Sweet Beauty',
    'Crimson Sweet',
    'Sugar Baby',
    'Jubilee',
    'Yellow Doll',
    'Seedless Watermelon',
    'Black Beauty',
  ],
}

export const CROP_DURATION: Record<Crop, number> = { rice: 4, corn: 3, watermelon: 3 }

export const CROP_COLOR: Record<Crop, {
  dot: string
  chip: string
  soft: string
  bar: string
  ring: string
  text: string
}> = {
  rice: {
    dot: 'bg-emerald-600',
    chip: 'bg-emerald-100 text-emerald-800',
    soft: 'bg-emerald-50',
    bar: 'bg-emerald-600',
    ring: 'ring-emerald-600',
    text: 'text-emerald-700',
  },
  corn: {
    dot: 'bg-yellow-400',
    chip: 'bg-yellow-100 text-yellow-800',
    soft: 'bg-yellow-50',
    bar: 'bg-yellow-400',
    ring: 'ring-yellow-400',
    text: 'text-yellow-700',
  },
  watermelon: {
    dot: 'bg-red-700',
    chip: 'bg-red-100 text-red-800',
    soft: 'bg-red-50',
    bar: 'bg-red-700',
    ring: 'ring-red-700',
    text: 'text-red-700',
  },
}

export const SCHEDULE_LABEL: Record<string, string> = {
  planned: 'Planned',
  planted: 'Planted',
  growing: 'Growing',
  harvested: 'Harvested',
  cancelled: 'Cancelled',
}

export const SEASON: Record<Crop, number[]> = {
  rice: [4, 5, 6, 7, 10, 11, 0, 1],
  corn: [3, 4, 5, 10, 11, 0],
  watermelon: [11, 0, 1, 2, 3, 4],
}

export function suggestedCrops(monthIndex: number): Crop[] {
  return CROPS.filter((c) => SEASON[c].includes(monthIndex))
}

export function todayISO(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`
}

export function toISODate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`
}

export function daysBetween(a: string, b: string): number {
  return Math.max(0, Math.round((+new Date(b) - +new Date(a)) / 86400000))
}

export function addDays(iso: string, days: number): string {
  const d = new Date(iso)
  d.setDate(d.getDate() + days)
  return toISODate(d)
}

export const ROLE_HOME: Record<Role, string> = {
  owner: '/owner/dashboard',
  farmer: '/farmer/jobs',
  buyer: '/buyer/market',
  admin: '/admin/dashboard',
}

export const ROLE_LABEL: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
  admin: 'Administrator',
}

export const ORDER_STAGES: { stage: OrderStage; label: string; hint: string }[] = [
  { stage: 'confirmed', label: 'Order Confirmed', hint: 'The farm accepted your order' },
  { stage: 'shipped', label: 'Out for Delivery', hint: 'On the way to you' },
  { stage: 'completed', label: 'Completed', hint: 'Order finished' },
]

export const STAGE_LABEL: Record<OrderStage, string> = {
  placed: 'Order Placed',
  confirmed: 'Order Confirmed',
  preparing: 'Out for Delivery',
  ready: 'Out for Delivery',
  shipped: 'Out for Delivery',
  delivered: 'Out for Delivery',
  completed: 'Completed',
  cancelled: 'Cancelled',
}

export function simplifyStage(stage: OrderStage): OrderStage {
  if (stage === 'preparing' || stage === 'ready' || stage === 'delivered') return 'shipped'
  return stage
}

export function stageIndex(stage: OrderStage): number {
  return ORDER_STAGES.findIndex((s) => s.stage === simplifyStage(stage))
}

export function isFinishedOrder(order: { stage?: OrderStage; status?: OrderStatus }): boolean {
  if (order.stage === 'completed' || order.stage === 'cancelled') return true
  return order.status === 'completed' || order.status === 'cancelled'
}

export function effectiveStage(order: { stage?: OrderStage; status?: OrderStatus }): OrderStage {
  if (order.stage && order.stage !== 'placed') return simplifyStage(order.stage)
  if (order.status === 'completed') return 'completed'
  if (order.status === 'cancelled') return 'cancelled'
  return order.stage ?? 'placed'
}

export const ATTENDANCE_LABEL: Record<AttendanceStatus, string> = {
  present: 'Present',
  absent: 'Absent',
  half_day: 'Half day',
  leave: 'On leave',
}

export function hours(value: number | string | null | undefined): string {
  const n = Number(value ?? 0)
  if (!Number.isFinite(n)) return '0'
  return n % 1 === 0 ? String(n) : n.toFixed(2).replace(/0$/, '')
}

export function availableSacks(p: { quantity: number; reserved?: number }): number {
  return Math.max(Math.floor(p.quantity) - Math.floor(p.reserved ?? 0), 0)
}

export function toSacks(value: unknown): number {
  const n = typeof value === 'number' ? value : parseInt(String(value ?? ''), 10)
  if (!Number.isFinite(n)) return 0
  return Math.floor(n)
}

export function sacks(value: unknown): string {
  return toSacks(value).toLocaleString('en-PH', { maximumFractionDigits: 0 })
}

export function sacksLabel(value: unknown): string {
  const n = toSacks(value)
  return `${sacks(n)} ${n === 1 ? 'sack' : 'sacks'}`
}

export function weightNote(value: unknown): string {
  const n = toSacks(value)
  return `${sacks(n)} ${n === 1 ? 'sack' : 'sacks'} = ${(n * KG_PER_SACK).toLocaleString('en-PH')} kg`
}

export function peso(value: number | string | null | undefined): string {
  const n = Number(value ?? 0)
  return `₱${(Number.isFinite(n) ? n : 0).toLocaleString('en-PH', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`
}

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
