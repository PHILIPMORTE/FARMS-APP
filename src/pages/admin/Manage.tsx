import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/validation'
import {
  Badge,
  Dialog,
  Empty,
  Search,
  Select,
  Spinner,
  Stat,
  TextArea,
} from '@/components/ui'
import { StageBadge } from '@/components/OrderTimeline'
import {
  CROP_EMOJI,
  ORDER_STAGES,
  ROLE_LABEL,
  effectiveStage,
  isFinishedOrder,
  STAGE_LABEL,
  peso,
  pesoShort,
  sacks,
  shortDate,
  titleCase,
} from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { Order, Product, Profile, Role } from '@/lib/types'

export function AdminUsers() {
  const [rows, setRows] = useState<Profile[] | null>(null)
  const [query, setQuery] = useState('')
  const [role, setRole] = useState<'all' | Role>('all')
  const [removing, setRemoving] = useState<Profile | null>(null)
  const [impact, setImpact] = useState<Record<string, any> | null>(null)
  const [reason, setReason] = useState('')
  const [force, setForce] = useState(false)
  const [busy, setBusy] = useState(false)

  async function openRemove(p: Profile) {
    setRemoving(p)
    setImpact(null)
    setReason('')
    setForce(false)
    const { data } = await supabase.rpc('admin_user_impact', { p_profile_id: p.id })
    setImpact((data as Record<string, any>) ?? null)
  }

  async function confirmRemove() {
    if (!removing) return
    if (!reason.trim()) {
      toast.error('Give a reason so there is a record of why.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('admin_delete_profile', {
      p_profile_id: removing.id,
      p_reason: reason.trim(),
      p_force: force,
    })
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Account removed')
    setRows((prev) => (prev ?? []).filter((r) => r.id !== removing.id))
    setRemoving(null)
  }

  useEffect(() => {
    ;(async () => {
      const { data } = await supabase
        .from('profiles')
        .select('*')
        .order('created_at', { ascending: false })
      setRows((data as Profile[]) ?? [])
    })()
  }, [])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return (rows ?? []).filter((p) => {
      if (role !== 'all' && p.role !== role) return false
      if (!q) return true
      return (
        p.name.toLowerCase().includes(q) ||
        p.phone.includes(q) ||
        (p.company ?? '').toLowerCase().includes(q)
      )
    })
  }, [rows, query, role])

  if (!rows) return <Spinner label="Loading users" />

  const blocking =
    impact && !force && (Number(impact.open_orders) > 0 || Number(impact.unpaid_wages) > 0)

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Users</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every account on the system. One phone number can hold one account per role.
        </p>
      </div>

      <div className="stagger grid grid-cols-2 gap-3 lg:grid-cols-4">
        {(['owner', 'farmer', 'buyer', 'admin'] as Role[]).map((r) => (
          <Stat
            key={r}
            label={ROLE_LABEL[r]}
            value={String(rows.filter((p) => p.role === r).length)}
          />
        ))}
      </div>

      <div className="grid gap-3 sm:grid-cols-[1fr_12rem]">
        <Search value={query} onChange={setQuery} placeholder="Search name, phone or company" />
        <Select
          label=""
          value={role}
          onChange={(e) => setRole(e.target.value as typeof role)}
          options={[
            { value: 'all', label: 'All roles' },
            ...(['owner', 'farmer', 'buyer', 'admin'] as Role[]).map((r) => ({
              value: r,
              label: ROLE_LABEL[r],
            })),
          ]}
        />
      </div>

      <Dialog
        open={removing !== null}
        onClose={() => setRemoving(null)}
        title={`Remove ${removing?.name ?? 'this account'}?`}
        description={removing ? `${ROLE_LABEL[removing.role]} · ${displayPhone(removing.phone)}` : undefined}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setRemoving(null)}>
              Keep account
            </button>
            <button
              className="btn-danger"
              onClick={confirmRemove}
              disabled={busy || !impact || (blocking ?? false)}
            >
              {busy ? 'Removing…' : 'Remove permanently'}
            </button>
          </>
        }
      >
        {!impact ? (
          <Spinner label="Checking what this would remove" />
        ) : (
          <div className="space-y-4">
            <div className="rounded-lg border-2 border-red-300 bg-red-50 px-4 py-3">
              <p className="text-[14px] font-bold text-red-800">This cannot be undone</p>
              <p className="mt-0.5 text-[13px] leading-relaxed text-red-700">
                Removing this account also deletes everything attached to it.
              </p>
            </div>

            <dl className="space-y-1 rounded-lg bg-soil-50 px-4 py-3 text-[13px]">
              {[
                ['Farms', impact.farms],
                ['Market listings', impact.products],
                ['Orders placed', impact.orders_placed],
                ['Orders received', impact.orders_received],
                ['Job posts', impact.job_posts],
                ['Job applications', impact.applications],
                ['Recorded work days', impact.work_days],
              ]
                .filter(([, n]) => Number(n) > 0)
                .map(([label, n]) => (
                  <div key={String(label)} className="flex justify-between gap-3">
                    <dt className="text-soil-600">{label}</dt>
                    <dd className="num font-semibold text-red-700">{String(n)}</dd>
                  </div>
                ))}

              {[
                impact.farms,
                impact.products,
                impact.orders_placed,
                impact.orders_received,
                impact.job_posts,
                impact.applications,
                impact.work_days,
              ].every((n) => Number(n) === 0) && (
                <p className="text-soil-600">
                  This account has no farms, orders or work records attached.
                </p>
              )}
            </dl>

            {(Number(impact.open_orders) > 0 || Number(impact.unpaid_wages) > 0) && (
              <div className="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3">
                <p className="text-[13px] font-bold text-amber-900">Someone is relying on this</p>
                <ul className="mt-1 list-disc space-y-0.5 pl-4 text-[13px] text-amber-800">
                  {Number(impact.open_orders) > 0 && (
                    <li>{impact.open_orders} order(s) still in progress</li>
                  )}
                  {Number(impact.unpaid_wages) > 0 && (
                    <li>{peso(impact.unpaid_wages)} in wages not yet paid</li>
                  )}
                </ul>
                <label className="mt-2 flex cursor-pointer items-start gap-2">
                  <input
                    type="checkbox"
                    checked={force}
                    onChange={(e) => setForce(e.target.checked)}
                    className="mt-0.5 h-4 w-4 rounded border-soil-300 text-red-600"
                  />
                  <span className="text-[13px] font-medium text-amber-900">
                    Remove anyway. I understand this leaves the other party without a record.
                  </span>
                </label>
              </div>
            )}

            <TextArea
              label="Reason for removing"
              max={200}
              placeholder="e.g. duplicate account, fake ID, requested by the user"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
            />
          </div>
        )}
      </Dialog>

      {filtered.length === 0 ? (
        <Empty title="No users match" body="Try a different search or role." />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[36rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Name</th>
                <th className="px-4 py-2.5 font-semibold">Role</th>
                <th className="px-4 py-2.5 font-semibold">Phone</th>
                <th className="px-4 py-2.5 font-semibold">Joined</th>
                <th className="px-4 py-2.5 text-right font-semibold">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {filtered.map((p) => (
                <tr key={p.id}>
                  <td className="px-4 py-2.5 font-semibold">
                    {p.name || '—'}
                    {p.company && (
                      <span className="block text-[12px] font-normal text-soil-400">
                        {p.company}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2.5">
                    <Badge tone={p.role === 'admin' ? 'red' : 'brand'}>{ROLE_LABEL[p.role]}</Badge>
                  </td>
                  <td className="num px-4 py-2.5">{displayPhone(p.phone)}</td>
                  <td className="num px-4 py-2.5 text-soil-600">{shortDate(p.created_at)}</td>
                  <td className="px-4 py-2.5 text-right">
                    <button
                      className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                      onClick={() => openRemove(p)}
                    >
                      Remove
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

export function AdminCatalog() {
  const [rows, setRows] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('*, farms(name, city, province)')
      .order('created_at', { ascending: false })
    setRows((data as unknown as Product[]) ?? [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return rows ?? []
    return (rows ?? []).filter(
      (p) =>
        p.variety.toLowerCase().includes(q) ||
        p.crop.toLowerCase().includes(q) ||
        (p.farms?.name ?? '').toLowerCase().includes(q),
    )
  }, [rows, query])

  if (!rows) return <Spinner label="Loading products" />

  const out = rows.filter((p) => p.quantity === 0).length

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Products &amp; stock</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Every listing across all farms. Stock is managed by each farm owner.
        </p>
      </div>

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="Listings" value={String(rows.length)} />
        <Stat label="Out of stock" value={String(out)} accent={out ? 'red' : undefined} />
        <Stat
          label="Stock value"
          value={pesoShort(rows.reduce((s, p) => s + p.quantity * Number(p.price), 0))}
          accent="green"
        />
      </div>

      <Search value={query} onChange={setQuery} placeholder="Search variety, crop or farm" />

      {filtered.length === 0 ? (
        <Empty title="No products match" body="Try a different search." />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[42rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Product</th>
                <th className="px-4 py-2.5 font-semibold">Farm</th>
                <th className="px-4 py-2.5 text-right font-semibold">Stock</th>
                <th className="px-4 py-2.5 text-right font-semibold">Price</th>
                <th className="px-4 py-2.5 font-semibold">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {filtered.map((p) => (
                <tr key={p.id} className={p.quantity === 0 ? 'bg-red-50/50' : ''}>
                  <td className="px-4 py-2.5 font-semibold">
                    {CROP_EMOJI[p.crop]} {p.variety}
                  </td>
                  <td className="px-4 py-2.5 text-soil-600">{p.farms?.name ?? '—'}</td>
                  <td className="num px-4 py-2.5 text-right font-bold">{sacks(p.quantity)}</td>
                  <td className="num px-4 py-2.5 text-right">{peso(p.price)}</td>
                  <td className="px-4 py-2.5">
                    <Badge
                      tone={p.quantity === 0 ? 'red' : p.quantity <= 5 ? 'amber' : 'green'}
                    >
                      {p.quantity === 0 ? 'Out of stock' : p.quantity <= 5 ? 'Low' : 'Available'}
                    </Badge>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

    </div>
  )
}

export function AdminOrders() {
  const [rows, setRows] = useState<Order[] | null>(null)
  const [stage, setStage] = useState('all')

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, products(*, farms(name)), profiles!orders_buyer_id_fkey(*)')
      .order('created_at', { ascending: false })
    setRows((data as unknown as Order[]) ?? [])
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const filtered = useMemo(
    () => (stage === 'all' ? (rows ?? []) : (rows ?? []).filter((o) => effectiveStage(o) === stage)),
    [rows, stage],
  )

  if (!rows) return <Spinner label="Loading orders" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Orders</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">Every order placed across all farms.</p>
      </div>

      <div className="stagger grid grid-cols-3 gap-3">
        <Stat label="All orders" value={String(rows.length)} />
        <Stat
          label="In progress"
          value={String(rows.filter((o) => !isFinishedOrder(o)).length)}
        />
        <Stat
          label="Sales value"
          value={pesoShort(
            rows.filter((o) => effectiveStage(o) !== 'cancelled').reduce((s, o) => s + Number(o.total_price), 0),
          )}
          accent="green"
        />
      </div>

      <div className="max-w-xs">
        <Select
          label="Stage"
          value={stage}
          onChange={(e) => setStage(e.target.value)}
          options={[
            { value: 'all', label: 'All stages' },
            ...ORDER_STAGES.map((s) => ({ value: s.stage, label: s.label })),
            { value: 'cancelled', label: 'Cancelled' },
          ]}
        />
      </div>

      {filtered.length === 0 ? (
        <Empty title="No orders here" body="Nothing matches this filter." />
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[46rem] text-left text-[13px]">
            <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
              <tr>
                <th className="px-4 py-2.5 font-semibold">Date</th>
                <th className="px-4 py-2.5 font-semibold">Product</th>
                <th className="px-4 py-2.5 font-semibold">Farm</th>
                <th className="px-4 py-2.5 font-semibold">Buyer</th>
                <th className="px-4 py-2.5 text-right font-semibold">Sacks</th>
                <th className="px-4 py-2.5 text-right font-semibold">Total</th>
                <th className="px-4 py-2.5 font-semibold">Stage</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-soil-200">
              {filtered.map((o) => (
                <tr key={o.id}>
                  <td className="num px-4 py-2.5 text-soil-600">{shortDate(o.created_at)}</td>
                  <td className="px-4 py-2.5 font-semibold">{o.products?.variety ?? '—'}</td>
                  <td className="px-4 py-2.5 text-soil-600">
                    {(o.products as any)?.farms?.name ?? '—'}
                  </td>
                  <td className="px-4 py-2.5 text-soil-600">{o.profiles?.name ?? '—'}</td>
                  <td className="num px-4 py-2.5 text-right font-bold">{sacks(o.quantity)}</td>
                  <td className="num px-4 py-2.5 text-right">{peso(o.total_price)}</td>
                  <td className="px-4 py-2.5">
                    <StageBadge stage={effectiveStage(o)} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
