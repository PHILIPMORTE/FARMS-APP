import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Badge, DataTable, Dialog, Empty, SectionHeading, Spinner, Stat, TextArea } from '@/components/ui'
import { TopFarms } from '@/components/TopFarms'
import { pesoShort, relativeDate, shortDate } from '@/lib/format'
import { displayPhone, friendlyError } from '@/lib/validation'
import type { OwnerVerification } from '@/lib/types'

interface Stats {
  owners: number
  farmers: number
  buyers: number
  pending_reviews: number
  products: number
  out_of_stock: number
  orders: number
  open_orders: number
  revenue: number
}

export function AdminDashboard() {
  const [stats, setStats] = useState<Stats | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    ;(async () => {
      const { data, error: rpcError } = await supabase.rpc('admin_stats')
      if (rpcError) {
        setError(rpcError.message)
        return
      }
      setStats(data as Stats)
    })()
  }, [])

  if (error) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700">
        {error}
      </div>
    )
  }
  if (!stats) return <Spinner label="Loading system overview" />

  return (
    <div className="animate-fade-up space-y-6">
      <div>
        <h1 className="text-[22px] font-bold">System overview</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Everything across FARMS at a glance.
        </p>
      </div>

      {stats.pending_reviews > 0 && (
        <Link
          to="/admin/verifications"
          className="block rounded-xl border border-amber-300 bg-amber-50 px-4 py-3.5 transition hover:shadow-sm"
        >
          <p className="text-[14px] font-bold text-amber-900">
            {stats.pending_reviews} Farm Owner{stats.pending_reviews === 1 ? '' : 's'} waiting for
            verification
          </p>
          <p className="mt-0.5 text-[13px] text-amber-800">
            They cannot use their account until you review them. Tap to open.
          </p>
        </Link>
      )}

      <section>
        <SectionHeading>People</SectionHeading>
        <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="Farm owners" value={String(stats.owners)} />
          <Stat label="Farmers" value={String(stats.farmers)} />
          <Stat label="Buyers" value={String(stats.buyers)} />
          <Stat
            label="Awaiting review"
            value={String(stats.pending_reviews)}
            accent={stats.pending_reviews ? 'red' : undefined}
          />
        </div>
      </section>

      <section>
        <SectionHeading>Top selling farms</SectionHeading>
        <TopFarms limit={10} />
      </section>

      <section>
        <SectionHeading>Marketplace</SectionHeading>
        <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Stat label="Products listed" value={String(stats.products)} />
          <Stat
            label="Out of stock"
            value={String(stats.out_of_stock)}
            accent={stats.out_of_stock ? 'red' : undefined}
          />
          <Stat label="Orders placed" value={String(stats.orders)} sub={`${stats.open_orders} in progress`} />
          <Stat label="Total sales" value={pesoShort(stats.revenue)} accent="green" />
        </div>
      </section>
    </div>
  )
}

