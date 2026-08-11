import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, Dialog, Empty, Search, Spinner, TextArea } from '@/components/ui'
import { CROP_EMOJI, peso, shortDate, titleCase } from '@/lib/format'
import { friendlyError } from '@/lib/validation'
import type { JobApplication, JobPost, JobType } from '@/lib/types'

const FILTERS: { value: 'all' | JobType; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'seasonal', label: 'Seasonal' },
  { value: 'part-time', label: 'Part-time' },
  { value: 'full-time', label: 'Full-time' },
]

export default function FarmerJobs() {
  const { profile } = useAuth()
  const [jobs, setJobs] = useState<JobPost[] | null>(null)
  const [mine, setMine] = useState<Map<string, JobApplication>>(new Map())
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<'all' | JobType>('all')
  const [details, setDetails] = useState<JobPost | null>(null)
  const [applyTo, setApplyTo] = useState<JobPost | null>(null)

  const load = useCallback(async () => {
    const [{ data: posts }, { data: apps }] = await Promise.all([
      supabase
        .from('job_posts')
        .select('*, farms(name, city, province)')
        .order('created_at', { ascending: false }),
      profile
        ? supabase.from('job_applications').select('*').eq('farmer_id', profile.id)
        : Promise.resolve({ data: [] as JobApplication[] }),
    ])

    setJobs((posts as unknown as JobPost[]) ?? [])
    setMine(new Map(((apps as JobApplication[]) ?? []).map((a) => [a.job_id, a])))
  }, [profile?.id])

  useEffect(() => {
    load()

    // Live job board: a farm owner's new post lands here without a refresh.
    const channel = supabase
      .channel('farmer-job-board')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_posts' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  const filtered = useMemo(() => {
    if (!jobs) return []
    const q = query.trim().toLowerCase()
    return jobs.filter((j) => {
      if (filter !== 'all' && j.type !== filter) return false
      if (!q) return true
      return (
        j.title.toLowerCase().includes(q) ||
        j.crop.toLowerCase().includes(q) ||
        j.location.toLowerCase().includes(q) ||
        (j.farms?.name ?? '').toLowerCase().includes(q)
      )
    })
  }, [jobs, query, filter])

  if (!jobs) return <Spinner label="Loading the job board" />

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Find jobs</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Farm work across the country. New posts appear here as farms publish them.
        </p>
      </div>

      <Search value={query} onChange={setQuery} placeholder="Search title, crop or location" />

      <div className="flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <button
            key={f.value}
            onClick={() => setFilter(f.value)}
            aria-pressed={filter === f.value}
            className={`chip border transition ${
              filter === f.value
                ? 'border-brand-700 bg-brand-700 text-white'
                : 'border-soil-200 bg-white text-soil-600 hover:bg-soil-100'
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      {filtered.length === 0 ? (
        <Empty
          title="No jobs match"
          body="Try a different crop, a nearby town, or clear the filters to see everything."
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((j) => {
            const app = mine.get(j.id)
            const openForApplications = j.status === 'open'
            const remaining = Math.max(0, j.slots - j.filled_slots)

            return (
              <article
                key={j.id}
                className={`card flex flex-col gap-3 p-4 ${!openForApplications ? 'opacity-60' : ''}`}
              >
                <div className="flex items-start justify-between gap-3">
                  <span className="text-2xl" aria-hidden>
                    {CROP_EMOJI[j.crop]}
                  </span>
                  {openForApplications ? (
                    <Badge tone="brand">{j.type}</Badge>
                  ) : (
                    <Badge tone="grey">No longer accepting</Badge>
                  )}
                </div>

                <div>
                  <h3 className="text-base font-bold leading-snug">{j.title}</h3>
                  <p className="mt-0.5 text-[13px] text-soil-600">{j.farms?.name ?? 'Farm'}</p>
                  <p className="text-[13px] text-soil-400">{j.location}</p>
                </div>

                {j.description && (
                  <p className="line-clamp-2 text-[13px] leading-relaxed text-soil-600">
                    {j.description}
                  </p>
                )}

                <div className="mt-auto flex items-end justify-between border-t border-soil-200/70 pt-3">
                  <div>
                    <p className="num text-lg font-bold text-brand-700">{peso(j.wage)}</p>
                    <p className="text-[12px] text-soil-400">per day</p>
                  </div>
                  <div className="text-right">
                    <p className="num text-lg font-bold">{remaining}</p>
                    <p className="text-[12px] text-soil-400">
                      {remaining === 1 ? 'slot left' : 'slots left'}
                    </p>
                  </div>
                </div>

                <p className="text-[12px] text-soil-400">Starts {shortDate(j.start_date)}</p>

                <div className="grid grid-cols-2 gap-2">
                  <button className="btn-ghost" onClick={() => setDetails(j)}>
                    View details
                  </button>
                  {app?.status === 'accepted' ? (
                    <span className="btn bg-green-100 text-green-800">Hired ✓</span>
                  ) : app ? (
                    <button className="btn bg-soil-100 text-soil-400" disabled>
                      Applied ✓
                    </button>
                  ) : openForApplications && remaining > 0 ? (
                    <button className="btn-primary" onClick={() => setApplyTo(j)}>
                      Apply now
                    </button>
                  ) : (
                    <button className="btn bg-soil-100 text-soil-400" disabled>
                      Closed
                    </button>
                  )}
                </div>
              </article>
            )
          })}
        </div>
      )}

      {/* Details */}
      <Dialog
        open={details !== null}
        onClose={() => setDetails(null)}
        title={details?.title ?? ''}
        description={details?.farms?.name ?? undefined}
      >
        {details && (
          <div className="space-y-4">
            <div className="flex flex-wrap gap-2">
              <Badge tone="brand">{details.type}</Badge>
              <Badge>
                {CROP_EMOJI[details.crop]}&nbsp;
                {details.crop === 'general' ? 'General farm work' : titleCase(details.crop)}
              </Badge>
              <Badge tone={details.status === 'open' ? 'green' : 'grey'}>
                {titleCase(details.status)}
              </Badge>
            </div>

            <p className="whitespace-pre-line text-[14px] leading-relaxed text-soil-800">
              {details.description || 'The farm did not add a description for this job.'}
            </p>

            <dl className="grid grid-cols-2 gap-3 border-t border-soil-200/70 pt-4 text-sm">
              <Row label="Daily wage" value={peso(details.wage)} />
              <Row
                label="Slots left"
                value={String(Math.max(0, details.slots - details.filled_slots))}
              />
              <Row label="Location" value={details.location} />
              <Row label="Starts" value={shortDate(details.start_date)} />
              {details.end_date && <Row label="Ends" value={shortDate(details.end_date)} />}
            </dl>
          </div>
        )}
      </Dialog>

      <ApplyDialog
        job={applyTo}
        farmerId={profile?.id ?? ''}
        onClose={() => setApplyTo(null)}
        onApplied={() => {
          setApplyTo(null)
          load()
        }}
      />
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-[12px] font-bold uppercase tracking-wide text-soil-400">{label}</dt>
      <dd className="num mt-0.5 font-semibold">{value}</dd>
    </div>
  )
}

function ApplyDialog({
  job,
  farmerId,
  onClose,
  onApplied,
}: {
  job: JobPost | null
  farmerId: string
  onClose(): void
  onApplied(): void
}) {
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (job) setMessage('')
  }, [job?.id])

  async function submit() {
    if (!job) return
    setBusy(true)
    const { error } = await supabase.from('job_applications').insert({
      job_id: job.id,
      farmer_id: farmerId,
      message: message.trim() || null,
      status: 'pending',
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Application sent')
    onApplied()
  }

  return (
    <Dialog
      open={job !== null}
      onClose={onClose}
      title="Apply for this job"
      description={job ? `${job.title} · ${job.farms?.name ?? 'Farm'}` : undefined}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Sending…' : 'Send application'}
          </button>
        </>
      }
    >
      <TextArea
        label="Message to the farm"
        placeholder="Tell them about your experience with this kind of work."
        max={300}
        value={message}
        onChange={(e) => setMessage(e.target.value)}
      />
      <p className="mt-2 text-[13px] text-soil-400">
        Optional, but a short note helps. The farm can also see your skills and availability from
        your account.
      </p>
    </Dialog>
  )
}
