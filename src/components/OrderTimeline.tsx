import { ORDER_STAGES, STAGE_LABEL, relativeDate, simplifyStage, stageIndex } from '@/lib/format'
import type { OrderEvent, OrderStage } from '@/lib/types'

export function OrderTimeline({
  stage,
  events = [],
  cancelReason,
}: {
  stage: OrderStage
  events?: OrderEvent[]
  cancelReason?: string | null
}) {
  if (stage === 'cancelled') {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3">
        <p className="text-[14px] font-bold text-red-800">Order cancelled</p>
        {cancelReason && (
          <p className="mt-1 text-[13px] leading-relaxed text-red-700">{cancelReason}</p>
        )}
        <p className="mt-1.5 text-[12px] text-red-600">
          The sacks were returned to the farm's stock.
        </p>
      </div>
    )
  }

  const current = stageIndex(stage)
  const waiting = stage === 'placed'
  const timeFor = (s: OrderStage) =>
    events.find((e) => e.stage === s || simplifyStage(e.stage) === s)?.created_at

  return (
    <>
      {waiting && (
        <p className="mb-3 rounded-lg bg-amber-50 px-3.5 py-2.5 text-[13px] font-medium text-amber-900">
          Waiting for the farm to confirm your order.
        </p>
      )}
      <ol className="relative space-y-0">
      {ORDER_STAGES.map((step, i) => {
        const done = i < current
        const active = i === current
        const at = timeFor(step.stage)

        return (
          <li key={step.stage} className="relative flex gap-3 pb-4 last:pb-0">
            {i < ORDER_STAGES.length - 1 && (
              <span
                aria-hidden
                className={`absolute left-[11px] top-6 h-full w-0.5 ${
                  done ? 'bg-brand-600' : 'bg-soil-200'
                }`}
              />
            )}

            <span
              aria-hidden
              className={`relative z-10 mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2 ${
                done
                  ? 'border-brand-600 bg-brand-600 text-white'
                  : active
                    ? 'border-brand-600 bg-white text-brand-700'
                    : 'border-soil-200 bg-white text-soil-400'
              }`}
            >
              {done ? (
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
              ) : (
                <span className={`h-2 w-2 rounded-full ${active ? 'bg-brand-600' : 'bg-soil-200'}`} />
              )}
            </span>

            <span className="min-w-0 flex-1 pb-1">
              <span
                className={`block text-[14px] leading-snug ${
                  active ? 'font-bold text-brand-700' : done ? 'font-semibold' : 'text-soil-400'
                }`}
              >
                {step.label}
              </span>
              <span className={`block text-[12px] ${active ? 'text-soil-600' : 'text-soil-400'}`}>
                {at ? relativeDate(at) : step.hint}
              </span>
            </span>
          </li>
        )
      })}
      </ol>
    </>
  )
}

export function StageBadge({ stage }: { stage: OrderStage }) {
  const tone =
    stage === 'cancelled'
      ? 'bg-red-100 text-red-700'
      : stage === 'completed' || stage === 'delivered'
        ? 'bg-green-100 text-green-700'
        : stage === 'shipped' || stage === 'ready'
          ? 'bg-blue-100 text-blue-700'
          : 'bg-amber-100 text-amber-700'

  return <span className={`chip ${tone}`}>{STAGE_LABEL[stage]}</span>
}
