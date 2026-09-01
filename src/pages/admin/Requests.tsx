import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Badge, DataTable, Dialog, Empty, Spinner, Stat, TextArea } from '@/components/ui'
import { ROLE_LABEL, relativeDate, shortDate } from '@/lib/format'
import { displayPhone, friendlyError } from '@/lib/validation'
import type { Profile, VerificationStatus } from '@/lib/types'

interface AdminRequest {
  id: string
  user_id: string
  requester_id: string
  full_name: string
  phone: string
  reason: string
  status: VerificationStatus
  review_notes: string | null
  reviewed_at: string | null
  created_at: string
}

export function AdminRequests() {
  const { profile } = useAuth()
  const [rows, setRows] = useState<AdminRequest[] | null>(null)
  const [admins, setAdmins] = useState<Profile[]>([])
  const [error, setError] = useState<string | null>(null)
  const [acting, setActing] = useState<{ row: AdminRequest; approve: boolean } | null>(null)
  const [revoking, setRevoking] = useState<Profile | null>(null)
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const [{ data, error: qError }, { data: ad }] = await Promise.all([
      supabase.from('admin_requests').select('*').order('created_at', { ascending: false }),
      supabase.from('profiles').select('*').eq('role', 'admin').order('created_at'),
    ])

    if (qError) {
      setError(qError.message)
      setRows([])
    } else {
      setError(null)
      setRows((data as AdminRequest[]) ?? [])
    }
    setAdmins((ad as Profile[]) ?? [])
  }, [])

  useEffect(() => {
    load()
    const channel = supabase
      .channel('admin-requests')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'admin_requests' }, () =>
        load(),
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  async function decide() {
    if (!acting) return
    if (!acting.approve && !notes.trim()) {
      toast.error('Give a reason so they know why.')
      return
    }
    setBusy(true)
    const { error: rpcError } = await supabase.rpc('review_admin_request', {
      p_request_id: acting.row.id,
      p_decision: acting.approve ? 'approved' : 'rejected',
      p_notes: notes.trim(),
    })
    setBusy(false)
    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success(acting.approve ? 'Administrator access granted' : 'Request declined')
    setActing(null)
    setNotes('')
    load()
  }

  async function revoke() {
    if (!revoking) return
    setBusy(true)
    const { error: rpcError } = await supabase.rpc('revoke_admin', { p_profile_id: revoking.id })
    setBusy(false)
    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success('Administrator access removed')
    setRevoking(null)
    load()
  }

  if (!rows) return <Spinner label="Loading requests" />

  const pending = rows.filter((r) => r.status === 'pending')

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">Administrators</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Anyone asking for administrator access appears here. Only an existing administrator can
          approve them.
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
          <p className="font-semibold">Requests could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
        </div>
      )}

      <div className="stagger grid grid-cols-2 gap-3">
        <Stat label="Administrators" value={String(admins.length)} />
        <Stat
          label="Pending requests"
          value={String(pending.length)}
          accent={pending.length ? 'red' : undefined}
        />
      </div>

      <section>
        <h2 className="mb-3 text-[15px] font-bold">Current administrators</h2>
        <DataTable
          minWidth="34rem"
          headers={[
            { label: 'Name' },
            { label: 'Phone' },
            { label: 'Since' },
            { label: '', align: 'right' },
          ]}
        >
          {admins.map((a) => (
            <tr key={a.id}>
              <td className="px-4 py-3 font-semibold">
                {a.name}
                {a.id === profile?.id && (
                  <span className="ml-1.5 text-[11px] font-bold uppercase text-brand-700">You</span>
                )}
              </td>
              <td className="num px-4 py-3 text-soil-600">{displayPhone(a.phone)}</td>
              <td className="num px-4 py-3 text-soil-600">{shortDate(a.created_at)}</td>
              <td className="px-4 py-3 text-right">
                {a.id === profile?.id || admins.length <= 1 ? (
                  <span className="text-[12px] text-soil-400">—</span>
                ) : (
                  <button
                    className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                    onClick={() => setRevoking(a)}
                  >
                    Remove
                  </button>
                )}
              </td>
            </tr>
          ))}
        </DataTable>
      </section>

      <section>
        <h2 className="mb-3 text-[15px] font-bold">Access requests</h2>
        {rows.length === 0 ? (
          <Empty
            title="No requests"
            body="When someone asks for administrator access, their request appears here for review."
          />
        ) : (
          <DataTable
            minWidth="46rem"
            headers={[
              { label: 'Person' },
              { label: 'Reason' },
              { label: 'Requested' },
              { label: 'Status' },
              { label: '', align: 'right' },
            ]}
          >
            {rows.map((r) => (
              <tr key={r.id} className="align-top">
                <td className="px-4 py-3">
                  <span className="block font-semibold">{r.full_name || 'Unnamed'}</span>
                  <span className="num block text-[12px] text-soil-400">
                    {displayPhone(r.phone)}
                  </span>
                </td>
                <td className="max-w-[20rem] px-4 py-3 text-soil-600">{r.reason || '—'}</td>
                <td className="num px-4 py-3 text-soil-600">{relativeDate(r.created_at)}</td>
                <td className="px-4 py-3">
                  <Badge
                    tone={
                      r.status === 'approved' ? 'green' : r.status === 'rejected' ? 'red' : 'amber'
                    }
                  >
                    {r.status}
                  </Badge>
                  {r.review_notes && (
                    <span className="mt-1 block max-w-[12rem] text-[11px] leading-snug text-soil-400">
                      {r.review_notes}
                    </span>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  {r.status === 'pending' ? (
                    <span className="inline-flex gap-1.5">
                      <button
                        className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                        onClick={() => {
                          setActing({ row: r, approve: true })
                          setNotes('')
                        }}
                      >
                        Approve
                      </button>
                      <button
                        className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                        onClick={() => {
                          setActing({ row: r, approve: false })
                          setNotes('')
                        }}
                      >
                        Decline
                      </button>
                    </span>
                  ) : (
                    <span className="text-[12px] text-soil-400">
                      {r.reviewed_at ? relativeDate(r.reviewed_at) : '—'}
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </DataTable>
        )}
      </section>

      <Dialog
        open={acting !== null}
        onClose={() => setActing(null)}
        title={acting?.approve ? 'Grant administrator access?' : 'Decline this request?'}
        description={acting?.row.full_name}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setActing(null)}>
              Go back
            </button>
            <button
              className={acting?.approve ? 'btn-primary' : 'btn-danger'}
              onClick={decide}
              disabled={busy}
            >
              {busy ? 'Saving…' : acting?.approve ? 'Grant access' : 'Decline'}
            </button>
          </>
        }
      >
        <div className="space-y-3">
          <p className="text-[14px] leading-relaxed text-soil-800">
            {acting?.approve
              ? 'They will be able to verify accounts, view every user, product and order, and approve future administrators. Only grant this to someone who needs it.'
              : 'They keep their existing account and can ask again later.'}
          </p>
          <TextArea
            label={acting?.approve ? 'Note (optional)' : 'Reason for declining'}
            max={200}
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
        </div>
      </Dialog>

      <Dialog
        open={revoking !== null}
        onClose={() => setRevoking(null)}
        title="Remove administrator access?"
        description={revoking?.name}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setRevoking(null)}>
              Keep access
            </button>
            <button className="btn-danger" onClick={revoke} disabled={busy}>
              {busy ? 'Removing…' : 'Remove access'}
            </button>
          </>
        }
      >
        <p className="text-[14px] leading-relaxed text-soil-800">
          They lose the admin panel immediately. Any other accounts they hold as a farm owner,
          farmer or buyer are unaffected.
        </p>
      </Dialog>
    </div>
  )
}

export function RequestAdminAccess() {
  const { profile } = useAuth()
  const [existing, setExisting] = useState<AdminRequest | null>(null)
  const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('admin_requests')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    setExisting((data as AdminRequest) ?? null)
    setLoading(false)
  }, [])

  useEffect(() => {
    load()
  }, [load])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (reason.trim().length < 10) {
      toast.error('Explain briefly why you need administrator access.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('request_admin_access', { p_reason: reason.trim() })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Request sent for review')
    setReason('')
    load()
  }

  if (loading) return <Spinner label="Checking your request" />

  return (
    <div className="mx-auto max-w-xl animate-fade-up">
      <div className="card p-6 sm:p-8">
        <h1 className="text-[20px] font-bold">Request administrator access</h1>
        <p className="mt-1.5 text-[14px] leading-relaxed text-soil-600">
          You are signed in as {ROLE_LABEL[profile?.role ?? 'buyer']}. An existing administrator
          reviews every request, so nobody can grant themselves access.
        </p>

        {existing?.status === 'pending' ? (
          <div className="mt-5 rounded-xl border border-amber-200 bg-amber-50 px-4 py-4">
            <p className="text-[14px] font-bold text-amber-900">Your request is under review</p>
            <p className="mt-1 text-[13px] leading-relaxed text-amber-800">
              Sent {relativeDate(existing.created_at)}. You will be notified once an administrator
              decides.
            </p>
          </div>
        ) : (
          <>
            {existing?.status === 'rejected' && (
              <div className="mt-5 rounded-xl border border-red-200 bg-red-50 px-4 py-3">
                <p className="text-[13px] font-semibold text-red-800">
                  Your last request was declined
                </p>
                {existing.review_notes && (
                  <p className="mt-0.5 text-[13px] text-red-700">{existing.review_notes}</p>
                )}
              </div>
            )}

            <form onSubmit={submit} className="mt-5 space-y-4">
              <TextArea
                label="Why do you need administrator access?"
                max={300}
                placeholder="e.g. I am the second barangay agriculture officer and need to verify farm owners."
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
              <button className="btn-primary w-full" disabled={busy}>
                {busy ? 'Sending…' : 'Send request'}
              </button>
            </form>
          </>
        )}

        <p className="mt-5 text-center text-[12px] text-soil-400">
          <Link to="/" className="font-semibold text-brand-700 hover:underline">
            Back to FARMS
          </Link>
        </p>
      </div>
    </div>
  )
}
