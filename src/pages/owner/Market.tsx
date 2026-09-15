import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  Badge,
  DataTable,
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
import {
  CROPS,
  CROP_EMOJI,
  VARIETIES,
  availableSacks,
  peso,
  pesoShort,
  effectiveStage,
  isFinishedOrder,
  sacks,
  shortDate,
  titleCase,
} from '@/lib/format'
import { friendlyError, validateAmount, validateSacks, validateRequired } from '@/lib/validation'
import { BuyerContactCard } from '@/components/BuyerContactCard'
import { BuyerPurchases } from '@/components/BuyerPurchases'
import { StageBadge } from '@/components/OrderTimeline'
import type { Crop, Order, Product, Profile, Schedule } from '@/lib/types'

export default function OwnerMarket() {
  const { farm } = useAuth()
  const [items, setItems] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [revenue, setRevenue] = useState(0)
  const [orders, setOrders] = useState<(Order & { buyer?: Profile | null })[]>([])
  const [editing, setEditing] = useState<Product | null>(null)
  const [settling, setSettling] = useState<string | null>(null)
  const [viewingBuyer, setViewingBuyer] = useState<Profile | null>(null)
  const [sukiCounts, setSukiCounts] = useState<Record<string, number>>({})
  const [harvests, setHarvests] = useState<Schedule[]>([])

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

    const { data: full } = await supabase
      .from('orders')
      .select('*, products!inner(variety, crop, price, farm_id), profiles!orders_buyer_id_fkey(*)')
      .eq('products.farm_id', farm.id)
      .order('created_at', { ascending: false })
      .limit(30)

    setOrders(
      ((full as any[]) ?? []).map((o) => ({ ...o, buyer: (o.profiles as Profile) ?? null })),
    )

    const counts: Record<string, number> = {}
    for (const o of ((full as any[]) ?? [])) {
      if (o.stage === 'completed' && o.buyer_id) {
        counts[o.buyer_id] = (counts[o.buyer_id] ?? 0) + 1
      }
    }
    setSukiCounts(counts)

    const { data: hv } = await supabase
      .from('schedules')
      .select('*')
      .eq('farm_id', farm.id)
      .eq('status', 'harvested')
      .order('harvest_date', { ascending: false })
    setHarvests((hv as Schedule[]) ?? [])

  }

  useEffect(() => {
    load()
    if (!farm) return

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

  async function togglePaid(o: Order) {
    setSettling(o.id)
    const { error } = await supabase.rpc('set_order_paid', {
      p_order_id: o.id,
      p_paid: !o.paid,
    })
    setSettling(null)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    toast.success(o.paid ? 'Payment undone' : 'Order marked as paid')
    load()
  }

  const activeOrders = useMemo(() => orders.filter((o) => !isFinishedOrder(o)), [orders])
  const finishedOrders = useMemo(() => orders.filter((o) => isFinishedOrder(o)), [orders])

  const filtered = useMemo(() => {
    if (!items) return []
    const q = query.trim().toLowerCase()
    if (!q) return items
    return items.filter(
      (p) => p.variety.toLowerCase().includes(q) || p.crop.toLowerCase().includes(q),
    )
  }, [items, query])

  if (!items) return <Spinner label="Loading your listings" />

  const available = items.filter((p) => availableSacks(p) > 0).length
  const sold = items.filter((p) => availableSacks(p) === 0).length

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

      <div className="stagger grid grid-cols-3 gap-3">
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
        <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
          {filtered.map((p) => {
            const avail = availableSacks(p)
            const out = avail === 0
            return (
              <article
                key={p.id}
                className="flex flex-col overflow-hidden rounded-lg border border-soil-200 bg-white transition hover:shadow-md"
              >
                <div className="relative flex aspect-square items-center justify-center overflow-hidden bg-brand-50">
                  {p.photo_url ? (
                    <img
                      src={p.photo_url}
                      alt={p.variety}
                      loading="lazy"
                      className={`h-full w-full object-cover ${out ? 'opacity-50 grayscale' : ''}`}
                    />
                  ) : (
                    <span className={`text-6xl ${out ? 'opacity-40 grayscale' : ''}`} aria-hidden>
                      {CROP_EMOJI[p.crop]}
                    </span>
                  )}
                  <span
                    className={`absolute left-0 top-2 rounded-r px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white ${
                      out ? 'bg-soil-600' : avail <= 5 ? 'bg-amber-500' : 'bg-brand-700'
                    }`}
                  >
                    {out ? 'Sold out' : avail <= 5 ? `Only ${sacks(avail)} left` : 'On sale'}
                  </span>
                </div>

                <div className="flex flex-1 flex-col gap-1 p-2.5">
                  <h3 className="line-clamp-2 text-[13px] font-semibold leading-snug">
                    {p.variety}
                  </h3>
                  <span
                    className={`chip mt-0.5 ${
                      p.form === 'milled'
                        ? 'bg-brand-100 text-brand-800'
                        : 'bg-soil-100 text-soil-700'
                    }`}
                  >
                    {p.form === 'milled' ? 'Milled' : 'Unmilled'}
                  </span>
                  <p className="num text-[17px] font-bold text-brand-700">{peso(p.price)}</p>
                  <p className="text-[11px] text-soil-400">per sack · {titleCase(p.crop)}</p>

                  <dl className="mt-1.5 space-y-0.5 border-t border-soil-200 pt-1.5 text-[11px]">
                    <div className="flex justify-between">
                      <dt className="text-soil-400">In stock</dt>
                      <dd className="num font-semibold">{sacks(p.quantity)}</dd>
                    </div>
                    {p.reserved > 0 && (
                      <div className="flex justify-between">
                        <dt className="text-soil-400">Reserved</dt>
                        <dd className="num font-semibold text-amber-600">{sacks(p.reserved)}</dd>
                      </div>
                    )}
                    <div className="flex justify-between">
                      <dt className="text-soil-400">Available</dt>
                      <dd className="num font-bold">{sacks(avail)}</dd>
                    </div>
                  </dl>

                  <div className="mt-2 grid grid-cols-2 gap-1.5">
                    <button
                      className="btn-sm border border-soil-200 hover:bg-soil-100"
                      onClick={() => setEditing(p)}
                    >
                      Edit stock
                    </button>
                    <button
                      onClick={async () => {
                        await supabase.from('products').delete().eq('id', p.id)
                        toast.success('Listing removed')
                        load()
                      }}
                      className="btn-sm border border-soil-200 text-red-600 hover:bg-red-50"
                    >
                      Remove
                    </button>
                  </div>
                </div>
              </article>
            )
          })}
        </div>
      )}

      {activeOrders.length > 0 && (
        <section className="no-print">
          <SectionHeading>
            Incoming orders
            <span className="num ml-2 text-soil-400">({activeOrders.length})</span>
          </SectionHeading>
          <DataTable
            minWidth="50rem"
            headers={[
              { label: 'Order ID' },
              { label: 'Date' },
              { label: 'Product' },
              { label: 'Buyer' },
              { label: 'Sacks', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Stage' },
              { label: 'Payment' },
              { label: 'Contact', align: 'right' },
            ]}
          >
            {activeOrders.map((o) => (
              <tr key={o.id}>
                <td className="num px-4 py-3 font-semibold text-soil-800">{o.order_no ?? '—'}</td>
                <td className="num px-4 py-3 text-soil-600">{shortDate(o.created_at)}</td>
                <td className="px-4 py-3 font-semibold">
                  {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                  {o.products?.variety ?? 'Product'}
                </td>
                <td className="px-4 py-3">
                  {o.buyer ? (
                    <span className="flex flex-wrap items-center gap-1.5">
                      <button
                        onClick={() => setViewingBuyer(o.buyer!)}
                        className="text-left font-semibold text-brand-700 hover:underline"
                      >
                        {o.buyer.name}
                      </button>
                      {(sukiCounts[o.buyer_id] ?? 0) >= 3 && <SukiBadge />}
                    </span>
                  ) : (
                    <span className="block">—</span>
                  )}
                  <span className="block max-w-[14rem] truncate text-[12px] text-soil-400">
                    {[o.buyer?.address, o.buyer?.city].filter(Boolean).join(', ') ||
                      'No address given'}
                  </span>
                </td>
                <td className="num px-4 py-3 text-right font-bold">{sacks(o.quantity)}</td>
                <td className="num px-4 py-3 text-right font-bold text-brand-700">
                  {peso(o.total_price)}
                </td>
                <td className="px-4 py-3">
                  <StageBadge stage={effectiveStage(o)} />
                </td>
                <td className="px-4 py-3">
                  {o.paid ? (
                    <Badge tone="green">Paid</Badge>
                  ) : (
                    <button
                      className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                      disabled={settling === o.id}
                      onClick={() => togglePaid(o)}
                    >
                      {settling === o.id ? '…' : 'Mark paid'}
                    </button>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  {o.buyer?.phone ? (
                    <span className="inline-flex gap-1.5">
                      <a
                        href={`tel:${o.buyer.phone}`}
                        className="btn-sm bg-brand-600 text-white hover:bg-brand-700"
                      >
                        Call
                      </a>
                      <a
                        href={`sms:${o.buyer.phone}`}
                        className="btn-sm border border-soil-200 hover:bg-soil-100"
                      >
                        Text
                      </a>
                    </span>
                  ) : (
                    <span className="text-[12px] text-soil-400">—</span>
                  )}
                </td>
              </tr>
            ))}
          </DataTable>
        </section>
      )}

      {finishedOrders.length > 0 && (
        <section className="no-print">
          <SectionHeading>
            Completed orders
            <span className="num ml-2 text-soil-400">({finishedOrders.length})</span>
          </SectionHeading>
          <DataTable
            minWidth="44rem"
            headers={[
              { label: 'Order ID' },
              { label: 'Date' },
              { label: 'Product' },
              { label: 'Buyer' },
              { label: 'Sacks', align: 'right' },
              { label: 'Total', align: 'right' },
              { label: 'Result' },
            ]}
          >
            {finishedOrders.map((o) => (
              <tr key={o.id}>
                <td className="num px-4 py-3 font-semibold text-soil-800">{o.order_no ?? '—'}</td>
                <td className="num px-4 py-3 text-soil-600">{shortDate(o.created_at)}</td>
                <td className="px-4 py-3 font-semibold">
                  {o.products?.crop ? `${CROP_EMOJI[o.products.crop]} ` : ''}
                  {o.products?.variety ?? 'Product'}
                </td>
                <td className="px-4 py-3">
                  {o.buyer ? (
                    <span className="flex flex-wrap items-center gap-1.5">
                      <button
                        onClick={() => setViewingBuyer(o.buyer!)}
                        className="font-semibold text-brand-700 hover:underline"
                      >
                        {o.buyer.name}
                      </button>
                      {(sukiCounts[o.buyer_id] ?? 0) >= 3 && <SukiBadge />}
                    </span>
                  ) : (
                    '—'
                  )}
                </td>
                <td className="num px-4 py-3 text-right">{sacks(o.quantity)}</td>
                <td className="num px-4 py-3 text-right font-semibold">{peso(o.total_price)}</td>
                <td className="px-4 py-3">
                  <StageBadge stage={effectiveStage(o)} />
                </td>
              </tr>
            ))}
          </DataTable>
        </section>
      )}

      <Dialog
        open={viewingBuyer !== null}
        onClose={() => setViewingBuyer(null)}
        title={viewingBuyer?.name ?? 'Buyer'}
        description={
          viewingBuyer && (sukiCounts[viewingBuyer.id] ?? 0) >= 3
            ? `Suki · ${sukiCounts[viewingBuyer.id]} completed orders`
            : (viewingBuyer?.company ?? 'Buyer')
        }
        footer={
          <button className="btn-ghost" onClick={() => setViewingBuyer(null)}>
            Close
          </button>
        }
      >
        <div className="space-y-4">
          <BuyerContactCard buyer={viewingBuyer} />
          {viewingBuyer && <BuyerPurchases buyerId={viewingBuyer.id} />}
        </div>
      </Dialog>

      <EditStockDialog
        product={editing}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null)
          load()
        }}
      />

      <AddProductDialog
        open={open}
        onClose={() => setOpen(false)}
        farmId={farm?.id ?? ''}
        products={items}
        harvests={harvests}
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
  products,
  harvests,
  onSaved,
}: {
  open: boolean
  onClose(): void
  farmId: string
  products: Product[]
  harvests: Schedule[]
  onSaved(): void
}) {
  const [form, setForm] = useState({
    variety: '',
    customVariety: '',
    crop: 'rice' as Crop,
    quantity: '',
    price: '',
    form: 'unmilled' as 'unmilled' | 'milled',
  })
  const [existing, setExisting] = useState<Product | null>(null)
  const [photo, setPhoto] = useState<File | null>(null)
  const [photoPreview, setPhotoPreview] = useState<string | null>(null)
  const [uploading, setUploading] = useState(false)

  useEffect(() => {
    if (!photo) {
      setPhotoPreview(null)
      return
    }
    const url = URL.createObjectURL(photo)
    setPhotoPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [photo])
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  const set = (k: string, v: string) => {
    setForm((f) => ({ ...f, [k]: v }))
    setErrors((e) => ({ ...e, [k]: null }))
  }

  const cropHarvests = harvests.filter((h) => h.crop === form.crop && (h.actual_sacks ?? 0) > 0)

  const harvestOptions = cropHarvests.map((h) => ({
    value: h.variety,
    label: h.variety,
  }))

  const isMilled = form.form === 'milled'

  const chosenVariety =
    form.variety === '__other' ? form.customVariety.trim() : form.variety.trim()

  const matchedHarvest = cropHarvests.find(
    (h) => h.variety.trim().toLowerCase() === chosenVariety.toLowerCase(),
  )

  const alreadyListed = products
    .filter(
      (p) => p.crop === form.crop && p.variety.trim().toLowerCase() === chosenVariety.toLowerCase(),
    )
    .reduce((sum, p) => sum + p.quantity, 0)

  const maxSacks =
    !isMilled && matchedHarvest
      ? Math.max((matchedHarvest.actual_sacks ?? 0) - alreadyListed, 0)
      : null

  useEffect(() => {
    if (!chosenVariety) {
      setExisting(null)
      return
    }
    const match = products.find(
      (p) =>
        p.crop === form.crop && p.variety.trim().toLowerCase() === chosenVariety.toLowerCase(),
    )
    setExisting(match ?? null)
  }, [chosenVariety, form.crop, products])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = {
      variety: form.variety
        ? null
        : isMilled
          ? 'Choose a variety.'
          : 'Choose a harvested crop to list.',
      customVariety:
        form.variety === '__other' ? validateRequired(form.customVariety, 'Variety name') : null,
      quantity: validateSacks(form.quantity, {
        min: 1,
        ...(maxSacks !== null ? { max: maxSacks } : {}),
      }),
      price: validateAmount(form.price, 'price'),
    }
    setErrors(next)
    if (Object.values(next).some(Boolean)) return

    setBusy(true)

    let photoUrl: string | null = null
    if (photo) {
      setUploading(true)
      const { data: sess } = await supabase.auth.getSession()
      const uid = sess.session?.user.id
      const ext = photo.name.split('.').pop()?.toLowerCase() || 'jpg'
      const path = `${uid}/${Date.now()}.${ext}`
      const { error: upErr } = await supabase.storage
        .from('product-photos')
        .upload(path, photo, { upsert: true, contentType: photo.type })
      setUploading(false)
      if (upErr) {
        setBusy(false)
        toast.error(`Photo upload failed: ${upErr.message}`)
        return
      }
      photoUrl = supabase.storage.from('product-photos').getPublicUrl(path).data.publicUrl
    }

    const { data, error } = await supabase.rpc('add_or_merge_product', {
      p_farm_id: farmId,
      p_variety: chosenVariety,
      p_crop: form.crop,
      p_quantity: parseInt(form.quantity, 10),
      p_price: Number(form.price),
      p_form: form.form,
    })
    setBusy(false)

    if (error) {
      toast.error(friendlyError(error))
      return
    }
    if (photoUrl && (data as any)?.id) {
      await supabase.from('products').update({ photo_url: photoUrl }).eq('id', (data as any).id)
    }

    toast.success(
      (data as any)?.merged
        ? `Added to the existing ${chosenVariety} listing`
        : 'Product listed',
    )
    setForm({
      variety: '',
      customVariety: '',
      crop: 'rice',
      quantity: '',
      price: '',
      form: 'unmilled',
    })
    setPhoto(null)
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
      description="Buyers order by the sack."
      footer={
        <>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            onClick={submit}
            disabled={busy || (!isMilled && harvestOptions.length === 0)}
          >
            {uploading ? 'Uploading photo…' : busy ? 'Listing…' : 'Add product'}
          </button>
        </>
      }
    >
      <form onSubmit={submit} className="space-y-4" noValidate>
        {isMilled && (
          <div className="rounded-lg border border-brand-200 bg-brand-50 px-4 py-3">
            <p className="text-[13px] font-bold text-brand-900">Milled rice is listed freely</p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-brand-900/80">
              Milled stock does not have to come from your own harvest, so you set the variety,
              the number of sacks, and the price yourself.
            </p>
          </div>
        )}

        {!isMilled && harvestOptions.length === 0 && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              No harvested {form.crop} yet
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
              Record a harvest on the Calendar first. Once a planting is harvested, its variety
              appears here ready to list.
            </p>
          </div>
        )}

        <div>
          <label className="label">How is it being sold?</label>
          <div className="grid grid-cols-2 gap-2">
            {(['unmilled', 'milled'] as const).map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => set('form', f)}
                aria-pressed={form.form === f}
                className={`rounded-xl border-2 px-3 py-3 text-left transition ${
                  form.form === f
                    ? 'border-brand-600 bg-brand-50'
                    : 'border-soil-200 hover:bg-soil-50'
                }`}
              >
                <span className="block text-[14px] font-bold">
                  {f === 'milled' ? 'Milled' : 'Unmilled'}
                </span>
                <span className="block text-[12px] leading-snug text-soil-600">
                  {f === 'milled'
                    ? 'Ready to cook and sell by the sack'
                    : 'Straight from the harvest, not yet milled'}
                </span>
              </button>
            ))}
          </div>
        </div>

        {form.variety === '__other' && isMilled && (
          <Field
            label="Variety name"
            placeholder="Type the variety"
            value={form.customVariety}
            error={errors.customVariety}
            onChange={(e) => set('customVariety', e.target.value)}
          />
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <Select
            label="Crop"
            value={form.crop}
            onChange={(e) => {
              set('crop', e.target.value)
              set('variety', '')
            }}
            options={CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` }))}
          />
          <Select
            label="Variety"
            value={form.variety}
            error={errors.variety}
            onChange={(e) => set('variety', e.target.value)}
            disabled={!isMilled && harvestOptions.length === 0}
            options={
              isMilled
                ? [
                    { value: '', label: 'Choose a variety…' },
                    ...VARIETIES[form.crop].map((v) => ({ value: v, label: v })),
                    { value: '__other', label: 'Other (type it in)' },
                  ]
                : harvestOptions.length === 0
                  ? [{ value: '', label: 'No harvested crops yet' }]
                  : [{ value: '', label: 'Choose a variety…' }, ...harvestOptions]
            }
          />
        </div>

        <div>
          <SackInput
            label="Number of sacks"
            placeholder="0"
            max={maxSacks ?? undefined}
            value={form.quantity}
            error={errors.quantity}
            onChange={(e) => set('quantity', e.target.value)}
          />

          {matchedHarvest && (
            <dl className="mt-2 space-y-1 rounded-lg bg-soil-50 px-3.5 py-2.5 text-[13px]">
              <div className="flex justify-between gap-3">
                <dt className="text-soil-600">
                  Harvested {shortDate(matchedHarvest.harvested_at ?? matchedHarvest.harvest_date)}
                </dt>
                <dd className="num font-semibold">
                  {sacks(matchedHarvest.actual_sacks ?? 0)} sacks
                </dd>
              </div>
              {alreadyListed > 0 && (
                <div className="flex justify-between gap-3">
                  <dt className="text-soil-600">Already listed</dt>
                  <dd className="num font-semibold">{sacks(alreadyListed)} sacks</dd>
                </div>
              )}
              <div className="flex justify-between gap-3 border-t border-soil-200 pt-1">
                <dt className="font-semibold">Most you can sell</dt>
                <dd className="num font-bold text-brand-700">{sacks(maxSacks ?? 0)} sacks</dd>
              </div>
            </dl>
          )}
        </div>
        <PesoInput
          label="Price per sack"
          placeholder="0.00"
          value={form.price}
          error={errors.price}
          onChange={(e) => set('price', e.target.value)}
        />
        <div>
          <label className="label" htmlFor="prodphoto">
            Product photo
          </label>
          {photoPreview ? (
            <div className="overflow-hidden rounded-xl border border-soil-200">
              <img src={photoPreview} alt="Your product" className="max-h-48 w-full bg-soil-50 object-contain" />
              <div className="flex items-center justify-between gap-3 border-t border-soil-200 px-3 py-2">
                <span className="truncate text-[12px] text-soil-600">{photo?.name}</span>
                <button
                  type="button"
                  onClick={() => setPhoto(null)}
                  className="shrink-0 text-[13px] font-semibold text-red-600 hover:underline"
                >
                  Remove
                </button>
              </div>
            </div>
          ) : (
            <label
              htmlFor="prodphoto"
              className="flex cursor-pointer flex-col items-center gap-1 rounded-xl border-2 border-dashed
                         border-soil-200 px-4 py-6 text-center transition hover:bg-soil-50"
            >
              <span className="text-2xl" aria-hidden>
                📷
              </span>
              <span className="text-[13px] font-semibold">Attach a photo</span>
              <span className="text-[12px] text-soil-400">
                Optional, but buyers are far more likely to order with one
              </span>
            </label>
          )}
          <input
            id="prodphoto"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            capture="environment"
            className="sr-only"
            onChange={(e) => {
              const f = e.target.files?.[0]
              if (!f) return
              if (f.size > 5 * 1024 * 1024) {
                toast.error('That photo is over 5 MB. Try a smaller one.')
                return
              }
              setPhoto(f)
            }}
          />
        </div>

        {existing && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              You already list {existing.variety}
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-amber-800">
              These sacks will be added to that listing, taking it from{' '}
              <span className="num font-semibold">{sacks(existing.quantity)}</span> to{' '}
              <span className="num font-semibold">
                {sacks(existing.quantity + (parseInt(form.quantity || '0', 10) || 0))}
              </span>{' '}
              sacks, rather than creating a second entry.
            </p>
          </div>
        )}

        {total !== null && (
          <p className="rounded-xl bg-brand-50 px-4 py-3 text-sm font-semibold text-brand-900">
            Whole listing is worth <span className="num">{peso(total)}</span>
          </p>
        )}
      </form>
    </Dialog>
  )
}

function SukiBadge() {
  return (
    <span
      title="A regular customer — three or more completed orders"
      className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-amber-800"
    >
      <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
        <path d="M12 2l2.9 6.1 6.6.9-4.8 4.6 1.2 6.6L12 17.1 6.1 20.2l1.2-6.6L2.5 9l6.6-.9z" />
      </svg>
      Suki
    </span>
  )
}

function EditStockDialog({
  product,
  onClose,
  onSaved,
}: {
  product: Product | null
  onClose(): void
  onSaved(): void
}) {
  const [qty, setQty] = useState('')
  const [newPrice, setNewPrice] = useState('')
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (product) {
      setQty(String(product.quantity))
      setReason('')
      setError(null)
      setConfirming(false)
    }
  }, [product?.id])

  if (!product) return null

  const next = /^\d+$/.test(qty) ? parseInt(qty, 10) : null
  const diff = next === null ? 0 : next - product.quantity

  const major =
    next !== null &&
    (next === 0 || Math.abs(diff) >= Math.max(10, Math.ceil(product.quantity / 2)))

  async function save() {
    const err = validateSacks(qty, { min: 0 })
    setError(err)
    if (err) return
    if (newPrice === '' || Number(newPrice) < 0) {
      toast.error('Enter a valid price per sack.')
      return
    }

    if (major && !confirming) {
      setConfirming(true)
      return
    }

    setBusy(true)
    const { error: rpcError } = await supabase.rpc('update_product_listing', {
      p_product_id: product!.id,
      p_new_quantity: parseInt(qty, 10),
      p_new_price: Number(newPrice),
      p_reason: reason.trim() || (diff > 0 ? 'Restocked' : 'Stock corrected'),
    })
    setBusy(false)

    if (rpcError) {
      toast.error(friendlyError(rpcError))
      return
    }
    toast.success('Listing updated — buyers see this immediately')
    onSaved()
  }

  return (
    <Dialog
      open
      onClose={onClose}
      title={`Edit listing — ${product.variety}`}
      description={`${sacks(product.quantity)} sacks at ${peso(product.price)} each`}
      footer={
        <>
          <button
            type="button"
            className="btn-ghost"
            onClick={() => (confirming ? setConfirming(false) : onClose())}
          >
            {confirming ? 'Go back' : 'Cancel'}
          </button>
          <button
            className={confirming ? 'btn-danger' : 'btn-primary'}
            onClick={save}
            disabled={busy || next === null}
          >
            {busy ? 'Saving…' : confirming ? 'Yes, save this change' : 'Save changes'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <SackInput
          label="New stock level"
          min={0}
          value={qty}
          error={error}
          hint={
            product.reserved > 0
              ? `${sacks(product.reserved)} sack(s) are reserved by open orders.`
              : 'Set to 0 to mark this product out of stock.'
          }
          onChange={(e) => {
            setQty(e.target.value)
            setError(null)
            setConfirming(false)
          }}
        />

        <PesoInput
          label="Price per sack"
          placeholder="0.00"
          value={newPrice}
          hint={
            Number(newPrice) !== Number(product.price)
              ? `Currently ${peso(product.price)} — buyers see the new price straight away`
              : undefined
          }
          onChange={(e) => setNewPrice(e.target.value)}
        />

        <Field
          label="Reason for the change"
          placeholder="e.g. New harvest added, spoilage, recount"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />

        {next !== null && diff !== 0 && (
          <dl className="space-y-1.5 rounded-lg bg-soil-50 px-4 py-3 text-[13px]">
            <div className="flex justify-between">
              <dt className="text-soil-600">Change</dt>
              <dd className={`num font-bold ${diff > 0 ? 'text-green-700' : 'text-red-600'}`}>
                {diff > 0 ? '+' : ''}
                {sacks(Math.abs(diff))} sacks
              </dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-soil-600">New weight</dt>
              <dd className="num font-semibold">{next * 25} kg</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-soil-600">Buyers will see</dt>
              <dd className="font-semibold">
                {next === 0 ? 'Out of stock' : next <= 5 ? 'Low stock' : 'Available'}
              </dd>
            </div>
          </dl>
        )}

        {confirming && (
          <div className="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3">
            <p className="text-[13px] font-bold text-amber-900">
              {next === 0 ? 'This will take the product off the market' : 'That is a large change'}
            </p>
            <p className="mt-1 text-[13px] leading-relaxed text-amber-800">
              {next === 0
                ? 'Buyers will see it as out of stock and cannot order it until you restock.'
                : `Stock goes from ${sacks(product.quantity)} to ${sacks(next!)} sacks. Check the number before saving.`}
            </p>
          </div>
        )}

        <p className="text-[12px] text-soil-400">
          This change is recorded with your name and the time, and appears in the stock history
          below the listings.
        </p>
      </div>
    </Dialog>
  )
}
