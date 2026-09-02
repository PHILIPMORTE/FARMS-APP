import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { Dialog, Spinner, TextArea } from '@/components/ui'
import { friendlyError } from '@/lib/validation'

export interface RatingSummary {
  average: number
  total: number
  five: number
  four: number
  three: number
  two: number
  one: number
}

export function Stars({ value, size = 16 }: { value: number; size?: number }) {
  return (
    <span className="inline-flex items-center gap-0.5" aria-label={`${value} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((i) => {
        const fill = Math.min(Math.max(value - i + 1, 0), 1)
        return (
          <span key={i} className="relative inline-block" style={{ width: size, height: size }}>
            <Star size={size} className="absolute inset-0 text-soil-200" />
            <span
              className="absolute inset-0 overflow-hidden"
              style={{ width: `${fill * 100}%` }}
              aria-hidden
            >
              <Star size={size} className="text-amber-400" />
            </span>
          </span>
        )
      })}
    </span>
  )
}

function Star({ size, className }: { size: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" className={className}>
      <path d="M12 2l2.9 6.1 6.6.9-4.8 4.6 1.2 6.6L12 17.1 6.1 20.2l1.2-6.6L2.5 9l6.6-.9z" />
    </svg>
  )
}

export function RatingBadge({ profileId, compact }: { profileId: string; compact?: boolean }) {
  const [data, setData] = useState<RatingSummary | null>(null)

  useEffect(() => {
    supabase
      .rpc('rating_summary', { p_profile_id: profileId })
      .then(({ data: d }) => setData((d as RatingSummary) ?? null))
  }, [profileId])

  if (!data || data.total === 0) {
    return compact ? null : (
      <span className="text-[12px] text-soil-400">No ratings yet</span>
    )
  }

  if (compact) {
    return (
      <span className="inline-flex items-center gap-1 text-[12px]">
        <Star size={12} className="text-amber-400" />
        <span className="num font-bold">{Number(data.average).toFixed(1)}</span>
        <span className="text-soil-400">({data.total})</span>
      </span>
    )
  }

  return (
    <div className="rounded-xl border border-soil-200 p-4">
      <div className="flex items-center gap-4">
        <div className="text-center">
          <p className="num text-[30px] font-bold leading-none text-soil-900">
            {Number(data.average).toFixed(1)}
          </p>
          <p className="text-[11px] text-soil-400">out of 5.0</p>
        </div>
        <div className="min-w-0 flex-1">
          <Stars value={Number(data.average)} size={18} />
          <p className="num mt-1 text-[12px] text-soil-600">
            {data.total} rating{data.total === 1 ? '' : 's'}
          </p>
        </div>
      </div>

      <dl className="mt-3 space-y-1">
        {([5, 4, 3, 2, 1] as const).map((n) => {
          const key = (['one', 'two', 'three', 'four', 'five'] as const)[n - 1]
          const count = data[key]
          const pct = data.total ? (count / data.total) * 100 : 0
          return (
            <div key={n} className="flex items-center gap-2">
              <dt className="num w-3 text-[11px] text-soil-500">{n}</dt>
              <Star size={11} className="text-amber-400" />
              <dd className="h-1.5 flex-1 overflow-hidden rounded-full bg-soil-100">
                <span className="block h-full bg-amber-400" style={{ width: `${pct}%` }} />
              </dd>
              <span className="num w-6 text-right text-[11px] text-soil-500">{count}</span>
            </div>
          )
        })}
      </dl>
    </div>
  )
}

export function RateDialog({
  open,
  onClose,
  title,
  description,
  onSubmit,
}: {
  open: boolean
  onClose(): void
  title: string
  description?: string
  onSubmit(stars: number, comment: string): Promise<{ error: unknown } | void>
}) {
  const [stars, setStars] = useState(0)
  const [hover, setHover] = useState(0)
  const [comment, setComment] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (open) {
      setStars(0)
      setHover(0)
      setComment('')
    }
  }, [open])

  const LABELS = ['', 'Poor', 'Fair', 'Good', 'Very good', 'Excellent']

  async function save() {
    if (stars === 0) {
      toast.error('Choose a star rating first.')
      return
    }
    setBusy(true)
    const res = await onSubmit(stars, comment.trim())
    setBusy(false)
    if (res && (res as any).error) {
      toast.error(friendlyError((res as any).error))
      return
    }
    toast.success('Thank you for rating')
    onClose()
  }

  if (!open) return null

  return (
    <Dialog
      open
      onClose={onClose}
      title={title}
      description={description}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Not now
          </button>
          <button className="btn-primary" onClick={save} disabled={busy}>
            {busy ? 'Sending…' : 'Submit rating'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="text-center">
          <div
            className="inline-flex gap-1.5"
            onMouseLeave={() => setHover(0)}
            role="radiogroup"
            aria-label="Star rating"
          >
            {[1, 2, 3, 4, 5].map((n) => (
              <button
                key={n}
                type="button"
                role="radio"
                aria-checked={stars === n}
                aria-label={`${n} star${n === 1 ? '' : 's'}`}
                onMouseEnter={() => setHover(n)}
                onClick={() => setStars(n)}
                className="transition hover:scale-110"
              >
                <Star
                  size={38}
                  className={
                    (hover || stars) >= n ? 'text-amber-400' : 'text-soil-200'
                  }
                />
              </button>
            ))}
          </div>
          <p className="mt-1.5 h-5 text-[14px] font-semibold text-soil-700">
            {LABELS[hover || stars]}
          </p>
        </div>

        <TextArea
          label="Comment (optional)"
          max={300}
          placeholder="What was the transaction like?"
          value={comment}
          onChange={(e) => setComment(e.target.value)}
        />

        <p className="rounded-lg bg-soil-50 px-3.5 py-2.5 text-[12px] leading-relaxed text-soil-600">
          Rate honestly based on your real dealing. Unfair or abusive ratings can be removed by an
          administrator, and repeated cases restrict your account from rating.
        </p>
      </div>
    </Dialog>
  )
}

export function RatingPanel({ profileId }: { profileId: string }) {
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const t = setTimeout(() => setLoading(false), 0)
    return () => clearTimeout(t)
  }, [])

  if (loading) return <Spinner label="Loading ratings" />
  return <RatingBadge profileId={profileId} />
}
