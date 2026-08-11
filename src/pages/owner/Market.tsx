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
  SackInput,
  Search,
  SectionHeading,
  Select,
  Spinner,
  Stat,
} from '@/components/ui'
import { CROPS, CROP_EMOJI, peso, pesoShort, sacks, shortDate, titleCase, weightNote } from '@/lib/format'
import { friendlyError, validateAmount, validateRequired, validateSacks } from '@/lib/validation'
import { BuyerContactCard } from '@/components/BuyerContactCard'
import type { Crop, Order, Product, Profile } from '@/lib/types'

export default function OwnerMarket() {
  const { farm } = useAuth()
  const [items, setItems] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [revenue, setRevenue] = useState(0)
  const [orders, setOrders] = useState<(Order & { buyer?: Profile | null })[]>([])

  async function load() {
    if (!farm) return
    const [{ data }, { data: orderRows }] = await Promise.all([
      supabase.from('products').select('*').eq('farm_id', farm.id).order('created_at', { ascending: false }),
      supabase
        .from('orders')
        .select('total_price, products!inner(farm_id)')
        .eq('products.farm_id', farm.id),
    ])
    setItems((data as Product[]) ?? [])
    setRevenue((orderRows ?? []).reduce((s: number, o: any) => s + Number(o.total_price), 0))

    // Incoming orders, newest first, with the buyer's contact details attached.
    const { data: full } = await supabase
      .from('orders')
      .select('*, products!inner(variety, crop, price, farm_id), profiles(*)')
      .eq('products.farm_id', farm.id)
      .order('created_at', { ascending: false })
      .limit(30)

    setOrders(
      ((full as any[]) ?? []).map((o) => ({ ...o, buyer: (o.profiles as Profile) ?? null })),
    )
  }

  useEffect(() => {
    load()
    if (!farm) return

    // Live sync: a buyer's purchase updates these listings without a refresh.
    const channel = supabase
      .channel(`owner-market:${farm.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'products', filter: `farm_id=eq.${farm.id}` },
        () => load(),
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [farm?.id])

  const filtered = useMemo(() => {
    if (!items) return []
    const q = query.trim().toLowerCase()
    if (!q) return items
    return items.filter(
      (p) => p.variety.toLowerCase().includes(q) || p.crop.toLowerCase().includes(q),
    )
  }, [items, query])

  if (!items) return <Spinner label="Loading your listings" />

  const available = items.filter((p) => p.status === 'available').length
  const sold = items.filter((p) => p.status === 'sold').length

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Market</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            What you list here appears instantly on the buyer market.
          </p>
        </div>
        <button className="btn-primary" onClick={() => setOpen(true)}>
          Add product
        </button>
      </div>

      <div className="grid grid-cols-3 gap-3">
        <Stat label="Available" value={String(available)} sub="Listings" />
        <Stat label="Sold out" value={String(sold)} sub="Listings" />
        <Stat label="Sales revenue" value={pesoShort(revenue)} accent="green" />
      </div>

      <Search value={query} onChange={setQuery} placeholder="Search variety or crop" />

      {filtered.length === 0 ? (
        <Empty
          title={query ? 'Nothing matches that search' : 'No listings yet'}
          body={
            query
              ? 'Try the variety name, or a crop like rice, corn or watermelon.'
              : 'Add your harvest as a listing and buyers can order it by the sack.'
          }
          action={
            !query && (
              <button className="btn-primary" onClick={() => setOpen(true)}>
                Add product
              </button>
            )
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
                <Badge
                  tone={p.status === 'available' ? 'green' : p.status === 'reserved' ? 'amber' : 'grey'}
                >
                  {titleCase(p.status)}
                </Badge>
              </div>
              <div>
                <h3 className="text-base font-bold leading-snug">{p.variety}</h3>
                <p className="text-[13px] text-soil-400">{titleCase(p.crop)}</p>
              </div>
              <div className="mt-auto flex items-end justify-between gap-3 border-t border-soil-200/70 pt-3">
                <div>
                  <p className="num text-lg font-bold">{sacks(p.quantity)}</p>
                  <p className="text-[12px] text-soil-400">{weightNote(p.quantity)}</p>
                </div>
                <div className="text-right">
                  <p className="num text-base font-bold text-brand-700">{peso(p.price)}</p>
                  <p className="text-[12px] text-soil-400">per sack</p>
                </div>
              </div>
              <button
                onClick={async () => {
                  await supabase.from('products').delete().eq('id', p.id)
                  toast.success('Listing removed')
                  load()
                }}
                className="text-[13px] font-semibold text-soil-400 hover:text-red-600"
              >
                Remove listing
              </button>
            </article>
          ))}
        </div>
      )}

      {orders.length > 0 && (
        <section>
          <SectionHeading>Incoming orders</SectionHeading>
          <div className="grid gap-3 lg:grid-cols-2">
            {orders.map((o) => (
              <article key={o.id} className="card space-y-3 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h3 className="text-[15px] font-bold">
                      {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                      {o.products?.variety ?? 'Product'}
                    </h3>
                    <p className="text-[12px] text-soil-400">{shortDate(o.created_at)}</p>
                  </div>
                  <Badge tone={o.status === 'completed' ? 'green' : 'amber'}>
                    {titleCase(o.status)}
                  </Badge>
                </div>

                <dl className="space-y-1 text-[13px]">
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Quantity</dt>
                    <dd className="num font-semibold">{sacks(o.quantity)} sacks</dd>
                  </div>
                  <div className="flex justify-between">
                    <dt className="text-soil-600">Weight</dt>
                    <dd className="num font-semibold">{weightNote(o.quantity).split('= ')[1]}</dd>
                  </div>
                  <div className="flex justify-between border-t border-soil-200 pt-1">
                    <dt className="font-bold">Total</dt>
                    <dd className="num font-bold text-brand-700">{peso(o.total_price)}</dd>
                  </div>
                </dl>

                <BuyerContactCard buyer={o.buyer} />
              </article>
            ))}
          </div>
        </section>
      )}

      <AddProductDialog
        open={open}
        onClose={() => setOpen(false)}
        farmId={farm?.id ?? ''}
        onSaved={() => {
          setOpen(false)
          load()
        }}
      />
    </div>
  )
}

function AddProductDialog({
  open,
  onClose,
  farmId,
  onSaved,
}: {
  open: boolean
  onClose(): void
  farmId: string
  onSaved(): void
}) {
  const [form, setForm] = useState({ variety: '', crop: 'rice' as Crop, quantity: '', price: '' })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      variety: validateRequired(form.variety, 'Variety'),
      quantity: validateSacks(form.quantity, { min: 1 }),
      price: validateAmount(form.price, 'price'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)
    const { error } = await supabase.from('products').insert({
      farm_id: farmId,
      variety: form.variety.trim(),
      crop: form.crop,
      // parseInt, not Number — a sack count is always a whole number.
      quantity: parseInt(form.quantity, 10),
      price: Number(form.price),
      status: 'available',
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success('Product listed')
    setForm({ variety: '', crop: 'rice', quantity: '', price: '' })
    onSaved()
  }

  const total =
    /^\d+$/.test(form.quantity) && form.price !== ''
      ? parseInt(form.quantity, 10) * Number(form.price)
      : null

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Add a product"
      description="Buyers order by the sack. One sack is 25 kg."
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-primary" onClick={submit} disabled={busy}>
            {busy ? 'Listing…' : 'Add product'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        <Field
          label="Variety"
          placeholder="e.g. Dinorado, Sweet Yellow"
          value={form.variety}
          error={errors.variety}
          onChange={(e) => set('variety', e.target.value)}
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => set('crop', e.target.value)}
            options={CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` }))}
          />
          <SackInput
            label="Number of sacks"
            placeholder="0"
            value={form.quantity}
            error={errors.quantity}
            onChange={(e) => set('quantity', e.target.value)}
          />
        </div>
        <PesoInput
          label="Price per sack"
          placeholder="0.00"
          value={form.price}
          error={errors.price}
          hint={form.quantity ? weightNote(form.quantity) : '1 sack = 25 kg'}
          onChange={(e) => set('price', e.target.value)}
        />
        {total !== null && (
          <p className="rounded-xl bg-brand-50 px-4 py-3 text-sm font-semibold text-brand-900">
            Whole listing is worth <span className="num">{peso(total)}</span>
          </p>
        )}
      </form>
    </Dialog>
  )
}
