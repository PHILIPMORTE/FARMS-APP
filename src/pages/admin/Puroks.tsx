import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Badge, DataTable, Dialog, Field, SectionHeading, Spinner, Stat, TextArea } from '@/components/ui'
import { friendlyError } from '@/lib/validation'

interface Purok {
  id: string
  number: number
  name: string
  latitude: number | null
  longitude: number | null
  boundary: number[][] | null
}

export default function AdminPuroks() {
  const [rows, setRows] = useState<Purok[] | null>(null)
  const [editing, setEditing] = useState<Purok | null>(null)
  const [centre, setCentre] = useState({ lat: '', lng: '' })
  const [paste, setPaste] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('puroks')
      .select('id, number, name, latitude, longitude, boundary')
      .order('number')
    setRows((data as Purok[]) ?? [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  function open(p: Purok) {
    setEditing(p)
    setCentre({
      lat: p.latitude != null ? String(p.latitude) : '',
      lng: p.longitude != null ? String(p.longitude) : '',
    })
    setPaste(p.boundary ? JSON.stringify(p.boundary) : '')
  }

  function parsePoint(text: string): { lat: number; lng: number } | null {
    const t = text.trim()
    if (!t) return null

    let parsed: unknown
    try {
      parsed = JSON.parse(t)
    } catch {
      return null
    }

    const any = parsed as Record<string, unknown>
    let geom: Record<string, unknown> | null = null

    if (any?.type === 'FeatureCollection') {
      const f = (any.features as Record<string, unknown>[])?.[0]
      geom = f?.geometry as Record<string, unknown>
    } else if (any?.type === 'Feature') {
      geom = any.geometry as Record<string, unknown>
    } else if (any?.type === 'Point') {
      geom = any
    }

    if (geom?.type !== 'Point') return null
    const c = geom.coordinates as number[]
    if (!Array.isArray(c) || typeof c[0] !== 'number') return null
    return { lng: c[0], lat: c[1] }
  }

  function parseBoundary(text: string): number[][] | null {
    const t = text.trim()
    if (!t) return null

    let parsed: unknown
    try {
      parsed = JSON.parse(t)
    } catch {
      throw new Error('That is not valid JSON. Copy the whole block from geojson.io.')
    }

    const any = parsed as Record<string, unknown>
    let ring: unknown = parsed

    if (any?.type === 'FeatureCollection') {
      const f = (any.features as Record<string, unknown>[])?.[0]
      ring = ((f?.geometry as Record<string, unknown>)?.coordinates as unknown[])?.[0]
    } else if (any?.type === 'Feature') {
      ring = ((any.geometry as Record<string, unknown>)?.coordinates as unknown[])?.[0]
    } else if (any?.type === 'Polygon') {
      ring = (any.coordinates as unknown[])?.[0]
    }

    if (!Array.isArray(ring) || ring.length < 3) {
      throw new Error(
        'That is a marker, not an area. Use the polygon tool in geojson.io to draw around the purok, or paste the marker into the centre point box instead.',
      )
    }

    const pts = ring.map((pair) => {
      const [lng, lat] = pair as number[]
      if (typeof lng !== 'number' || typeof lat !== 'number') {
        throw new Error('The points are not numbers. Copy the GeoJSON exactly as it appears.')
      }
      return [lng, lat]
    })

    const bad = pts.find(([lng, lat]) => lat < 4 || lat > 22 || lng < 115 || lng > 128)
    if (bad) {
      throw new Error(
        `A point sits outside the Philippines (${bad[1]}, ${bad[0]}). Check you drew in the right place, and that longitude comes before latitude.`,
      )
    }

    return pts
  }

  function pastePointAsCentre() {
    const pt = parsePoint(paste)
    if (!pt) {
      toast.error('No marker found in that text. Drop a pin in geojson.io and copy the result.')
      return
    }
    setCentre({ lat: pt.lat.toFixed(7), lng: pt.lng.toFixed(7) })
    setPaste('')
    toast.success('Centre point set from the marker')
  }

  async function save() {
    if (!editing) return

    let boundary: number[][] | null
    try {
      boundary = parseBoundary(paste)
    } catch (err) {
      toast.error(String((err as Error).message))
      return
    }

    setBusy(true)
    const { error } = await supabase
      .from('puroks')
      .update({
        latitude: centre.lat ? Number(centre.lat) : null,
        longitude: centre.lng ? Number(centre.lng) : null,
        boundary,
      })
      .eq('id', editing.id)
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(`${editing.name} saved`)
    setEditing(null)
    load()
  }

  if (!rows) return <Spinner label="Loading puroks" />

  const traced = rows.filter((r) => r.boundary && r.boundary.length >= 3).length
  const pinned = rows.filter((r) => r.latitude != null).length

  const preview =
    editing && centre.lat && centre.lng
      ? `https://maps.google.com/maps?q=${centre.lat},${centre.lng}&z=15&output=embed`
      : null

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Puroks</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          The eight puroks of Barangay Pagatban. Give each one a centre point, and a traced
          boundary if you have it, so farms can be placed automatically from their map pin.
        </p>
      </div>

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="Puroks" value={String(rows.length)} />
        <Stat label="Centre pinned" value={`${pinned}/${rows.length}`} />
        <Stat
          label="Boundary traced"
          value={`${traced}/${rows.length}`}
          accent={traced === rows.length ? 'green' : undefined}
        />
      </div>

      <section className="card p-5">
        <SectionHeading>How to trace a boundary</SectionHeading>
        <ol className="list-decimal space-y-1.5 pl-5 text-[14px] leading-relaxed text-soil-700">
          <li>
            Open{' '}
            <a
              href="https://geojson.io"
              target="_blank"
              rel="noreferrer"
              className="font-semibold text-brand-700 hover:underline"
            >
              geojson.io
            </a>{' '}
            and search for Bayawan City, then find Pagatban.
          </li>
          <li>Switch to satellite view so you can see roads, houses and field edges.</li>
          <li>
            Pick the <strong>polygon</strong> tool, not the marker, and click around the edge of
            one purok, then click the first point again to close the shape.
          </li>
          <li>Copy everything from the JSON panel on the right.</li>
          <li>Come back here, open that purok, and paste it in.</li>
        </ol>
        <p className="mt-3 rounded-lg bg-brand-50 px-3.5 py-2.5 text-[13px] leading-relaxed text-brand-900">
          <strong>In a hurry?</strong> Drop a marker at the middle of each purok instead and paste
          it into the box below, then press the centre-point button. Farms are then matched to the
          nearest purok. Draw proper boundaries later for exact placement.
        </p>

        <p className="mt-2 rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px] leading-relaxed text-soil-600">
          Rough boundaries are fine. They only need to be good enough to tell one purok from its
          neighbours. Ask at the barangay hall if you are unsure where a line runs.
        </p>
      </section>

      <DataTable
        minWidth="40rem"
        headers={[
          { label: 'Purok' },
          { label: 'Centre point' },
          { label: 'Boundary' },
          { label: '', align: 'right' },
        ]}
      >
        {rows.map((p) => (
          <tr key={p.id}>
            <td className="px-4 py-3 font-semibold">{p.name}</td>
            <td className="num px-4 py-3 text-soil-600">
              {p.latitude != null
                ? `${Number(p.latitude).toFixed(5)}, ${Number(p.longitude).toFixed(5)}`
                : '—'}
            </td>
            <td className="px-4 py-3">
              {p.boundary && p.boundary.length >= 3 ? (
                <Badge tone="green">{p.boundary.length} points</Badge>
              ) : (
                <Badge tone="grey">Not traced</Badge>
              )}
            </td>
            <td className="px-4 py-3 text-right">
              <button
                className="btn-sm border border-soil-200 hover:bg-soil-100"
                onClick={() => open(p)}
              >
                Edit
              </button>
            </td>
          </tr>
        ))}
      </DataTable>

      <Dialog
        open={editing !== null}
        onClose={() => setEditing(null)}
        title={editing?.name ?? 'Purok'}
        description="Centre point and traced boundary"
        footer={
          <>
            <button className="btn-ghost" onClick={() => setEditing(null)}>
              Cancel
            </button>
            <button className="btn-primary" onClick={save} disabled={busy}>
              {busy ? 'Saving…' : 'Save'}
            </button>
          </>
        }
      >
        <div className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Centre latitude"
              placeholder="9.3810"
              inputMode="decimal"
              value={centre.lat}
              onChange={(e) => setCentre((c) => ({ ...c, lat: e.target.value }))}
            />
            <Field
              label="Centre longitude"
              placeholder="122.7339"
              inputMode="decimal"
              value={centre.lng}
              onChange={(e) => setCentre((c) => ({ ...c, lng: e.target.value }))}
            />
          </div>

          {preview && (
            <iframe
              title="Purok centre"
              className="h-48 w-full rounded-lg border border-soil-200"
              loading="lazy"
              referrerPolicy="no-referrer-when-downgrade"
              src={preview}
            />
          )}

          <button
            type="button"
            className="btn-ghost w-full py-2.5 text-[13px]"
            onClick={pastePointAsCentre}
          >
            Use a pasted marker as the centre point
          </button>

          <TextArea
            label="Boundary from geojson.io"
            rows={5}
            placeholder='Paste the whole JSON, or just the coordinates like [[122.73,9.38],[122.74,9.38],...]'
            value={paste}
            onChange={(e) => setPaste(e.target.value)}
          />

          <p className="rounded-lg bg-soil-50 px-3.5 py-2.5 text-[12px] leading-relaxed text-soil-600">
            Leave the boundary empty to use the centre point only. Farms will then be matched to
            the nearest purok rather than the one they sit inside.
          </p>
        </div>
      </Dialog>
    </div>
  )
}
