/**
 * How ready a planting is to harvest, shown on the calendar's progress bars.
 *
 *   red     just planted, it cannot be harvested yet
 *   yellow  almost ready to harvest
 *   green   ready to harvest
 *
 * The stage follows the share of the growing period that has passed, from the
 * planting date to the expected harvest date.
 */

export type GrowthStage = 'early' | 'almost' | 'ready'

/** From this share of the growing period, a planting counts as almost ready. */
export const ALMOST_READY_FROM = 70

export interface StageStyle {
  /** Short word shown beside the percentage. */
  label: string
  /** Wording for the legend. */
  legend: string
  /** Fill of the progress bar. */
  bar: string
  /** Text colour that stays readable when it sits on top of that fill. */
  onFill: string
  /** Colour of the harvest button for this stage. */
  button: string
}

export const STAGE_STYLE: Record<GrowthStage, StageStyle> = {
  early: {
    label: 'Not ready',
    legend: 'Red: just planted, cannot be harvested yet',
    bar: 'bg-red-600',
    onFill: 'text-white',
    button: 'bg-red-600 text-white hover:bg-red-700',
  },
  almost: {
    label: 'Almost ready',
    legend: `Yellow: almost ready to harvest (from ${ALMOST_READY_FROM}%)`,
    bar: 'bg-amber-400',
    onFill: 'text-soil-900',
    button: 'bg-amber-400 text-soil-900 hover:bg-amber-500',
  },
  ready: {
    label: 'Ready to harvest',
    legend: 'Green: ready to harvest',
    bar: 'bg-green-600',
    onFill: 'text-white',
    button: 'bg-green-600 text-white hover:bg-green-700',
  },
}

export function growthStage(pct: number): GrowthStage {
  if (pct >= 100) return 'ready'
  if (pct >= ALMOST_READY_FROM) return 'almost'
  return 'early'
}
