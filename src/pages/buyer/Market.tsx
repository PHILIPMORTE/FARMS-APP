import { useCallback, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import {
  DataTable,
  Dialog,
  Empty,
  PesoInput,
  SackInput,
  Search,
  Select,
  Spinner,
  ViewToggle,
} from '@/components/ui'
import { TopFarms } from '@/components/TopFarms'
import { FarmProfileDialog } from '@/components/FarmProfileDialog'
import {
  CROPS,
  CROP_EMOJI,
  KG_PER_SACK,
  availableSacks,
  peso,
  sacks,
  titleCase,
  toSacks,
  weightNote,
} from '@/lib/format'
import { friendlyError, validateSacks } from '@/lib/validation'
import type { Product } from '@/lib/types'

export default function BuyerMarket() {
  const { profile } = useAuth()
  const [items, setItems] = useState<Product[] | null>(null)
  const [query, setQuery] = useState('')
  const [buying, setBuying] = useState<Product | null>(null)
  const [crop, setCrop] = useState('all')
  const [availability, setAvailability] = useState('all')
  const [farmFilter, setFarmFilter] = useState('all')
  const [sort, setSort] = useState('newest')
  const [maxPrice, setMaxPrice] = useState('')
  const [filtersOpen, setFiltersOpen] = useState(false)
  const [view, setView] = useState<'grid' | 'table'>('grid')
  const [viewingFarm, setViewingFarm] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('*, farms(name, city, province)')
      .order('quantity', { ascending: false })
      .order('created_at', { ascending: false })
    setItems((data as unknown as Product[]) ?? [])
  }, [])

  useEffect(() => {
    load()

    const channel = supabase
      .channel('buyer-market')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, () => load())
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [load])

  const farmNames = useMemo(
    () => [...new Set((items ?? []).map((p) => p.farms?.name).filter(Boolean) as string[])].sort(),
    [items],
  )

  const filtered = useMemo(() => {
    if (!items) return []
    const q = query.trim().toLowerCase()
    const cap = maxPrice === '' ? null : Number(maxPrice)

    const list = items.filter((p) => {
      if (q) {
        const hit =
          p.variety.toLowerCase().includes(q) ||
          p.crop.toLowerCase().includes(q) ||
          (p.farms?.name ?? '').toLowerCase().includes(q)
        if (!hit) return false
      }
      if (crop !== 'all' && p.crop !== crop) return false
      if (farmFilter !== 'all' && p.farms?.name !== farmFilter) return false
      const avail = availableSacks(p)
      if (availability === 'in' && avail <= 0) return false
      if (availability === 'low' && (avail === 0 || avail > 5)) return false
      if (availability === 'out' && avail > 0) return false
      if (cap !== null && Number(p.price) > cap) return false
      return true
    })

    const sorted = [...list]
    if (sort === 'price_low') sorted.sort((a, b) => Number(a.price) - Number(b.price))
    else if (sort === 'price_high') sorted.sort((a, b) => Number(b.price) - Number(a.price))
    else if (sort === 'stock') sorted.sort((a, b) => b.quantity - a.quantity)
    else sorted.sort((a, b) => +new Date(b.created_at) - +new Date(a.created_at))

    return sorted.sort(
      (a, b) => (availableSacks(a) === 0 ? 1 : 0) - (availableSacks(b) === 0 ? 1 : 0),
    )
  }, [items, query, crop, availability, farmFilter, sort, maxPrice])

  const activeFilters =
    (crop !== 'all' ? 1 : 0) +
    (availability !== 'all' ? 1 : 0) +
    (farmFilter !== 'all' ? 1 : 0) +
    (maxPrice !== '' ? 1 : 0)

  function clearFilters() {
    setCrop('all')
    setAvailability('all')
    setFarmFilter('all')
    setMaxPrice('')
    setSort('newest')
  }

  if (!items) return <Spinner label="Loading the market" />

  return (
    <div className="animate-fade-up space-y-5">
      <div>
        <h1 className="text-[22px] font-bold">Market</h1>
        <p className="mt-0.5 text-[13px] text-soil-600">
          Fresh from Philippine farms, sold by the sack. One sack is {KG_PER_SACK} kg.
        </p>
      </div>

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

      <div className="space-y-3">
        <div className="flex gap-2">
          <div className="flex-1">
            <Search value={query} onChange={setQuery} placeholder="Search variety, crop or farm" />
          </div>
          <ViewToggle view={view} onChange={setView} />
          <button
            onClick={() => setFiltersOpen((v) => !v)}
            aria-expanded={filtersOpen}
            className={`btn shrink-0 px-3.5 ${
              activeFilters > 0 ? 'bg-brand-600 text-white' : 'btn-ghost'
            }`}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M22 3H2l8 9.5V19l4 2v-8.5z" />
            </svg>
            Filter
            {activeFilters > 0 && (
              <span className="num rounded-full bg-white/25 px-1.5 text-[11px]">{activeFilters}</span>
            )}
          </button>
        </div>

        {filtersOpen && (
          <div className="card space-y-3 p-4">
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <Select
                label="Crop"
                value={crop}
                onChange={(e) => setCrop(e.target.value)}
                options={[
                  { value: 'all', label: 'All crops' },
                  ...CROPS.map((c) => ({ value: c, label: `${CROP_EMOJI[c]} ${titleCase(c)}` })),
                ]}
              />
              <Select
                label="Availability"
                value={availability}
                onChange={(e) => setAvailability(e.target.value)}
                options={[
                  { value: 'all', label: 'Any' },
                  { value: 'in', label: 'In stock' },
                  { value: 'low', label: 'Low stock' },
                  { value: 'out', label: 'Out of stock' },
                ]}
              />
              <Select
                label="Farm"
                value={farmFilter}
                onChange={(e) => setFarmFilter(e.target.value)}
                options={[
                  { value: 'all', label: 'All farms' },
                  ...farmNames.map((n) => ({ value: n, label: n })),
                ]}
              />
              <Select
                label="Sort by"
                value={sort}
                onChange={(e) => setSort(e.target.value)}
                options={[
                  { value: 'newest', label: 'Newest first' },
                  { value: 'price_low', label: 'Price: low to high' },
                  { value: 'price_high', label: 'Price: high to low' },
                  { value: 'stock', label: 'Most stock' },
                ]}
              />
              <PesoInput
                label="Highest price per sack"
                placeholder="Any"
                className="sm:col-span-2"
                value={maxPrice}
                onChange={(e) => setMaxPrice(e.target.value)}
              />
            </div>

            <div className="flex items-center justify-between gap-3 border-t border-soil-200 pt-3">
              <p className="text-[13px] text-soil-600">
                <span className="num font-bold">{filtered.length}</span>{' '}
                {filtered.length === 1 ? 'product' : 'products'}
              </p>
              {activeFilters > 0 && (
                <button
                  onClick={clearFilters}
                  className="text-[13px] font-semibold text-brand-700 hover:underline"
                >
                  Clear filters
                </button>
              )}
            </div>
          </div>
        )}
      </div>

      <details className="card group">
        <summary className="flex cursor-pointer items-center justify-between px-4 py-3 text-[14px] font-semibold">
          <span>🏆 Top selling farms this week</span>
          <svg
            className="text-soil-400 transition group-open:rotate-180"
            width="16" height="16" viewBox="0 0 24 24" fill="none"
            stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"
          >
            <path d="m6 9 6 6 6-6" />
          </svg>
        </summary>
        <div className="border-t border-soil-200 p-4">
          <TopFarms limit={5} showPeriodPicker={false} />
        </div>
      </details>

      {filtered.length === 0 ? (
        <Empty
          title={query ? 'Nothing matches that search' : 'Nothing for sale right now'}
          body={
            query
              ? 'Try a crop name like rice, corn or watermelon.'
              : 'Farms list their harvest here as it comes in. Check back shortly.'
          }
        />
      ) : view === 'table' ? (
        <DataTable
          minWidth="46rem"
          headers={[
            { label: 'Product' },
            { label: 'Farm' },
            { label: 'Available', align: 'right' },
            { label: 'Price per sack', align: 'right' },
            { label: 'Status' },
            { label: '', align: 'right' },
          ]}
        >
          {filtered.map((p) => (
            <tr key={p.id} className={availableSacks(p) === 0 ? 'bg-soil-50/60' : ''}>
              <td className="px-4 py-3">
                <span className="block font-semibold">
                  {CROP_EMOJI[p.crop]} {p.variety}
                </span>
                <span className="block text-[12px] text-soil-400">{titleCase(p.crop)}</span>
              </td>
              <td className="px-4 py-3 text-soil-600">
                <button
                  onClick={() => p.farm_id && setViewingFarm(p.farm_id)}
                  className="block font-semibold text-brand-700 hover:underline"
                >
                  {p.farms?.name ?? 'Farm'}
                </button>
                {p.farms?.city && (
                  <span className="block text-[12px] text-soil-400">{p.farms.city}</span>
                )}
              </td>
              <td className="num px-4 py-3 text-right">
                {availableSacks(p) === 0 ? (
                  <span className="text-soil-400">—</span>
                ) : (
                  <>
                    <span className="block font-bold">{sacks(availableSacks(p))} sacks</span>
                    <span className="block text-[12px] text-soil-400">
                      {availableSacks(p) * KG_PER_SACK} kg
                    </span>
                  </>
                )}
              </td>
              <td className="num px-4 py-3 text-right font-bold text-brand-700">
                {peso(p.price)}
              </td>
              <td className="px-4 py-3">
                <span
                  className={`chip ${
                    availableSacks(p) === 0
                      ? 'bg-soil-200 text-soil-600'
                      : availableSacks(p) <= 5
                        ? 'bg-amber-100 text-amber-700'
                        : 'bg-green-100 text-green-700'
                  }`}
                >
                  {availableSacks(p) === 0
                    ? 'Out of stock'
                    : availableSacks(p) <= 5
                      ? 'Low stock'
                      : 'In stock'}
                </span>
              </td>
              <td className="px-4 py-3 text-right">
                <button
                  className={`btn-sm ${
                    p.quantity === 0
                      ? 'cursor-not-allowed bg-soil-100 text-soil-400'
                      : 'bg-brand-600 text-white hover:bg-brand-700'
                  }`}
                  disabled={availableSacks(p) === 0}
                  onClick={() => setBuying(p)}
                >
                  {availableSacks(p) === 0 ? 'Unavailable' : 'Buy'}
                </button>
              </td>
            </tr>
          ))}
        </DataTable>
      ) : (
        <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
          {filtered.map((p) => {
            const avail = availableSacks(p)
            const out = avail === 0
            const low = !out && avail <= 5
            return (
              <article
                key={p.id}
                className="group relative flex flex-col overflow-hidden rounded-lg border border-soil-200
                           bg-white transition hover:shadow-md"
              >
                <div className="relative flex aspect-square items-center justify-center overflow-hidden bg-brand-50">
                  {p.photo_url ? (
                    <img
                      src={p.photo_url}
                      alt={p.variety}
                      loading="lazy"
                      className={`h-full w-full object-cover ${out ? 'grayscale opacity-50' : ''}`}
                    />
                  ) : (
                    <span className={`text-6xl ${out ? 'grayscale opacity-40' : ''}`} aria-hidden>
                      {CROP_EMOJI[p.crop]}
                    </span>
                  )}
                  {out && (
                    <span className="absolute inset-0 flex items-center justify-center bg-soil-900/55">
                      <span className="rounded-full bg-white/95 px-3 py-1.5 text-[12px] font-bold text-soil-800">
                        Out of stock
                      </span>
                    </span>
                  )}
                  {low && (
                    <span className="absolute left-0 top-2 rounded-r bg-amber-500 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white">
                      Only {sacks(avail)} left
                    </span>
                  )}
                  <span className="absolute bottom-0 left-0 bg-brand-700/90 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white">
                    {titleCase(p.crop)}
                  </span>
                </div>

                <div className="flex flex-1 flex-col gap-1 p-2.5">
                  <h2 className="line-clamp-2 text-[13px] leading-snug text-soil-800">
                    {p.variety}
                  </h2>

                  <p className="num text-[17px] font-bold text-brand-700">{peso(p.price)}</p>
                  <p className="text-[11px] text-soil-400">per sack · {KG_PER_SACK} kg</p>

                  <div className="mt-auto space-y-1 pt-1.5">
                    <p className="num text-[11px] text-soil-600">
                      {out ? 'No stock' : `${sacks(avail)} sacks available`}
                    </p>
                    <p className="flex items-center gap-0.5 truncate text-[11px] text-soil-400">
                      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4">
                        <path d="M12 21s7-6.3 7-11a7 7 0 1 0-14 0c0 4.7 7 11 7 11z" />
                        <circle cx="12" cy="10" r="2.4" />
                      </svg>
                      <button
                        onClick={(ev) => {
                          ev.stopPropagation()
                          if (p.farm_id) setViewingFarm(p.farm_id)
                        }}
                        className="truncate hover:text-brand-700 hover:underline"
                      >
                        {p.farms?.name || p.farms?.city || 'Farm'}
                      </button>
                    </p>
                  </div>

                  <button
                    className={`btn-sm mt-1.5 w-full justify-center py-2 ${
                      out
                        ? 'cursor-not-allowed bg-soil-100 text-soil-400'
                        : 'bg-brand-600 text-white hover:bg-brand-700'
                    }`}
                    disabled={out}
                    onClick={() => setBuying(p)}
                  >
                    {out ? 'Unavailable' : 'Buy Now'}
                  </button>
                </div>
              </article>
            )
          })}
        </div>
      )}

      <FarmProfileDialog farmId={viewingFarm} onClose={() => setViewingFarm(null)} />

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

  const stock = availableSacks(product)
  const asked = /^\d+$/.test(qty) ? toSacks(qty) : null
  const tooMany = asked !== null && asked > stock
  const valid = asked !== null && asked >= 1 && asked <= stock
  const total = valid ? asked * Number(product.price) : 0

  async function confirm() {
    const err = validateSacks(qty, { min: 1, max: availableSacks(product!) })
    setError(err)
    if (err) return

    setBusy(true)

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

        <div className="flex items-center justify-between gap-3 rounded-lg bg-brand-50 px-4 py-3">
          <span className="text-[13px] font-semibold text-brand-900">Available now</span>
          <span className="num text-[15px] font-bold text-brand-900">
            {sacks(stock)} sacks
          </span>
        </div>

        <SackInput
          label="How many sacks"
          min={1}
          max={stock}
          value={qty}
          error={error}
          hint={`Up to ${sacks(stock)} · 1 sack = ${KG_PER_SACK} kg`}
          onChange={(e) => {
            setQty(e.target.value)
            setError(null)
          }}
        />

        {tooMany && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3">
            <p className="text-[13px] font-bold text-red-800">
              Only {sacks(stock)} sacks are available
            </p>
            <p className="mt-0.5 text-[13px] leading-relaxed text-red-700">
              You asked for {sacks(asked!)}. Lower your quantity to continue.
            </p>
            <button
              type="button"
              onClick={() => {
                setQty(String(stock))
                setError(null)
              }}
              className="mt-1.5 text-[13px] font-bold text-red-800 underline"
            >
              Order all {sacks(stock)} instead
            </button>
          </div>
        )}

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
