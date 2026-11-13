/**
 * The rules of the time clock's location check.
 *
 * They live here, apart from the page, so the page and the tests use the same
 * code, and so the page asks the same questions the database asks before it
 * accepts a time in or time out.
 */

export interface ClockPlace {
  /** The owner's choice for this job. When false, no location is asked for or checked. */
  geofenced: boolean | null
  max_accuracy_m: number | null
  latitude: number | null
  longitude: number | null
  radius_m: number | null
  /** Corner points as [longitude, latitude] pairs, from the job's purok. */
  purok_boundary: number[][] | null
}

export interface Fix {
  lat: number
  lng: number
  /** Accuracy of the reading, in metres. */
  acc: number
}

/**
 * - unchecked: the owner has the location check off, or there is nothing to check against
 * - waiting: the check is on but the device has not given a position yet
 * - inaccurate: the position is too rough to trust
 * - outside: the farmer is not inside the purok, or not near the farm
 * - ok: the farmer is where the job is
 */
export type Verdict = 'unchecked' | 'waiting' | 'inaccurate' | 'outside' | 'ok'

export function hasBoundary(pl: Pick<ClockPlace, 'purok_boundary'> | null | undefined): boolean {
  return !!(pl && pl.purok_boundary && pl.purok_boundary.length >= 3)
}

/** Ray casting, the same test the database performs. */
export function insideBoundary(lat: number, lng: number, ring: number[][]): boolean {
  if (!ring || ring.length < 3) return false
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i]
    const [xj, yj] = ring[j]
    if (yi > lat !== yj > lat && lng < ((xj - xi) * (lat - yi)) / (yj - yi || 1e-12) + xi) {
      inside = !inside
    }
  }
  return inside
}

export function metresBetween(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const R = 6371000
  const p1 = (aLat * Math.PI) / 180
  const p2 = (bLat * Math.PI) / 180
  const dp = ((bLat - aLat) * Math.PI) / 180
  const dl = ((bLng - aLng) * Math.PI) / 180
  const a = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2
  return Math.round(R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)))
}

/** Whether the farm owner's location check applies to this job at all. */
export function usesLocationCheck(pl: ClockPlace | null | undefined): boolean {
  if (!pl) return false
  if (pl.geofenced === false) return false
  return hasBoundary(pl) || (pl.latitude != null && pl.longitude != null)
}

export function checkPlace(pl: ClockPlace | null | undefined, fix: Fix | null): Verdict {
  if (!pl || !usesLocationCheck(pl)) return 'unchecked'
  if (!fix) return 'waiting'
  if (fix.acc > (pl.max_accuracy_m ?? 75)) return 'inaccurate'
  if (hasBoundary(pl)) {
    return insideBoundary(fix.lat, fix.lng, pl.purok_boundary as number[][]) ? 'ok' : 'outside'
  }
  const d = metresBetween(fix.lat, fix.lng, Number(pl.latitude), Number(pl.longitude))
  return d <= (pl.radius_m ?? 300) ? 'ok' : 'outside'
}

/** The button may be used when nothing is being checked, or the check passes. */
export const canRecord = (v: Verdict): boolean => v === 'unchecked' || v === 'ok'

/** The server accepts time in and out from a phone only, because a computer cannot place itself well. */
export function isPhone(): boolean {
  if (typeof navigator === 'undefined') return false
  const uaData = (navigator as unknown as { userAgentData?: { mobile?: boolean } }).userAgentData
  if (uaData && typeof uaData.mobile === 'boolean') return uaData.mobile
  return /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent)
}
