import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Select } from '@/components/ui'

export interface Purok {
  id: string
  number: number
  name: string
  latitude: number | null
  longitude: number | null
}

let cache: Purok[] | null = null

export function usePuroks() {
  const [puroks, setPuroks] = useState<Purok[]>(cache ?? [])

  useEffect(() => {
    if (cache) return
    supabase
      .from('puroks')
      .select('id, number, name, latitude, longitude')
      .order('number')
      .then(({ data }) => {
        cache = (data as Purok[]) ?? []
        setPuroks(cache)
      })
  }, [])

  return puroks
}

export function PurokSelect({
  label = 'Purok',
  value,
  error,
  onChange,
  className,
  hint,
}: {
  label?: string
  value: string
  error?: string | null
  onChange: (id: string) => void
  className?: string
  hint?: string
}) {
  const puroks = usePuroks()

  return (
    <div className={className}>
      <Select
        label={label}
        value={value}
        error={error}
        onChange={(e) => onChange(e.target.value)}
        options={[
          { value: '', label: 'Choose a purok…' },
          ...puroks.map((p) => ({ value: p.id, label: p.name })),
        ]}
      />
      {hint && !error && <p className="mt-1.5 text-[12px] text-soil-400">{hint}</p>}
    </div>
  )
}

export function PurokFromPin({
  latitude,
  longitude,
  onDetected,
}: {
  latitude: string
  longitude: string
  onDetected: (id: string) => void
}) {
  const [found, setFound] = useState<{
    id: string
    name: string
    exact: boolean
    distance_m?: number
  } | null>(null)

  useEffect(() => {
    if (!latitude || !longitude) {
      setFound(null)
      return
    }
    supabase
      .rpc('purok_at', { p_lat: Number(latitude), p_lng: Number(longitude) })
      .then(({ data }) => setFound((data as typeof found) ?? null))
  }, [latitude, longitude])

  if (!found) return null

  return (
    <button
      type="button"
      onClick={() => onDetected(found.id)}
      className="mt-2 w-full rounded-lg border border-brand-200 bg-brand-50 px-3.5 py-2.5 text-left transition hover:bg-brand-100"
    >
      <span className="block text-[13px] font-bold text-brand-900">
        {found.exact ? `This pin is inside ${found.name}` : `Nearest purok: ${found.name}`}
      </span>
      <span className="block text-[12px] text-brand-900/70">
        {found.exact
          ? 'Tap to use it'
          : `About ${found.distance_m} m from its centre. Tap to use it, or choose another.`}
      </span>
    </button>
  )
}
