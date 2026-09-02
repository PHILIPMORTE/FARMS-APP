import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { Dialog, Empty, Spinner } from '@/components/ui'
import { RatingBadge } from '@/components/Ratings'
import { CROP_COLOR, CROP_EMOJI, availableSacks, peso, sacks, titleCase } from '@/lib/format'
import type { Crop } from '@/lib/types'

interface FarmProduct {
  id: string
  variety: string
  crop: Crop
  price: number
  quantity: number
  reserved: number
  photo_url: string | null
  status: string
}

interface BestSeller {
  variety: string
  crop: Crop
  photo_url: string | null
  sacks_sold: number
  orders: number
}

interface Profile {
  farm: {
    id: string
    name: string
    city: string | null
    province: string | null
    address: string | null
    latitude: number | null
    longitude: number | null
  } | null
  products: FarmProduct[]
  best_sellers: BestSeller[]
  total_sold: number
}

export function FarmProfileDialog({
  farmId,
  onClose,
}: {
  farmId: string | null
  onClose(): void
}) {
  const [data, setData] = useState<Profile | null>(null)

  useEffect(() => {
    if (!farmId) return
    setData(null)
    supabase.rpc('farm_profile', { p_farm_id: farmId }).then(({ data: d }) => {
      setData((d as Profile) ?? null)
    })
  }, [farmId])

  if (!farmId) return null

  return (
    <Dialog
      open
      onClose={onClose}
      title={data?.farm?.name ?? 'Farm'}
      description={
        data?.farm
          ? [data.farm.city, data.farm.province].filter(Boolean).join(', ') || 'Farm'
          : undefined
      }
      footer={
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      }
    >
      {!data ? (
        <Spinner label="Loading the farm" />
      ) : (
        <div className="space-y-5">
          {data.farm && <RatingBadge profileId={(data as any).owner_id ?? data.farm.id} compact />}

          {data.farm?.latitude != null && data.farm?.longitude != null && (
            <section>
              <h3 className="mb-2 text-[13px] font-bold uppercase tracking-wide text-soil-400">
                Where the farm is
              </h3>
              <iframe
                title={`${data.farm.name} location`}
                className="h-52 w-full rounded-xl border border-soil-200"
                loading="lazy"
                referrerPolicy="no-referrer-when-downgrade"
                src={`https://maps.google.com/maps?q=${data.farm.latitude},${data.farm.longitude}&z=15&output=embed`}
              />
              <a
                href={`https://www.google.com/maps/search/?api=1&query=${data.farm.latitude},${data.farm.longitude}`}
                target="_blank"
                rel="noreferrer"
                className="mt-2 block text-center text-[13px] font-semibold text-brand-700 hover:underline"
              >
                Open in Google Maps
              </a>
            </section>
          )}

          {data.best_sellers.length > 0 && (
            <section>
              <h3 className="mb-2 text-[13px] font-bold uppercase tracking-wide text-soil-400">
                Best selling
              </h3>
              <ul className="space-y-2">
                {data.best_sellers.map((b, i) => (
                  <li
                    key={b.variety + b.crop}
                    className="flex items-center gap-3 rounded-xl border border-amber-200 bg-amber-50 p-2.5"
                  >
                    <span className="num flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-amber-400 text-[13px] font-bold text-white">
                      {i + 1}
                    </span>
                    {b.photo_url ? (
                      <img
                        src={b.photo_url}
                        alt={b.variety}
                        className="h-12 w-12 shrink-0 rounded-lg object-cover"
                      />
                    ) : (
                      <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg bg-white text-xl">
                        {CROP_EMOJI[b.crop]}
                      </span>
                    )}
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[14px] font-bold text-amber-900">
                        {b.variety}
                      </span>
                      <span className="block text-[12px] text-amber-800">
                        {titleCase(b.crop)}
                      </span>
                    </span>
                    <span className="num shrink-0 text-right text-[12px] text-amber-900">
                      <span className="block font-bold">{sacks(b.sacks_sold)} sacks</span>
                      <span className="block">
                        {b.orders} order{b.orders === 1 ? '' : 's'}
                      </span>
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}

          <section>
            <h3 className="mb-2 text-[13px] font-bold uppercase tracking-wide text-soil-400">
              All products
              <span className="num ml-1.5 font-semibold text-soil-400">
                ({data.products.length})
              </span>
            </h3>

            {data.products.length === 0 ? (
              <Empty
                title="Nothing listed"
                body="This farm has no products on the market right now."
              />
            ) : (
              <ul className="grid grid-cols-2 gap-2">
                {data.products.map((p) => {
                  const avail = availableSacks(p)
                  return (
                    <li
                      key={p.id}
                      className="overflow-hidden rounded-xl border border-soil-200 bg-white"
                    >
                      <div className="relative flex aspect-square items-center justify-center overflow-hidden bg-brand-50">
                        {p.photo_url ? (
                          <img
                            src={p.photo_url}
                            alt={p.variety}
                            loading="lazy"
                            className={`h-full w-full object-cover ${
                              avail === 0 ? 'opacity-50 grayscale' : ''
                            }`}
                          />
                        ) : (
                          <span className="text-4xl">{CROP_EMOJI[p.crop]}</span>
                        )}
                        <span
                          className={`absolute left-0 top-2 rounded-r px-2 py-0.5 text-[9px] font-bold uppercase tracking-wide text-white ${
                            avail === 0 ? 'bg-soil-600' : CROP_COLOR[p.crop].bar
                          }`}
                        >
                          {avail === 0 ? 'Sold out' : titleCase(p.crop)}
                        </span>
                      </div>

                      <div className="p-2">
                        <p className="truncate text-[13px] font-semibold">{p.variety}</p>
                        <p className="num text-[15px] font-bold text-brand-700">{peso(p.price)}</p>
                        <p className="num text-[11px] text-soil-500">
                          {avail === 0 ? 'None left' : `${sacks(avail)} sacks available`}
                        </p>
                      </div>
                    </li>
                  )
                })}
              </ul>
            )}
          </section>

          {data.total_sold > 0 && (
            <p className="rounded-lg bg-soil-50 px-4 py-3 text-center text-[13px] text-soil-600">
              This farm has sold{' '}
              <span className="num font-bold text-soil-900">{sacks(data.total_sold)} sacks</span> in
              completed orders.
            </p>
          )}
        </div>
      )}
    </Dialog>
  )
}
