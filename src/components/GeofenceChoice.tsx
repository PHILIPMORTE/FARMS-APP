/**
 * Asked when a job is posted: should this job be geofenced?
 *
 * Yes - workers can record time in and out only from a phone, inside the purok of the job.
 * No  - workers can record time in and out from anywhere; no location is asked for or kept.
 */
export function GeofenceChoice({
  value,
  onChange,
  purok,
}: {
  value: boolean
  onChange(next: boolean): void
  purok?: string
}) {
  const option = (on: boolean, title: string, body: string) => {
    const selected = value === on
    return (
      <button
        type="button"
        role="radio"
        aria-checked={selected}
        onClick={() => onChange(on)}
        className={`flex flex-1 items-start gap-2.5 rounded-xl border-2 p-3 text-left transition ${
          selected
            ? on
              ? 'border-green-600 bg-green-50'
              : 'border-amber-500 bg-amber-50'
            : 'border-soil-200 bg-white hover:border-soil-300'
        }`}
      >
        <span
          aria-hidden
          className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border-2 text-[11px] font-bold text-white ${
            selected ? (on ? 'border-green-600 bg-green-600' : 'border-amber-500 bg-amber-500') : 'border-soil-300 bg-white'
          }`}
        >
          {selected ? '\u2713' : ''}
        </span>
        <span>
          <span className="block text-[14px] font-bold text-soil-900">{title}</span>
          <span className="block text-[12px] leading-snug text-soil-600">{body}</span>
        </span>
      </button>
    )
  }

  return (
    <div>
      <p className="label flex items-center gap-2">
        Geofence this job?
        <span className="chip bg-soil-100 text-soil-600">Optional</span>
      </p>
      <div className="flex flex-col gap-2 sm:flex-row" role="radiogroup" aria-label="Geofence this job">
        {option(true, 'Yes, geofence it', 'Workers must be inside the purok to time in and out.')}
        {option(false, 'No, do not geofence', 'Workers can time in and out from anywhere.')}
      </div>
      <p className="mt-1.5 text-[12px] leading-relaxed text-soil-500">
        {value
          ? `Workers can record time in and out only from a phone, while inside ${purok || 'the purok you chose'}.`
          : 'No location is asked for or stored. Shifts for this job read \u201cNot checked\u201d in your work log.'}
      </p>
    </div>
  )
}
