import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Dialog, Empty, SackInput, Search, Spinner } from '@/components/ui'
import { CROP_EMOJI, KG_PER_SACK, peso, sacks, titleCase, toSacks, weightNote } from '@/lib/format'
import { friendlyError, validateSacks } from '@/lib/validation'
import type { Product } from '@/lib/types'

export default function BuyerMarket() {
  const { profile } = useAuth()
  const [items, setItems] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')
  const [buying, setBuying] = useState<Product | null>(null)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('*, farms(name, city, province)')
      .eq('status', 'available')
      .gt('quantity', 0)
      .order('created_at', { ascending: false })
    setItems((data as unknown as Product[]) ?? [])
  }, [])

  useEffect(() => {
    load()

    // Live market: an owner's new listing, or another buyer's purchase,
    // updates this grid without a refresh.
    const channel = supabase
      .channel('buyer-market')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  const filtered = useMemo(() => {
    if (!items) return []
    const q = query.trim().toLowerCase()
    if (!q) return items
    return items.filter(
      (p) =>
        p.variety.toLowerCase().includes(q) ||
        p.crop.toLowerCase().includes(q) ||
        (p.farms?.name ?? '').toLowerCase().includes(q),
    )
  }, [items, query])

  if (!items) return <Spinner label="Loading the market" />

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Market</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Fresh from Philippine farms, sold by the sack. One sack is {KG_PER_SACK} kg.
        </p>
      </div>

      {/* The farm owner calls this number and delivers to this address, so a
          missing one is worth flagging before an order is placed. */}
      {profile && (!profile.address || !profile.city) && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3">
          <p className="text-[13px] font-semibold text-amber-900">
            Add your delivery address
          </p>
          <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
            Farm owners use it to find you and arrange delivery.{' '}
            <Link to="/buyer/account" className="font-semibold underline">
              Complete your account
            </Link>
          </p>
        </div>
      )}

      <Search value={query} onChange={setQuery} placeholder="Search variety, crop or farm" />

      {filtered.length === 0 ? (
        <Empty
          title={query ? 'Nothing matches that search' : 'Nothing for sale right now'}
          body={
            query
              ? 'Try a crop name like rice, corn or watermelon.'
              : 'Farms list their harvest here as it comes in. Check back shortly.'
          }
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((p) => (
            <article key={p.id} className="card flex flex-col gap-3 p-4">
              <div className="flex items-start justify-between gap-3">
                <span className="text-3xl" aria-hidden>
                  {CROP_EMOJI[p.crop]}
                </span>
                <span className="chip bg-brand-100 text-brand-900">{titleCase(p.crop)}</span>
              </div>

              <div>
                <h2 className="text-base font-bold leading-snug">{p.variety}</h2>
                <p className="text-[13px] text-soil-600">{p.farms?.name ?? 'Farm'}</p>
                {p.farms?.city && (
                  <p className="text-[13px] text-soil-400">
                    {[p.farms.city, p.farms.province].filter(Boolean).join(', ')}
                  </p>
                )}
              </div>

              <div className="mt-auto flex items-end justify-between border-t border-soil-200/70 pt-3">
                <div>
                  <p className="num text-lg font-bold">{sacks(p.quantity)}</p>
                  <p className="text-[12px] text-soil-400">{weightNote(p.quantity)}</p>
                </div>
                <div className="text-right">
                  <p className="num text-base font-bold text-brand-700">{peso(p.price)}</p>
                  <p className="text-[12px] text-soil-400">per sack</p>
                </div>
              </div>

              <button className="btn-primary w-full" onClick={() => setBuying(p)}>
                Buy now
              </button>
            </article>
          ))}
        </div>
      )}

      <BuyDialog
        product={buying}
        onClose={() => setBuying(null)}
        onBought={() => {
          setBuying(null)
          load()
        }}
      />
    </div>
  )
}

function BuyDialog({
  product,
  onClose,
  onBought,
}: {
  product: Product | null
  onClose(): void
  onBought(): void
}) {
  const [qty, setQty] = useState('1')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (product) {
      setQty('1')
      setError(null)
    }
  }, [product?.id])

  if (!product) return <Dialog open={false} onClose={onClose} title="">{null}</Dialog>

  const valid = /^\d+$/.test(qty) && toSacks(qty) >= 1 && toSacks(qty) <= product.quantity
  const total = valid ? toSacks(qty) * Number(product.price) : 0

  async function confirm() {
    const err = validateSacks(qty, { min: 1, max: product!.quantity })
    setError(err)
    if (err) return

    setBusy(true)
    // One server-side transaction: order, stock decrement, seller income,
    // and both notifications — so stock can never go negative.
    const { error: rpcError } = await supabase.rpc('purchase_product', {
      p_product_id: product!.id,
      p_quantity: parseInt(qty, 10),
    })
    setBusy(false)

    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success(`Ordered ${sacks(qty)} ${toSacks(qty) === 1 ? 'sack' : 'sacks'}`)
    onBought()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={`Buy ${product.variety}`}
      description={`${product.farms?.name ?? 'Farm'} · ${peso(product.price)} per sack`}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={confirm} disabled={busy || !valid}>
            {busy ? 'Placing order…' : 'Confirm order'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <SackInput
          label="How many sacks"
          min={1}
          max={product.quantity}
          value={qty}
          error={error}
          hint={`${sacks(product.quantity)} available · 1 sack = ${KG_PER_SACK} kg`}
          onChange={(e) => {
            setQty(e.target.value)
            setError(null)
          }}
        />

        <dl className="space-y-2 rounded-xl bg-soil-50 px-4 py-3.5 text-sm">
          <div className="flex justify-between">
            <dt className="text-soil-600">Sacks</dt>
            <dd className="num font-semibold">{valid ? sacks(qty) : '—'}</dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-soil-600">Total weight</dt>
            <dd className="num font-semibold">
              {valid ? `${(toSacks(qty) * KG_PER_SACK).toLocaleString('en-PH')} kg` : '—'}
            </dd>
          </div>
          <div className="flex justify-between border-t border-soil-200 pt-2">
            <dt className="font-bold">Total price</dt>
            <dd className="num text-base font-bold text-brand-700">{valid ? peso(total) : '—'}</dd>
          </div>
        </dl>
      </div>
    </Dialog>
  )
}
