import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  Dialog,
  Empty,
  Field,
  PesoInput,
  Select,
  Spinner,
  TextArea,
} from '@/components/ui'
import { CROP_EMOJI, peso, relativeDate, shortDate, titleCase,
  todayISO,
} from '@/lib/format'
import { displayPhone, friendlyError, validateAmount, validateRequired, validateWholeNumber } from '@/lib/validation'
import type { AppStatus, JobApplication, JobCrop, JobPost, JobType } from '@/lib/types'

const JOB_TYPES: JobType[] = ['seasonal', 'part-time', 'full-time']
const JOB_CROPS: JobCrop[] = ['rice', 'corn', 'watermelon', 'general']


export default function OwnerJobs() {
  const { profile, farm } = useAuth()
  const [tab, setTab] = useState<'posts' | 'apps'>('posts')
  const [posts, setPosts] = useState<JobPost[] | null>(null)
  const [apps, setApps] = useState<JobApplication[] | null>(null)
  const [dialog, setDialog] = useState(false)

  async function load() {
    if (!profile) return
    const { data: jobs } = await supabase
      .from('job_posts')
      .select('*')
      .eq('owner_id', profile.id)
      .order('created_at', { ascending: false })

    setPosts((jobs as JobPost[]) ?? [])

    const ids = (jobs ?? []).map((j) => j.id)
    if (!ids.length) {
      setApps([])
      return
    }
    const { data: applications } = await supabase
      .from('job_applications')
      .select('*, job_posts(*), profiles(*)')
      .in('job_id', ids)
      .order('applied_at', { ascending: false })

    const rows = (applications as unknown as JobApplication[]) ?? []

    const farmerIds = [...new Set(rows.map((r) => r.farmer_id))]
    if (farmerIds.length) {
      const { data: fps } = await supabase.from('farmer_profiles').select('*').in('id', farmerIds)
      const byId = new Map((fps ?? []).map((f: any) => [f.id, f]))
      rows.forEach((r) => {
        r.farmer_profiles = byId.get(r.farmer_id) ?? null
      })
    }

    setApps(rows)
  }

  useEffect(() => {
    load()
    if (!profile) return
    const channel = supabase
      .channel(`owner-jobs:${profile.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_applications' }, () => load())
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [profile?.id])

  if (!posts || !apps) return <Spinner label="Loading your job posts" />

  const pending = apps.filter((a) => a.status === 'pending').length

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Jobs</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            Post work and review who applies. Farmers see open posts straight away.
          </p>
        </div>
        <button className="btn-primary" onClick={() => setDialog(true)}>
          Post a job
        </button>
      </div>

      <div role="tablist" className="grid grid-cols-2 gap-1 rounded-xl bg-soil-100 p-1">
        <button
          role="tab"
          aria-selected={tab === 'posts'}
          onClick={() => setTab('posts')}
          className={`rounded-lg px-3 py-2.5 text-sm font-bold transition ${
            tab === 'posts' ? 'bg-white shadow-sm' : 'text-soil-600'
          }`}
        >
          My job posts
        </button>
        <button
          role="tab"
          aria-selected={tab === 'apps'}
          onClick={() => setTab('apps')}
          className={`rounded-lg px-3 py-2.5 text-sm font-bold transition ${
            tab === 'apps' ? 'bg-white shadow-sm' : 'text-soil-600'
          }`}
        >
          Applications
          {pending > 0 && (
            <span className="num ml-1.5 rounded-full bg-red-600 px-1.5 py-0.5 text-[10px] text-white">
              {pending}
            </span>
          )}
        </button>
      </div>

      {tab === 'posts' ? (
        <PostsTab posts={posts} apps={apps} onChanged={load} onAdd={() => setDialog(true)} />
      ) : (
        <ApplicationsTab posts={posts} apps={apps} onChanged={load} />
      )}

      <PostJobDialog
        open={dialog}
        onClose={() => setDialog(false)}
        farmId={farm?.id ?? ''}
        ownerId={profile?.id ?? ''}
        defaultLocation={[farm?.city, farm?.province].filter(Boolean).join(', ')}
        onSaved={() => {
          setDialog(false)
          load()
        }}
      />
    </div>
  )
}

function PostsTab({
  posts,
  apps,
  onChanged,
  onAdd,
}: {
  posts: JobPost[]
  apps: JobApplication[]
  onChanged(): void
  onAdd(): void
}) {
  const [confirming, setConfirming] = useState<JobPost | null>(null)
  const [deleting, setDeleting] = useState(false)

  async function remove() {
    if (!confirming) return
    setDeleting(true)
    const { error } = await supabase.rpc('delete_job_post', { p_job_id: confirming.id })
    setDeleting(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Job post deleted')
    setConfirming(null)
    onChanged()
  }

  if (posts.length === 0) {
    return (
      <Empty
        title="No job posts yet"
        body="Post the work you need doing — planting, harvesting, driving — and farmers can apply."
        action={
          <button className="btn-primary" onClick={onAdd}>
            Post a job
          </button>
        }
      />
    )
  }

  async function toggle(post: JobPost) {
    const next = post.status === 'closed' ? 'open' : 'closed'
    const { error } = await supabase.from('job_posts').update({ status: next }).eq('id', post.id)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(next === 'open' ? 'Job reopened' : 'Job closed')
    onChanged()
  }

  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {posts.map((p) => {
        const count = apps.filter((a) => a.job_id === p.id).length
        const remaining = Math.max(0, p.slots - p.filled_slots)
        return (
          <article key={p.id} className="card flex flex-col gap-3 p-4">
            <div className="flex items-start justify-between gap-3">
              <span className="text-2xl" aria-hidden>
                {CROP_EMOJI[p.crop]}
              </span>
              <Badge
                tone={p.status === 'open' ? 'green' : p.status === 'filled' ? 'blue' : 'grey'}
              >
                {titleCase(p.status)}
              </Badge>
            </div>

            <div>
              <h3 className="text-base font-bold leading-snug">{p.title}</h3>
              <p className="mt-0.5 text-[13px] text-soil-400">
                {p.location} · starts {shortDate(p.start_date)}
              </p>
            </div>

            <div className="flex flex-wrap gap-2">
              <Badge tone="brand">{p.type}</Badge>
              <Badge>
                <span className="num">{peso(p.wage)}</span>&nbsp;a day
              </Badge>
            </div>

            <div className="mt-auto flex items-end justify-between border-t border-soil-200/70 pt-3">
              <div>
                <p className="num text-lg font-bold">
                  {remaining}
                  <span className="text-sm font-semibold text-soil-400">/{p.slots}</span>
                </p>
                <p className="text-[12px] text-soil-400">slots left</p>
              </div>
              <div className="text-right">
                <p className="num text-lg font-bold">{count}</p>
                <p className="text-[12px] text-soil-400">
                  {count === 1 ? 'applicant' : 'applicants'}
                </p>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <button className="btn-ghost" onClick={() => toggle(p)}>
                {p.status === 'closed' ? 'Reopen post' : 'Close post'}
              </button>
              <button
                className="btn-ghost text-red-600 hover:bg-red-50"
                onClick={() => setConfirming(p)}
              >
                Delete
              </button>
            </div>
          </article>
        )
      })}

      <Dialog
        open={confirming !== null}
        onClose={() => setConfirming(null)}
        title="Delete this job post?"
        description={confirming?.title}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setConfirming(null)}>
              Keep post
            </button>
            <button className="btn-danger" onClick={remove} disabled={deleting}>
              {deleting ? 'Deleting…' : 'Delete post'}
            </button>
          </>
        }
      >
        <div className="space-y-3 text-[14px] leading-relaxed text-soil-800">
          <p>
            The post and its {apps.filter((a) => a.job_id === confirming?.id).length} application
            {apps.filter((a) => a.job_id === confirming?.id).length === 1 ? '' : 's'} will be
            removed. Everyone who applied is notified.
          </p>

          {confirming && confirming.filled_slots > 0 && (
            <p className="rounded-lg border border-amber-200 bg-amber-50 px-3.5 py-3 text-[13px] text-amber-900">
              You already hired {confirming.filled_slots}{' '}
              {confirming.filled_slots === 1 ? 'person' : 'people'} for this job. Their wages stay
              recorded in Finance — deleting the post does not change your expenses. Call them to
              explain before deleting.
            </p>
          )}

          <p className="text-[13px] text-soil-600">This cannot be undone.</p>
        </div>
      </Dialog>
    </div>
  )
}

function ApplicationsTab({
  posts,
  apps,
  onChanged,
}: {
  posts: JobPost[]
  apps: JobApplication[]
  onChanged(): void
}) {
  const [job, setJob] = useState('all')
  const [status, setStatus] = useState('all')
  const [busy, setBusy] = useState<string | null>(null)

  const filtered = useMemo(
    () =>
      apps.filter(
        (a) => (job === 'all' || a.job_id === job) && (status === 'all' || a.status === status),
      ),
    [apps, job, status],
  )

  async function decide(id: string, decision: AppStatus) {
    setBusy(id)
    const { error } = await supabase.rpc('decide_application', {
      p_application_id: id,
      p_decision: decision,
    })
    setBusy(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(decision === 'accepted' ? 'Applicant hired' : 'Application rejected')
    onChanged()
  }

  return (
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select
          label="Job post"
          value={job}
          onChange={(e) => setJob(e.target.value)}
          options={[
            { value: 'all', label: 'All job posts' },
            ...posts.map((p) => ({ value: p.id, label: p.title })),
          ]}
        />
        <Select
          label="Status"
          value={status}
          onChange={(e) => setStatus(e.target.value)}
          options={[
            { value: 'all', label: 'All statuses' },
            { value: 'pending', label: 'Pending' },
            { value: 'accepted', label: 'Accepted' },
            { value: 'rejected', label: 'Rejected' },
          ]}
        />
      </div>

      {filtered.length === 0 ? (
        <Empty
          title="No applications here"
          body={
            apps.length === 0
              ? 'When a farmer applies to one of your posts, they show up here.'
              : 'Nothing matches these filters. Try widening them.'
          }
        />
      ) : (
        <div className="grid gap-3 lg:grid-cols-2">
          {filtered.map((a) => {
            const fp = a.farmer_profiles
            return (
              <article key={a.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h3 className="text-base font-bold">{a.profiles?.name ?? 'Farmer'}</h3>
                    <p className="num text-[13px] text-soil-600">
                      {displayPhone(a.profiles?.phone)}
                    </p>
                  </div>
                  <Badge
                    tone={
                      a.status === 'accepted' ? 'green' : a.status === 'rejected' ? 'red' : 'amber'
                    }
                  >
                    {titleCase(a.status)}
                  </Badge>
                </div>

                <p className="text-[13px] font-semibold text-soil-600">
                  Applied for {a.job_posts?.title} · {relativeDate(a.applied_at)}
                </p>

                {a.message && (
                  <p className="rounded-xl bg-soil-50 px-3.5 py-3 text-[14px] leading-relaxed text-soil-800">
                    {a.message}
                  </p>
                )}

                <div className="flex flex-wrap gap-2">
                  {fp?.availability && (
                    <Badge tone={fp.availability === 'available' ? 'green' : 'grey'}>
                      {titleCase(fp.availability)}
                    </Badge>
                  )}
                  {typeof fp?.experience_years === 'number' && (
                    <Badge>
                      <span className="num">{fp.experience_years}</span>&nbsp;
                      {fp.experience_years === 1 ? 'year' : 'years'} experience
                    </Badge>
                  )}
                  {(fp?.skills ?? []).map((s) => (
                    <Badge key={s} tone="brand">
                      {s}
                    </Badge>
                  ))}
                </div>

                {a.profiles?.phone && (
                  <div className="flex gap-2 border-t border-soil-200/70 pt-3">
                    <a
                      href={`tel:${a.profiles.phone}`}
                      className="btn-ghost flex-1 py-2 text-[13px]"
                    >
                      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z" />
                      </svg>
                      Call
                    </a>
                    <a
                      href={`sms:${a.profiles.phone}`}
                      className="btn-ghost flex-1 py-2 text-[13px]"
                    >
                      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.9-.9L3 21l2-4.1A8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z" />
                      </svg>
                      Text
                    </a>
                  </div>
                )}

                {a.status === 'pending' && (
                  <div className="grid grid-cols-2 gap-2 border-t border-soil-200/70 pt-3">
                    <button
                      className="btn-primary"
                      disabled={busy === a.id}
                      onClick={() => decide(a.id, 'accepted')}
                    >
                      Accept
                    </button>
                    <button
                      className="btn-ghost"
                      disabled={busy === a.id}
                      onClick={() => decide(a.id, 'rejected')}
                    >
                      Reject
                    </button>
                  </div>
                )}
              </article>
            )
          })}
        </div>
      )}
    </div>
  )
}

function PostJobDialog({
  open,
  onClose,
  farmId,
  ownerId,
  defaultLocation,
  onSaved,
}: {
  open: boolean
  onClose(): void
  farmId: string
  ownerId: string
  defaultLocation: string
  onSaved(): void
}) {
  const [form, setForm] = useState({
    title: '',
    description: '',
    crop: 'general' as JobCrop,
    type: 'seasonal' as JobType,
    wage: '',
    slots: '',
    location: defaultLocation,
    start_date: todayISO(),
    end_date: '',
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      title: validateRequired(form.title, 'Job title'),
      wage: validateAmount(form.wage, 'daily wage'),

      slots: validateWholeNumber(form.slots, 1, 'number of slots'),
      location: validateRequired(form.location, 'Location'),
      start_date: form.start_date ? null : 'Pick a start date.',
      end_date:
        form.end_date && form.end_date < form.start_date
          ? 'The end date cannot come before the start date.'
          : null,
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    const { error } = await supabase.from('job_posts').insert({
      farm_id: farmId,
      owner_id: ownerId,
      title: form.title.trim(),
      description: form.description.trim(),
      crop: form.crop,
      type: form.type,
      wage: Number(form.wage),
      slots: parseInt(form.slots, 10),
      location: form.location.trim(),
      start_date: form.start_date,
      end_date: form.end_date || null,
      status: 'open',
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Job posted')
    setForm((f) => ({ ...f, title: '', description: '', wage: '', slots: '' }))
    onSaved()
  }

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Post a job"
      description="Open posts appear on the farmer job board immediately."
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Posting…' : 'Post job'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <Field
          label="Job title"
          placeholder="e.g. Rice harvest crew"
          value={form.title}
          error={errors.title}
          onChange={(e) => set('title', e.target.value)}
        />
        <TextArea
          label="Description"
          placeholder="What the work involves, hours, what to bring"
          value={form.description}
          onChange={(e) => set('description', e.target.value)}
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => set('crop', e.target.value)}
            options={JOB_CROPS.map((c) => ({
              value: c,
              label: `${CROP_EMOJI[c]} ${c === 'general' ? 'General farm work' : titleCase(c)}`,
            }))}
          />
          <Select
            label="Job type"
            value={form.type}
            onChange={(e) => set('type', e.target.value)}
            options={JOB_TYPES.map((t) => ({ value: t, label: titleCase(t) }))}
          />
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <PesoInput
            label="Daily wage"
            placeholder="0.00"
            value={form.wage}
            error={errors.wage}
            onChange={(e) => set('wage', e.target.value)}
          />
          <div>
            <label className="label" htmlFor="slots">
              Number of slots
            </label>
            <input
              id="slots"
              type="number"
              step="1"
              min="1"
              inputMode="numeric"
              placeholder="0"
              className={`field num ${errors.slots ? 'field-error' : ''}`}
              value={form.slots}
              onKeyDown={(e) => ['.', ',', 'e', 'E', '+', '-'].includes(e.key) && e.preventDefault()}
              onChange={(e) => set('slots', e.target.value)}
            />
            {errors.slots ? (
              <p className="err">{errors.slots}</p>
            ) : (
              <p className="mt-1.5 text-[13px] text-soil-400">How many workers you need</p>
            )}
          </div>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label className="label" htmlFor="sd">
              Start date
            </label>
            <input
              id="sd"
              type="date"
              className={`field num ${errors.start_date ? 'field-error' : ''}`}
              value={form.start_date}
              onChange={(e) => set('start_date', e.target.value)}
            />
            {errors.start_date && <p className="err">{errors.start_date}</p>}
          </div>
          <div>
            <label className="label" htmlFor="ed">
              End date
            </label>
            <input
              id="ed"
              type="date"
              className={`field num ${errors.end_date ? 'field-error' : ''}`}
              value={form.end_date}
              onChange={(e) => set('end_date', e.target.value)}
            />
            {errors.end_date ? (
              <p className="err">{errors.end_date}</p>
            ) : (
              <p className="mt-1.5 text-[13px] text-soil-400">Optional</p>
            )}
          </div>
        </div>

        <Field
          label="Location"
          placeholder="Barangay, city or municipality"
          value={form.location}
          error={errors.location}
          onChange={(e) => set('location', e.target.value)}
        />
      </form>
    </Dialog>
  )
}
