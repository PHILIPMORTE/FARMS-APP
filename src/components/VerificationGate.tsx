import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Field, SectionHeading, Select, Spinner, TextArea } from '@/components/ui'
import { shortDate } from '@/lib/format'
import { friendlyError, validateRequired } from '@/lib/validation'
import type { OwnerVerification, Role, VerificationStatus } from '@/lib/types'
import type { ReactNode } from 'react'

const ID_TYPES = [
  'PhilSys National ID',
  "Driver's Licence",
  'UMID / SSS',
  'Postal ID',
  'Voter’s ID',
  'Barangay Certificate',
  'Other government ID',
]

export function VerificationGate({ role, children }: { role: Role; children: ReactNode }) {
  const { profile } = useAuth()
  const [record, setRecord] = useState<OwnerVerification | null>(null)
  const [status, setStatus] = useState<VerificationStatus | 'none' | null>(null)

  async function load() {
    if (!profile) return
    const { data } = await supabase
      .from('owner_verifications')
      .select('*')
      .eq('profile_id', profile.id)
      .maybeSingle()

    setRecord((data as OwnerVerification) ?? null)
    setStatus(((data as OwnerVerification)?.status as VerificationStatus) ?? 'none')
  }

  useEffect(() => {
    load()
    if (!profile) return

    const channel = supabase
      .channel(`verification-${profile.id}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'owner_verifications',
          filter: `profile_id=eq.${profile.id}`,
        },
        () => load(),
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [profile?.id])

  if (status === null) return <Spinner label="Checking your verification" />
  if (status === 'approved') return <>{children}</>

  return <VerificationScreen role={role} status={status} record={record} onSubmitted={load} />
}

const ROLE_WORD: Record<Role, string> = {
  owner: 'Farm Owner',
  farmer: 'Farmer',
  buyer: 'Buyer',
  admin: 'Administrator',
}

function VerificationScreen({
  role,
  status,
  record,
  onSubmitted,
}: {
  role: Role
  status: VerificationStatus | 'none'
  record: OwnerVerification | null
  onSubmitted(): void
}) {
  const { profile, signOut } = useAuth()
  const [form, setForm] = useState({
    full_name: '',
    id_type: ID_TYPES[0],
    id_number: '',
    farm_name: '',
    farm_address: '',
    barangay: 'Pagatban, Bayawan City',
    farm_size_ha: '',
    latitude: '',
    longitude: '',
    notes: '',
  })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)
  const [idFile, setIdFile] = useState<File | null>(null)
  const [selfie, setSelfie] = useState<File | null>(null)
  const [selfiePreview, setSelfiePreview] = useState<string | null>(null)

  useEffect(() => {
    if (!selfie) return
    const url = URL.createObjectURL(selfie)
    setSelfiePreview(url)
    return () => URL.revokeObjectURL(url)
  }, [selfie])
  const [preview, setPreview] = useState<string | null>(null)
  const [uploading, setUploading] = useState(false)
  const [locating, setLocating] = useState(false)
  const [summary, setSummary] = useState<{ field: string; message: string }[]>([])

  useEffect(() => {
    if (!idFile) return
    const url = URL.createObjectURL(idFile)
    setPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [idFile])

  useEffect(() => {
    if (!record?.id_photo_path) return
    supabase.storage
      .from('verification-ids')
      .createSignedUrl(record.id_photo_path, 600)
      .then(({ data }) => {
        if (data?.signedUrl) setPreview((prev) => prev ?? data.signedUrl)
      })
  }, [record?.id_photo_path])

  useEffect(() => {
    setForm((f) => ({
      ...f,
      full_name: record?.full_name || profile?.name || '',
      id_type: record?.id_type || ID_TYPES[0],
      id_number: record?.id_number || '',
      farm_name: record?.farm_name || '',
      farm_address: record?.farm_address || '',
      barangay: record?.barangay || 'Pagatban, Bayawan City',
      farm_size_ha: record?.farm_size_ha ? String(record.farm_size_ha) : '',
      latitude: record?.latitude != null ? String(record.latitude) : '',
      longitude: record?.longitude != null ? String(record.longitude) : '',
      notes: record?.notes || '',
    }))
  }, [record?.id, profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  if (status === 'pending') {
    return (
      <Shell
        icon="⏳"
        title="Verification under review"
        body={`An administrator is checking your details. You will be notified as soon as your ${ROLE_WORD[role]} account is approved, usually within a working day.`}
        onSignOut={signOut}
      >
        {record && (
          <dl className="mt-4 space-y-2 rounded-lg bg-soil-50 px-4 py-3 text-[13px]">
            <Row label="Submitted" value={shortDate(record.submitted_at)} />
            <Row label="Farm" value={record.farm_name || '—'} />
            <Row label="ID presented" value={record.id_type} />
          </dl>
        )}
      </Shell>
    )
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    const next = {
      full_name: validateRequired(form.full_name, 'Full name'),
      id_photo: idFile || record?.id_photo_path ? null : 'Upload a photo of your ID.',
      selfie: selfie || record?.selfie_path ? null : 'Take a photo of yourself holding your ID.',
      farm_name: role === 'owner' ? validateRequired(form.farm_name, 'Farm name') : null,
      latitude:
        role === 'owner' && !form.latitude ? 'Pin your farm so buyers can find it.' : null,
      longitude: role === 'owner' && !form.longitude ? 'Longitude is missing.' : null,
      farm_address: role === 'owner' ? validateRequired(form.farm_address, 'Farm address') : null,
      barangay: validateRequired(form.barangay, 'Barangay'),
    }
    setErrors(next)

    const problems = Object.entries(next).filter(([, v]) => v)
    if (problems.length > 0) {
      setSummary(problems.map(([k, v]) => ({ field: k, message: String(v) })))
      window.setTimeout(() => {
        document.getElementById('form-problems')?.scrollIntoView({
          behavior: 'smooth',
          block: 'center',
        })
      }, 0)
      return
    }
    setSummary([])

    setBusy(true)

    let photoPath = record?.id_photo_path ?? null
    if (idFile) {
      setUploading(true)
      const { data: session } = await supabase.auth.getSession()
      const uid = session.session?.user.id
      const ext = idFile.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `${uid}/id-${Date.now()}.${ext}`
      const { error: upError } = await supabase.storage
        .from('verification-ids')
        .upload(path, idFile, { upsert: true, contentType: idFile.type })
      setUploading(false)

      if (upError) {
        setBusy(false)
        toast.error(`Photo upload failed: ${upError.message}`)
        return
      }
      photoPath = path
    }

    let selfiePath = record?.selfie_path ?? null
    if (selfie) {
      setUploading(true)
      const { data: session } = await supabase.auth.getSession()
      const uid = session.session?.user.id
      const ext = selfie.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `${uid}/selfie-${Date.now()}.${ext}`
      const { error: upError } = await supabase.storage
        .from('verification-ids')
        .upload(path, selfie, { upsert: true, contentType: selfie.type })
      setUploading(false)
      if (upError) {
        setBusy(false)
        toast.error(`Selfie upload failed: ${upError.message}`)
        return
      }
      selfiePath = path
    }

    const payload = {
      profile_id: profile.id,
      role,
      status: 'pending' as const,
      full_name: form.full_name.trim(),
      id_type: form.id_type,
      id_number: null,
      id_photo_path: photoPath,
      selfie_path: selfiePath,
      farm_name: form.farm_name.trim(),
      farm_address: form.farm_address.trim(),
      barangay: form.barangay.trim(),
      latitude: form.latitude ? Number(form.latitude) : null,
      longitude: form.longitude ? Number(form.longitude) : null,
      farm_size_ha: form.farm_size_ha ? Number(form.farm_size_ha) : null,
      notes: form.notes.trim() || null,
      review_notes: null,
    }

    const { error } = record
      ? await supabase.from('owner_verifications').update(payload).eq('id', record.id)
      : await supabase.from('owner_verifications').insert(payload)

    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Verification submitted for review')
    onSubmitted()
  }

  return (
    <Shell
      icon={status === 'rejected' ? '⚠️' : '🔒'}
      title={
        status === 'rejected'
          ? 'Verification not approved'
          : `Verify your ${ROLE_WORD[role]} account`
      }
      body={
        status === 'rejected'
          ? 'Your details could not be verified. Correct them below and submit again.'
          : 'Every account is verified before it is activated. Give your details below and an administrator will review them.'
      }
      onSignOut={signOut}
    >
      {status === 'rejected' && record?.review_notes && (
        <div className="mt-4 rounded-lg border border-red-200 bg-red-50 px-4 py-3">
          <p className="text-[13px] font-semibold text-red-800">Reason given</p>
          <p className="mt-0.5 text-[13px] leading-relaxed text-red-700">{record.review_notes}</p>
        </div>
      )}

      <form onSubmit={submit} className="mt-5 space-y-5 text-left" noValidate>
        {summary.length > 0 && (
          <div
            id="form-problems"
            role="alert"
            className="animate-fade-up rounded-xl border-2 border-red-300 bg-red-50 px-4 py-3.5"
          >
            <p className="text-[14px] font-bold text-red-800">
              {summary.length === 1
                ? 'One thing still needs filling in'
                : `${summary.length} things still need filling in`}
            </p>
            <ul className="mt-1.5 space-y-1">
              {summary.map((pr) => (
                <li key={pr.field}>
                  <button
                    type="button"
                    onClick={() => {
                      const el =
                        document.getElementById(pr.field) ??
                        document.querySelector<HTMLElement>(`[name="${pr.field}"]`)
                      el?.scrollIntoView({ behavior: 'smooth', block: 'center' })
                      el?.focus()
                    }}
                    className="text-left text-[13px] font-medium text-red-700 underline decoration-red-300 hover:decoration-red-700"
                  >
                    {pr.message}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}

        <section>
          <SectionHeading>Your identity</SectionHeading>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Full legal name"
              className="sm:col-span-2"
              value={form.full_name}
              error={errors.full_name}
              onChange={(e) => set('full_name', e.target.value)}
            />
            <Select
              label="ID type"
              className="sm:col-span-2"
              value={form.id_type}
              onChange={(e) => set('id_type', e.target.value)}
              options={ID_TYPES.map((t) => ({ value: t, label: t }))}
            />

            <div className="sm:col-span-2">
              <label className="label" htmlFor="idphoto">
                Photo of your ID
              </label>

              {preview ? (
                <div className="overflow-hidden rounded-xl border border-soil-200">
                  <img src={preview} alt="Your uploaded ID" className="max-h-64 w-full object-contain bg-soil-50" />
                  <div className="flex items-center justify-between gap-3 border-t border-soil-200 px-3 py-2">
                    <span className="text-[12px] text-soil-600">
                      {idFile ? idFile.name : 'Uploaded earlier'}
                    </span>
                    <button
                      type="button"
                      onClick={() => {
                        setIdFile(null)
                        setPreview(null)
                      }}
                      className="text-[13px] font-semibold text-red-600 hover:underline"
                    >
                      Replace
                    </button>
                  </div>
                </div>
              ) : (
                <label
                  htmlFor="idphoto"
                  className={`flex cursor-pointer flex-col items-center gap-1.5 rounded-xl border-2 border-dashed
                              px-4 py-8 text-center transition hover:bg-soil-50 ${
                                errors.id_photo ? 'border-red-400' : 'border-soil-200'
                              }`}
                >
                  <span className="text-3xl" aria-hidden>
                    📷
                  </span>
                  <span className="text-[14px] font-semibold">Take or choose a photo</span>
                  <span className="text-[12px] text-soil-400">
                    Make sure the name and number are readable. JPG or PNG, up to 5 MB.
                  </span>
                </label>
              )}

              <input
                id="idphoto"
                type="file"
                accept="image/jpeg,image/png,image/webp"
                capture="environment"
                className="sr-only"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (!f) return
                  if (f.size > 5 * 1024 * 1024) {
                    setErrors((x) => ({ ...x, id_photo: 'That photo is over 5 MB. Try a smaller one.' }))
                    return
                  }
                  setIdFile(f)
                  setErrors((x) => ({ ...x, id_photo: null }))
                }}
              />
              {errors.id_photo && <p className="err">{errors.id_photo}</p>}
            </div>

            <div className="sm:col-span-2">
              <label className="label" htmlFor="selfie">
                Photo of yourself holding your ID
              </label>

              {selfiePreview ? (
                <div className="overflow-hidden rounded-xl border border-soil-200">
                  <img
                    src={selfiePreview}
                    alt="You holding your ID"
                    className="max-h-64 w-full bg-soil-50 object-contain"
                  />
                  <div className="flex items-center justify-between gap-3 border-t border-soil-200 px-3 py-2">
                    <span className="text-[12px] text-soil-600">{selfie?.name}</span>
                    <button
                      type="button"
                      onClick={() => setSelfie(null)}
                      className="text-[13px] font-semibold text-red-600 hover:underline"
                    >
                      Retake
                    </button>
                  </div>
                </div>
              ) : (
                <label
                  htmlFor="selfie"
                  className={`flex cursor-pointer flex-col items-center gap-1.5 rounded-xl border-2 border-dashed
                              px-4 py-8 text-center transition hover:bg-soil-50 ${
                                errors.selfie ? 'border-red-400' : 'border-soil-200'
                              }`}
                >
                  <span className="text-3xl" aria-hidden>
                    🤳
                  </span>
                  <span className="text-[14px] font-semibold">Take a selfie with your ID</span>
                  <span className="text-[12px] leading-relaxed text-soil-400">
                    Hold your ID next to your face so the administrator can see the person on the ID
                    is you. Good light, no sunglasses or hat.
                  </span>
                </label>
              )}

              <input
                id="selfie"
                type="file"
                accept="image/jpeg,image/png,image/webp"
                capture="user"
                className="sr-only"
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  if (!f) return
                  if (f.size > 5 * 1024 * 1024) {
                    setErrors((x) => ({ ...x, selfie: 'That photo is over 5 MB.' }))
                    return
                  }
                  setSelfie(f)
                  setErrors((x) => ({ ...x, selfie: null }))
                }}
              />
              {errors.selfie && <p className="err">{errors.selfie}</p>}
            </div>
          </div>
        </section>

        <section className={role === 'owner' ? '' : 'hidden'}>
          <SectionHeading>Your farm</SectionHeading>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Farm name"
              className="sm:col-span-2"
              value={form.farm_name}
              error={errors.farm_name}
              onChange={(e) => set('farm_name', e.target.value)}
            />
            <Field
              label="Farm address"
              className="sm:col-span-2"
              placeholder="Purok / sitio, street"
              value={form.farm_address}
              error={errors.farm_address}
              onChange={(e) => set('farm_address', e.target.value)}
            />
            <Field
              label="Barangay / city"
              value={form.barangay}
              error={errors.barangay}
              onChange={(e) => set('barangay', e.target.value)}
            />
            <div className="sm:col-span-2">
              <label className="label">Pin your farm on the map</label>
              <div className="rounded-xl border border-soil-200 p-4">
                <p className="text-[13px] leading-relaxed text-soil-600">
                  Buyers see this marker so they can find you. Stand at your farm and tap the button
                  below, or open Google Maps, long-press your farm, and copy the two numbers.
                </p>

                <button
                  type="button"
                  className="btn-ghost mt-3 w-full py-2.5 text-[13px]"
                  disabled={locating}
                  onClick={() => {
                    if (!navigator.geolocation) {
                      toast.error('This device cannot share its location.')
                      return
                    }
                    setLocating(true)
                    navigator.geolocation.getCurrentPosition(
                      (pos) => {
                        set('latitude', pos.coords.latitude.toFixed(6))
                        set('longitude', pos.coords.longitude.toFixed(6))
                        setLocating(false)
                        toast.success('Location captured')
                      },
                      () => {
                        setLocating(false)
                        toast.error('Could not read your location. Type the numbers instead.')
                      },
                      { enableHighAccuracy: true, timeout: 10000 },
                    )
                  }}
                >
                  {locating ? 'Finding you…' : '📍 Use my current location'}
                </button>

                <div className="mt-3 grid gap-4 sm:grid-cols-2">
                  <Field
                    label="Latitude"
                    placeholder="9.3644"
                    inputMode="decimal"
                    value={form.latitude}
                    error={errors.latitude}
                    onChange={(e) => set('latitude', e.target.value)}
                  />
                  <Field
                    label="Longitude"
                    placeholder="122.8064"
                    inputMode="decimal"
                    value={form.longitude}
                    error={errors.longitude}
                    onChange={(e) => set('longitude', e.target.value)}
                  />
                </div>

                {form.latitude && form.longitude ? (
                  <>
                    <iframe
                      title="Your farm location"
                      className="mt-3 h-56 w-full rounded-lg border border-soil-200"
                      loading="lazy"
                      referrerPolicy="no-referrer-when-downgrade"
                      src={`https://maps.google.com/maps?q=${form.latitude},${form.longitude}&z=15&output=embed`}
                    />
                    <p className="mt-2 text-center text-[12px] text-soil-500">
                      Check the marker sits on your farm. Adjust the numbers if it does not.
                    </p>
                  </>
                ) : (
                  <p className="mt-3 rounded-lg bg-soil-50 px-3.5 py-3 text-center text-[13px] text-soil-500">
                    No location set yet
                  </p>
                )}
              </div>
            </div>

            <Field
              label="Farm size (hectares)"
              type="number"
              min="0"
              step="0.01"
              inputMode="decimal"
              placeholder="Optional"
              value={form.farm_size_ha}
              onChange={(e) => set('farm_size_ha', e.target.value)}
            />
          </div>
        </section>

        {role !== 'owner' && (
          <Field
            label="Barangay / city"
            value={form.barangay}
            error={errors.barangay}
            onChange={(e) => set('barangay', e.target.value)}
          />
        )}

        <TextArea
          label="Anything else the reviewer should know"
          max={300}
          placeholder="Optional"
          value={form.notes}
          onChange={(e) => set('notes', e.target.value)}
        />

        <button className="btn-primary w-full" disabled={busy}>
          {uploading ? 'Uploading photo…' : busy ? 'Submitting…' : 'Submit for verification'}
        </button>
      </form>
    </Shell>
  )
}

function Shell({
  icon,
  title,
  body,
  children,
  onSignOut,
}: {
  icon: string
  title: string
  body: string
  children?: ReactNode
  onSignOut(): void
}) {
  return (
    <div className="mx-auto max-w-2xl">
      <div className="card p-6 text-center sm:p-8">
        <span className="text-4xl" aria-hidden>
          {icon}
        </span>
        <h1 className="mt-3 text-[22px] font-bold">{title}</h1>
        <p className="mx-auto mt-2 max-w-md text-[14px] leading-relaxed text-soil-600">{body}</p>
        {children}
      </div>
      <div className="mt-4 text-center">
        <button onClick={onSignOut} className="text-[13px] font-semibold text-soil-600 hover:underline">
          Sign out
        </button>
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-soil-600">{label}</dt>
      <dd className="font-semibold">{value}</dd>
    </div>
  )
}
