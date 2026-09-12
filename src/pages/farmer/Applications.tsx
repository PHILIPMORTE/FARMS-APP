import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/validation'
import { useAuth } from '@/context/AuthContext'
import { Badge, Empty, Spinner } from '@/components/ui'
import { CROP_EMOJI, peso, shortDate, titleCase } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { JobApplication } from '@/lib/types'

interface Row extends JobApplication {
  farm?: { name: string; owner_phone: string | null } | null
}

export default function FarmerApplications() {
  const { profile } = useAuth()
  const [rows, setRows] = useState<Row[] | null>(null)
  const [cancelling, setCancelling] = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    if (!profile) return
    let alive = true

    ;(async () => {
      const { data } = await supabase
        .from('job_applications')
        .select('*, job_posts(*, farms(name, city, province, owner_id))')
        .eq('farmer_id', profile.id)
        .order('applied_at', { ascending: false })

      const list = (data as unknown as Row[]) ?? []

      const ownerIds = [
        ...new Set(
          list
            .filter((r) => r.status === 'accepted')
            .map((r) => (r.job_posts?.farms as any)?.owner_id)
            .filter(Boolean),
        ),
      ]
      let contacts = new Map<string, string>()
      if (ownerIds.length) {
        const { data: owners } = await supabase
          .from('profiles')
          .select('id, phone')
          .in('id', ownerIds)
        contacts = new Map((owners ?? []).map((o: any) => [o.id, o.phone]))
      }

      list.forEach((r) => {
        const farms = r.job_posts?.farms as any
        r.farm = farms
          ? { name: farms.name, owner_phone: contacts.get(farms.owner_id) ?? null }
          : null
      })

      if (alive) setRows(list)
    })()

    return () => {
      alive = false
    }
  }, [profile?.id, reloadKey])

  async function cancel(id: string) {
    setCancelling(id)
    const { error } = await supabase.rpc('cancel_application', { p_application_id: id })
    setCancelling(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Application withdrawn')
    setReloadKey((k) => k + 1)
  }

  if (!rows) return <Spinner label="Loading your applications" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">My applications</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every job you have applied for, and where each one stands.
        </p>
      </div>

      {rows.length === 0 ? (
        <Empty
          title="You have not applied anywhere yet"
          body="Browse the job board and send your first application — a short message about your experience goes a long way."
        />
      ) : (
        <div className="grid gap-3 lg:grid-cols-2">
          {rows.map((a) => {
            const job = a.job_posts
            return (
              <article key={a.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h2 className="text-base font-bold leading-snug">
                      {job?.crop ? `${CROP_EMOJI[job.crop]} ` : ''}
                      {job?.title ?? 'Job'}
                    </h2>
                    <p className="text-[13px] text-soil-600">{a.farm?.name ?? 'Farm'}</p>
                  </div>
                  <Badge
                    tone={
                      a.status === 'accepted' ? 'green' : a.status === 'rejected' ? 'red' : 'amber'
                    }
                  >
                    {titleCase(a.status)}
                  </Badge>
                </div>

                <p className="text-[12px] text-soil-400">Applied {shortDate(a.applied_at)}</p>

                {a.message && (
                  <p className="rounded-xl bg-soil-50 px-3.5 py-3 text-[14px] leading-relaxed text-soil-800">
                    {a.message}
                  </p>
                )}

                {job && (
                  <div className="flex flex-wrap gap-2">
                    <Badge tone="brand">{job.type}</Badge>
                    <Badge>
                      <span className="num">{peso(job.wage)}</span>&nbsp;a day
                    </Badge>
                    <Badge>Starts {shortDate(job.start_date)}</Badge>
                  </div>
                )}

                {a.status === 'accepted' && (
                  <div className="rounded-xl border border-green-200 bg-green-50 px-4 py-3">
                    <p className="text-sm font-bold text-green-900">
                      🎉 You got the job — congratulations!
                    </p>
                    <p className="mt-1 text-[13px] leading-relaxed text-green-800">
                      Contact {a.farm?.name ?? 'the farm'} to agree your start time.
                    </p>
                    {a.farm?.owner_phone && (
                      <a
                        href={`tel:${a.farm.owner_phone}`}
                        className="num mt-1.5 inline-block text-sm font-bold text-green-900 underline"
                      >
                        {displayPhone(a.farm.owner_phone)}
                      </a>
                    )}
                  </div>
                )}

                {a.status === 'pending' && (
                  <button
                    className="btn-ghost w-full py-2 text-[13px] text-red-600 hover:bg-red-50"
                    disabled={cancelling === a.id}
                    onClick={() => cancel(a.id)}
                  >
                    {cancelling === a.id ? 'Withdrawing…' : 'Cancel application'}
                  </button>
                )}

                {a.status === 'rejected' && (
                  <div className="rounded-xl border border-soil-200 bg-soil-50 px-4 py-3">
                    {a.message && a.message.includes('Reason:') && (
                      <p className="mb-2 text-[13px] font-semibold text-soil-800">
                        {a.message.slice(a.message.lastIndexOf('Reason:'))}
                      </p>
                    )}
                    <p className="text-[13px] leading-relaxed text-soil-600">
                      Plenty of farms are hiring — keep applying, and add your skills to your
                      account so they know what you can do.
                    </p>
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
