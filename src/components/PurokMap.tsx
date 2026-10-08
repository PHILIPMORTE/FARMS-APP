import { useEffect, useRef } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'

export interface PurokMapProps {
  /** Boundary as stored: an array of [longitude, latitude] pairs. */
  boundary: number[][] | null
  /** Name shown on the boundary, e.g. "Purok 2". */
  purokName?: string | null
  /** Where the farmer is now, if the device has reported a position. */
  here?: { lat: number; lng: number; acc: number } | null
  /** Whether the farmer is currently allowed to record time. */
  inside?: boolean
  /** The farm pin, drawn when the farm has one. */
  farm?: { lat: number; lng: number; name?: string | null } | null
  height?: number
}

export function PurokMap({
  boundary,
  purokName,
  here,
  inside = false,
  farm,
  height = 260,
}: PurokMapProps) {
  const holder = useRef<HTMLDivElement | null>(null)
  const map = useRef<L.Map | null>(null)
  const shape = useRef<L.Polygon | null>(null)
  const dot = useRef<L.CircleMarker | null>(null)
  const halo = useRef<L.Circle | null>(null)
  const farmPin = useRef<L.Marker | null>(null)

  // create the map once
  useEffect(() => {
    if (!holder.current || map.current) return

    map.current = L.map(holder.current, {
      zoomControl: true,
      attributionControl: true,
      scrollWheelZoom: false,
    })

    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '© OpenStreetMap contributors',
    }).addTo(map.current)

    map.current.setView([9.3764, 122.741], 15)

    return () => {
      map.current?.remove()
      map.current = null
    }
  }, [])

  // draw the purok
  useEffect(() => {
    const m = map.current
    if (!m) return

    shape.current?.remove()
    shape.current = null

    if (!boundary || boundary.length < 3) return

    // stored as [lng, lat]; Leaflet wants [lat, lng]
    const ring: L.LatLngExpression[] = boundary.map(([lng, lat]) => [lat, lng])

    shape.current = L.polygon(ring, {
      color: inside ? '#15803d' : '#b45309',
      weight: 2.5,
      fillColor: inside ? '#22c55e' : '#f59e0b',
      fillOpacity: 0.18,
    }).addTo(m)

    if (purokName) {
      shape.current.bindTooltip(purokName, {
        permanent: true,
        direction: 'center',
        className: 'purok-label',
      })
    }

    m.fitBounds(shape.current.getBounds(), { padding: [24, 24] })
  }, [boundary, purokName, inside])

  // the farm pin
  useEffect(() => {
    const m = map.current
    if (!m) return
    farmPin.current?.remove()
    farmPin.current = null
    if (!farm) return

    farmPin.current = L.marker([farm.lat, farm.lng], {
      icon: L.divIcon({
        className: '',
        html:
          '<div style="width:14px;height:14px;border-radius:3px;background:#1f2937;' +
          'border:2px solid #fff;box-shadow:0 0 0 1px #1f2937"></div>',
        iconSize: [14, 14],
        iconAnchor: [7, 7],
      }),
    })
      .addTo(m)
      .bindTooltip(farm.name ?? 'Farm', { direction: 'top' })
  }, [farm?.lat, farm?.lng])

  // the farmer's position, redrawn as it moves
  useEffect(() => {
    const m = map.current
    if (!m) return

    dot.current?.remove()
    halo.current?.remove()
    dot.current = null
    halo.current = null

    if (!here) return

    const colour = inside ? '#15803d' : '#b45309'

    halo.current = L.circle([here.lat, here.lng], {
      radius: Math.max(here.acc, 5),
      color: colour,
      weight: 1,
      fillColor: colour,
      fillOpacity: 0.12,
    }).addTo(m)

    dot.current = L.circleMarker([here.lat, here.lng], {
      radius: 7,
      color: '#ffffff',
      weight: 2,
      fillColor: colour,
      fillOpacity: 1,
    })
      .addTo(m)
      .bindTooltip('You are here', { direction: 'top' })

    // keep both the purok and the farmer in view
    if (shape.current) {
      const b = shape.current.getBounds().extend([here.lat, here.lng])
      m.fitBounds(b, { padding: [28, 28], maxZoom: 17 })
    } else {
      m.setView([here.lat, here.lng], 16)
    }
  }, [here?.lat, here?.lng, here?.acc, inside])

  return (
    <div>
      <div
        ref={holder}
        style={{ height }}
        className="w-full overflow-hidden rounded-xl border border-soil-200"
        role="img"
        aria-label={
          purokName
            ? `Map showing ${purokName}${here ? ', with your position marked' : ''}`
            : 'Map of the work area'
        }
      />
      <p className="mt-1.5 text-[12px] leading-relaxed text-soil-500">
        {boundary && boundary.length >= 3 ? (
          <>
            The shaded area is {purokName ?? 'the work area'}. You can record your time only from
            inside it.
          </>
        ) : (
          <>This job has no mapped area, so the distance from the farm is used instead.</>
        )}
      </p>
    </div>
  )
}
