import { useState } from 'react'
import { initials } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { Profile } from '@/lib/types'

/**
 * Everything the farm owner needs to reach a buyer and find them: name,
 * company, a tappable number, and a map of the delivery address.
 *
 * The map is a plain Google Maps embed built from the address text. It needs
 * no API key and costs nothing, which matters for a project that has to keep
 * running after the defence.
 */
export function BuyerContactCard({ buyer }: { buyer: Profile | null | undefined }) {
  const [mapOpen, setMapOpen] = useState(false)

  if (!buyer) {
    return (
      <p className="rounded-lg bg-soil-100 px-3.5 py-2.5 text-[13px] text-soil-600">
        Buyer details are not available for this order.
      </p>
    )
  }

  const address = [buyer.address, buyer.city, buyer.zip_code].filter(Boolean).join(', ')
  const mapQuery = encodeURIComponent(address || buyer.city || '')

  return (
    <div className="rounded-xl border border-soil-200 bg-white p-4">
      <div className="flex items-start gap-3">
        <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-600 text-[13px] font-semibold text-white">
          {initials(buyer.name || 'B')}
        </span>
        <div className="min-w-0 flex-1">
          <p className="truncate text-[15px] font-bold">{buyer.name || 'Buyer'}</p>
          {buyer.company && (
            <p className="truncate text-[13px] text-soil-600">{buyer.company}</p>
          )}
          <p className="num text-[13px] text-soil-600">{displayPhone(buyer.phone)}</p>
        </div>
      </div>

      {address ? (
        <p className="mt-3 text-[13px] leading-relaxed text-soil-600">📍 {address}</p>
      ) : (
        <p className="mt-3 rounded-lg bg-amber-50 px-3 py-2 text-[12px] leading-relaxed text-amber-800">
          This buyer has not added a delivery address yet. Call them to arrange the drop-off point.
        </p>
      )}

      {/* Contact — these open the phone's own dialer and messaging app */}
      <div className="mt-3 grid grid-cols-2 gap-2">
        <a href={`tel:${buyer.phone}`} className="btn-primary py-2 text-[13px]">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z" />
          </svg>
          Call buyer
        </a>
        <a href={`sms:${buyer.phone}`} className="btn-ghost py-2 text-[13px]">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.9-.9L3 21l2-4.1A8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z" />
          </svg>
          Text buyer
        </a>
      </div>

      {mapQuery && (
        <>
          <button
            onClick={() => setMapOpen((v) => !v)}
            className="mt-2 w-full rounded-lg border border-soil-200 px-3 py-2 text-[13px] font-semibold text-soil-800 hover:bg-soil-100"
            aria-expanded={mapOpen}
          >
            {mapOpen ? 'Hide map' : 'Show location on map'}
          </button>

          {mapOpen && (
            <div className="mt-2 space-y-2">
              <iframe
                title={`Map showing ${address}`}
                className="h-56 w-full rounded-lg border border-soil-200"
                loading="lazy"
                referrerPolicy="no-referrer-when-downgrade"
                src={`https://maps.google.com/maps?q=${mapQuery}&z=15&output=embed`}
              />
              <a
                href={`https://www.google.com/maps/search/?api=1&query=${mapQuery}`}
                target="_blank"
                rel="noreferrer"
                className="block text-center text-[13px] font-semibold text-brand-700 hover:underline"
              >
                Open in Google Maps for directions
              </a>
            </div>
          )}
        </>
      )}
    </div>
  )
}
