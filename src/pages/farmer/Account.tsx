import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth, isPhoneTakenForRole } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Badge, Field, SectionHeading, Spinner, TextArea } from '@/components/ui'
import { titleCase } from '@/lib/format'
import {
  friendlyError,
  normalisePhone,
  validateName,
  validatePhone,
  validateWholeNumber,
} from '@/lib/validation'
import type { Availability, FarmerProfile } from '@/lib/types'

const SUGGESTED = ['Rice Harvesting', 'Planting', 'Irrigation', 'Machinery', 'Driving']
const STATES: Availability[] = ['available', 'busy', 'unavailable']

export default function FarmerAccount() {
  const { profile, refresh } = useAuth()
  const [fp, setFp] = useState<FarmerProfile | null>(null)
  const [form, setForm] = useState<Record<string, string>>({})
  const [skills, setSkills] = useState<string[]>([])
  const [skillDraft, setSkillDraft] = useState('')
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!profile) return
    ;(async () => {
      let { data } = await supabase.from('farmer_profiles').select('*').eq('id', profile.id).maybeSingle()
      if (!data) {
        const { data: created } = await supabase
          .from('farmer_profiles')
          .insert({ id: profile.id, availability: 'available' })
          .select()
          .single()
        data = created
      }
      const row = data as FarmerProfile
      setFp(row)
      setSkills(row?.skills ?? [])
      setForm({
        name: profile.name ?? '',
        phone: profile.phone?.startsWith('+63') ? `0${profile.phone.slice(3)}` : profile.phone ?? '',
        email: profile.email ?? '',
        province: row?.province ?? '',
        city: row?.city ?? '',
        experience_years: String(row?.experience_years ?? 0),
        bio: row?.bio ?? '',
      })
    })()
  }, [profile?.id])

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function setAvailability(next: Availability) {
    if (!profile) return
    setFp((p) => (p ? { ...p, availability: next } : p))
    const { error } = await supabase
      .from('farmer_profiles')
      .update({ availability: next })
      .eq('id', profile.id)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(`You are now ${next}`)
  }

  function addSkill(value: string) {
    const s = value.trim()
    if (!s || skills.includes(s)) return
    setSkills((prev) => [...prev, s])
    setSkillDraft('')
  }

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!profile) return

    const next = {
      name: validateName(form.name),
      phone: validatePhone(form.phone),
      experience_years: validateWholeNumber(form.experience_years, 0, 'number of years'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    const normalised = normalisePhone(form.phone)!

    if (normalised !== profile.phone && (await isPhoneTakenForRole(normalised, 'farmer'))) {
      const msg = 'This number is already registered as a Farmer. Use a different number.'
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    setBusy(true)
    const [p, f] = await Promise.all([
      supabase
        .from('profiles')
        .update({
          name: form.name.trim(),
          phone: normalised,
          email: form.email.trim() || null,
        })
        .eq('id', profile.id),
      supabase
        .from('farmer_profiles')
        .update({
          province: form.province.trim(),
          city: form.city.trim(),
          experience_years: parseInt(form.experience_years, 10),
          bio: form.bio.trim(),
          skills,
        })
        .eq('id', profile.id),
    ])
    setBusy(false)

    const err = p.error ?? f.error
    if (err) {
      const msg = /profiles_phone_role_key/.test(err.message)
        ? 'This number is already registered as a Farmer. Use a different number.'
        : friendlyError(err)
      setErrors({ phone: msg })
      toast.error(msg)
      return
    }

    toast.success('Account saved')
    await refresh()
  }

  if (!profile || !fp) return <Spinner />

  return (
    <div className="space-y-6">
      <h1 className="text-[22px] font-bold">Account</h1>

      <AccountHeader
        extra={
          <span className="mt-1.5 inline-block">
            <Badge tone={fp.availability === 'available' ? 'green' : 'grey'}>
              {titleCase(fp.availability)}
            </Badge>
          </span>
        }
      />

      <section>
        <SectionHeading>Availability</SectionHeading>
        <div className="card grid grid-cols-3 gap-2 p-2">
          {STATES.map((s) => (
            <button
              key={s}
              onClick={() => setAvailability(s)}
              aria-pressed={fp.availability === s}
              className={`rounded-xl px-3 py-2.5 text-sm font-bold transition ${
                fp.availability === s
                  ? 'bg-brand-700 text-white'
                  : 'text-soil-600 hover:bg-soil-100'
              }`}
            >
              {titleCase(s)}
            </button>
          ))}
        </div>
        <p className="mt-2 text-[13px] text-soil-400">
          Farms see this on your applications. It saves the moment you tap it.
        </p>
      </section>

      <form onSubmit={save} className="space-y-5" noValidate>
        <section>
          <SectionHeading>Your details</SectionHeading>
          <div className="card grid gap-4 p-5 sm:grid-cols-2">
            <Field label="Full name" value={form.name ?? ''} error={errors.name} onChange={(e) => set('name', e.target.value)} />
            <Field
              label="Mobile number"
              type="tel"
              inputMode="tel"
              value={form.phone ?? ''}
              error={errors.phone}
              onChange={(e) => set('phone', e.target.value)}
            />
            <Field
              label="Email"
              type="email"
              placeholder="Needed for password resets"
              className="sm:col-span-2"
              value={form.email ?? ''}
              onChange={(e) => set('email', e.target.value)}
            />
            <Field label="Province" value={form.province ?? ''} onChange={(e) => set('province', e.target.value)} />
            <Field label="City or municipality" value={form.city ?? ''} onChange={(e) => set('city', e.target.value)} />
          </div>
        </section>

        <section>
          <SectionHeading>What you can do</SectionHeading>
          <div className="card space-y-4 p-5">
            <div>
              <label className="label" htmlFor="skill">
                Skills
              </label>
              <div className="flex gap-2">
                <input
                  id="skill"
                  className="field"
                  placeholder="Add a skill"
                  value={skillDraft}
                  onChange={(e) => setSkillDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault()
                      addSkill(skillDraft)
                    }
                  }}
                />
                <button type="button" className="btn-ghost shrink-0" onClick={() => addSkill(skillDraft)}>
                  Add
                </button>
              </div>

              {skills.length > 0 && (
                <div className="mt-3 flex flex-wrap gap-2">
                  {skills.map((s) => (
                    <span key={s} className="chip bg-brand-100 text-brand-900">
                      {s}
                      <button
                        type="button"
                        onClick={() => setSkills((prev) => prev.filter((x) => x !== s))}
                        aria-label={`Remove ${s}`}
                        className="ml-0.5 text-brand-700 hover:text-red-600"
                      >
                        ✕
                      </button>
                    </span>
                  ))}
                </div>
              )}

              <div className="mt-3 flex flex-wrap gap-2">
                {SUGGESTED.filter((s) => !skills.includes(s)).map((s) => (
                  <button
                    key={s}
                    type="button"
                    onClick={() => addSkill(s)}
                    className="chip border border-dashed border-soil-200 text-soil-400 hover:border-brand-600 hover:text-brand-700"
                  >
                    + {s}
                  </button>
                ))}
              </div>
            </div>

            <div>
              <label className="label" htmlFor="exp">
                Years of experience
              </label>
              <input
                id="exp"
                type="number"
                step="1"
                min="0"
                inputMode="numeric"
                className={`field num ${errors.experience_years ? 'field-error' : ''}`}
                value={form.experience_years ?? ''}
                onKeyDown={(e) => ['.', ',', 'e', 'E', '+', '-'].includes(e.key) && e.preventDefault()}
                onChange={(e) => set('experience_years', e.target.value)}
              />
              {errors.experience_years && <p className="err">{errors.experience_years}</p>}
            </div>

            <TextArea
              label="About you"
              max={200}
              placeholder="A sentence or two about the work you do best."
              value={form.bio ?? ''}
              onChange={(e) => set('bio', e.target.value)}
            />
          </div>
        </section>

        <button className="btn-primary w-full sm:w-auto" disabled={busy}>
          {busy ? 'Saving…' : 'Save changes'}
        </button>
      </form>
    </div>
  )
}
