import { useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { friendlyError } from '@/lib/validation'

/**
 * The farm owner's choice: is geofencing used for this farm's time clock?
 *
 * On  - workers can time in and out only from a phone, inside the purok of the job.
 * Off - workers can time in and out from anywhere; no location is asked for or kept.
 *
 * It saves the moment it is clicked.
 */
export function GeofenceSwitch() {
  const { farm, refresh } = useAuth()
  const [busy, setBusy] = useState(false)
  if (!farm) return null

  const on = farm.require_gps !== false

  async function flip() {
    if (busy || !farm) return
    setBusy(true)
    const { error } = await supabase.from('farms').update({ require_gps: !on }).eq('id', farm.id)
    if (error) {
      toast.error(friendlyError(error))
    } else {
      await refresh()
      toast.success(
        on
          ? 'Geofencing is off. Workers can time in and out from anywhere.'
          : 'Geofencing is on. Workers must be inside the purok to time in and out.',
      )
    }
    setBusy(false)
  }

  return (
    <div className={`card flex items-start gap-4 p-4 ${on ? '' : 'border-amber-300'}`}>
      <div className="flex-1">
        <p className="flex flex-wrap items-center gap-2 text-[15px] font-bold text-soil-900">
          Geofencing
          <span className="chip bg-soil-100 text-soil-600">Optional</span>
        </p>
        <p className="mt-1 text-[13px] leading-relaxed text-soil-600">
          {on ? (
            <>
              <span className="font-semibold text-green-700">On.</span> Workers can record time in and
              out only from a phone, while inside the purok of the job.
            </>
          ) : (
            <>
              <span className="font-semibold text-amber-800">Off.</span> Workers can record time in and
              out from anywhere. No location is asked for or stored, and shifts read &ldquo;Not
              checked&rdquo; in your work log.
            </>
          )}
        </p>
      </div>

      <button
        type="button"
        role="switch"
        aria-checked={on}
        aria-label="Geofencing"
        onClick={flip}
        disabled={busy}
        className={`relative h-9 w-[5.25rem] shrink-0 rounded-full text-[12px] font-bold text-white shadow-inner transition disabled:opacity-60 ${
          on ? 'bg-green-600' : 'bg-soil-400'
        }`}
      >
        <span className={`absolute top-1/2 -translate-y-1/2 ${on ? 'left-3' : 'right-3'}`}>
          {on ? 'ON' : 'OFF'}
        </span>
        <span
          aria-hidden
          className={`absolute top-1 h-7 w-7 rounded-full bg-white shadow transition-all ${
            on ? 'left-[3.25rem]' : 'left-1'
          }`}
        />
      </button>
    </div>
  )
}