export function AdminVerifications() {
  const [rows, setRows] = useState<OwnerVerification[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [tab, setTab] = useState<'pending' | 'approved' | 'rejected'>('pending')
  const [acting, setActing] = useState<{ row: OwnerVerification; approve: boolean } | null>(null)
  const [viewing, setViewing] = useState<OwnerVerification | null>(null)

  const load = useCallback(async () => {
    const { data, error: qError } = await supabase
      .from('owner_verifications')
      .select('*, profiles!owner_verifications_profile_id_fkey(*)')
      .order('submitted_at', { ascending: false })

    if (qError) {
      setError(qError.message)
      setRows([])
      return
    }
    setError(null)
    setRows(
      ((data as any[]) ?? []).map((r) => ({
        ...r,
        profiles: r['profiles'] ?? null,
      })) as OwnerVerification[],
    )
  }, [])

  useEffect(() => {
    load()
    const channel = supabase
      .channel('admin-verifications')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'owner_verifications' }, () =>
        load(),
      )
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  if (!rows) return <Spinner label="Loading verification requests" />

  const shown = rows.filter((r) => r.status === tab)
  const pending = rows.filter((r) => r.status === 'pending').length

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Farm Owner verification</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Check each applicant's identity and farm details before approving.
        </p>
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700"
        >
          <p className="font-semibold">Verification requests could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
          <button onClick={load} className="mt-2 font-semibold underline">
            Try again
          </button>
        </div>
      )}

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="Pending" value={String(pending)} accent={pending ? 'red' : undefined} />
        <Stat label="Approved" value={String(rows.filter((r) => r.status === 'approved').length)} />
        <Stat label="Rejected" value={String(rows.filter((r) => r.status === 'rejected').length)} />
      </div>

      <div role="tablist" className="grid grid-cols-3 gap-1 rounded-lg bg-soil-100 p-1">
        {(['pending', 'approved', 'rejected'] as const).map((t) => (
          <button
            key={t}
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            className={`rounded-md px-3 py-2 text-[13px] font-semibold capitalize transition ${
              tab === t ? 'bg-white shadow-sm' : 'text-soil-600'
            }`}
          >
            {t}
            {t === 'pending' && pending > 0 && (
              <span className="num ml-1.5 rounded-full bg-red-600 px-1.5 py-0.5 text-[10px] text-white">
                {pending}
              </span>
            )}
          </button>
        ))}
      </div>

      {shown.length === 0 ? (
        <Empty
          title={`Nothing ${tab}`}
          body={
            tab === 'pending'
              ? 'New Farm Owner applications appear here for review.'
              : `No ${tab} applications yet.`
          }
        />
      ) : (
        <DataTable
          minWidth="56rem"
          headers={[
            { label: 'Applicant' },
            { label: 'ID' },
            { label: 'Farm' },
            { label: 'Location' },
            { label: 'Submitted' },
            { label: 'Status' },
            { label: '', align: 'right' },
          ]}
        >
          {shown.map((r) => (
            <tr key={r.id} className="align-top">
              <td className="px-4 py-3">
                <span className="block font-semibold">{r.full_name || r.profiles?.name}</span>
                <span className="num block text-[12px] text-soil-400">
                  {displayPhone(r.profiles?.phone)}
                </span>
              </td>
              <td className="px-4 py-3">
                <span className="block text-[12px] text-soil-600">{r.id_type}</span>
                {r.id_photo_path ? (
                  <button
                    onClick={() => setViewing(r)}
                    className="mt-0.5 text-[12px] font-semibold text-brand-700 underline"
                  >
                    View photo
                  </button>
                ) : (
                  <span className="text-[12px] text-soil-400">No photo</span>
                )}
              </td>
              <td className="px-4 py-3">
                <span className="block font-semibold">{r.farm_name || '—'}</span>
                {r.farm_size_ha != null && (
                  <span className="num block text-[12px] text-soil-400">{r.farm_size_ha} ha</span>
                )}
              </td>
              <td className="px-4 py-3 text-soil-600">
                <span className="block">{r.barangay || '—'}</span>
                <span className="block text-[12px] text-soil-400">{r.farm_address || ''}</span>
              </td>
              <td className="num px-4 py-3 text-soil-600">{shortDate(r.submitted_at)}</td>
              <td className="px-4 py-3">
                <Badge
                  tone={r.status === 'approved' ? 'green' : r.status === 'rejected' ? 'red' : 'amber'}
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
                      onClick={() => setActing({ row: r, approve: true })}
                    >
                      Approve
                    </button>
                    <button
                      className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                      onClick={() => setActing({ row: r, approve: false })}
                    >
                      Reject
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

      <IdPhotoDialog record={viewing} onClose={() => setViewing(null)} />

      <ReviewDialog
        acting={acting}
        onClose={() => setActing(null)}
        onDone={() => {
          setActing(null)
          load()
        }}
      />
    </div>
  )
}

function IdPhotoDialog({
  record,
  onClose,
}: {
  record: OwnerVerification | null
  onClose(): void
}) {
  const [url, setUrl] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    setUrl(null)
    setFailed(false)
    if (!record?.id_photo_path) return
    supabase.storage
      .from('verification-ids')
      .createSignedUrl(record.id_photo_path, 600)
      .then(({ data, error }) => {
        if (error || !data?.signedUrl) setFailed(true)
        else setUrl(data.signedUrl)
      })
  }, [record?.id])

  if (!record) return null

  return (
    <Dialog
      open
      onClose={onClose}
      title="Identity document"
      description={`${record.full_name || record.profiles?.name} · ${record.id_type}`}
      footer={
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      }
    >
      {failed ? (
        <p className="rounded-lg bg-red-50 px-4 py-3 text-[13px] text-red-700">
          The photo could not be loaded. It may have been removed.
        </p>
      ) : url ? (
        <img
          src={url}
          alt={`ID document for ${record.full_name}`}
          className="w-full rounded-lg border border-soil-200 bg-soil-50 object-contain"
        />
      ) : (
        <Spinner label="Loading the photo" />
      )}
    </Dialog>
  )
}

function ReviewDialog({
  acting,
  onClose,
  onDone,
}: {
  acting: { row: OwnerVerification; approve: boolean } | null
  onClose(): void
  onDone(): void
}) {
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (acting) setNotes('')
  }, [acting?.row.id])

  if (!acting) return null
  const { row, approve } = acting

  async function confirm() {
    if (!approve && !notes.trim()) {
      toast.error('Give a reason so the applicant can correct it.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('review_owner_verification', {
      p_verification_id: row.id,
      p_decision: approve ? 'approved' : 'rejected',
      p_notes: notes.trim(),
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(approve ? 'Farm Owner approved' : 'Application rejected')
    onDone()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={approve ? 'Approve this Farm Owner?' : 'Reject this application?'}
      description={row.full_name || row.profiles?.name}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Go back
          </button>
          <button
            className={approve ? 'btn-primary' : 'btn-danger'}
            onClick={confirm}
            disabled={busy}
          >
            {busy ? 'Saving…' : approve ? 'Approve' : 'Reject'}
          </button>
        </>
      }
    >
      <div className="space-y-3">
        <p className="text-[14px] leading-relaxed text-soil-800">
          {approve
            ? 'They gain full access to Farm Owner functions, and their farm record is created automatically.'
            : 'They keep their account but stay locked out of Farm Owner functions. They can correct their details and apply again.'}
        </p>
        <TextArea
          label={approve ? 'Note (optional)' : 'Reason for rejection'}
          max={200}
          placeholder={approve ? 'Optional' : 'e.g. ID number does not match the name given'}
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
        />
      </div>
    </Dialog>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="shrink-0 text-soil-600">{label}</dt>
      <dd className="truncate text-right font-semibold">{value}</dd>
    </div>
  )
}
