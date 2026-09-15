import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { AccountHeader } from '@/components/AccountHeader'
import { Badge, DataTable, Empty, Field, SectionHeading, Spinner, Stat } from '@/components/ui'
import { relativeDate, shortDate } from '@/lib/format'
import { displayPhone, friendlyError, validateName } from '@/lib/validation'

interface OutboxRow {
  id: string
  recipient: string
  subject: string | null
  status: string
  error: string | null
  created_at: string
  sent_at: string | null
}

export default function AdminAccount() {
  const { profile, refresh } = useAuth()
  const [name, setName] = useState(profile?.name ?? '')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [mail, setMail] = useState<OutboxRow[] | null>(null)
  const [counts, setCounts] = useState({ admins: 0, users: 0 })

  const load = useCallback(async () => {
    const [{ data: out }, { data: profiles }] = await Promise.all([
      supabase
        .from('message_outbox')
        .select('id, recipient, subject, status, error, created_at, sent_at')
        .order('created_at', { ascending: false })
        .limit(15),
      supabase.from('profiles').select('role'),
    ])

    setMail((out as OutboxRow[]) ?? [])

    const all = (profiles as { role: string }[]) ?? []
    setCounts({
      admins: all.filter((p) => p.role === 'admin').length,
      users: all.filter((p) => p.role !== 'admin').length,
    })
  }, [])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    setName(profile?.name ?? '')
  }, [profile?.name])

  async function save() {
    const err = validateName(name)
    setError(err)
    if (err || !profile) return

    setSaving(true)
    const { error: upError } = await supabase
      .from('profiles')
      .update({ name: name.trim() })
      .eq('id', profile.id)
    setSaving(false)

    if (upError) {
      toast.error(friendlyError(upError))
      return
    }
    toast.success('Saved')
    await refresh()
  }

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Account</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Your administrator details, and what the system has been sending out.
        </p>
      </div>

      <AccountHeader subtitle="System Administrator" />

      <div className="stagger grid grid-cols-2 gap-3">
        <Stat label="Administrators" value={String(counts.admins)} />
        <Stat label="Other accounts" value={String(counts.users)} />
      </div>

      <section>
        <SectionHeading>Your details</SectionHeading>
        <div className="card space-y-4 p-5">
          <Field
            label="Display name"
            value={name}
            error={error}
            onChange={(e) => {
              setName(e.target.value)
              setError(null)
            }}
          />

          <div>
            <p className="label">Mobile number</p>
            <p className="num text-[15px] font-semibold text-soil-800">
              {displayPhone(profile?.phone)}
            </p>
            <p className="mt-1 text-[12px] text-soil-400">
              Your number is how you sign in, so it cannot be changed here.
            </p>
          </div>

          <button className="btn-primary w-full" onClick={save} disabled={saving}>
            {saving ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </section>

      <section>
        <SectionHeading>Recent emails sent by the system</SectionHeading>

        {mail === null ? (
          <Spinner label="Loading the outbox" />
        ) : mail.length === 0 ? (
          <Empty
            title="Nothing sent yet"
            body="Verification results and harvest alerts appear here once they go out."
          />
        ) : (
          <DataTable
            minWidth="44rem"
            headers={[
              { label: 'When' },
              { label: 'To' },
              { label: 'Subject' },
              { label: 'Status' },
            ]}
          >
            {mail.map((m) => (
              <tr key={m.id}>
                <td className="num px-4 py-3 text-soil-600">{relativeDate(m.created_at)}</td>
                <td className="px-4 py-3 text-soil-700">{m.recipient}</td>
                <td className="px-4 py-3">
                  <span className="block font-semibold">{m.subject ?? '—'}</span>
                  {m.error && (
                    <span className="block max-w-[18rem] text-[11px] leading-snug text-red-600">
                      {m.error}
                    </span>
                  )}
                </td>
                <td className="px-4 py-3">
                  <Badge
                    tone={
                      m.status === 'sent' ? 'green' : m.status === 'failed' ? 'red' : 'amber'
                    }
                  >
                    {m.status}
                  </Badge>
                  {m.sent_at && (
                    <span className="num mt-0.5 block text-[11px] text-soil-400">
                      {shortDate(m.sent_at)}
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </DataTable>
        )}

        <p className="mt-2 text-[12px] leading-relaxed text-soil-400">
          Sent means the message was handed to the mail provider. Delivery to the inbox is then up
          to the provider and the recipient's mail server.
        </p>
      </section>
    </div>
  )
}
