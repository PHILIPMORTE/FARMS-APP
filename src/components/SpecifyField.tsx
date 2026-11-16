import { Field } from '@/components/ui'
import { SPECIFY_MAX } from '@/lib/validation'

/** What a list shows for its "Other" choice. */
export const OTHER = 'Other'

/**
 * The box that opens under a list when "Other" is picked, so the person can say what it
 * is. What they type is what gets saved and shown, never the word "Other" on its own.
 */
export function SpecifyField({
  label = 'Please specify',
  placeholder,
  value,
  error,
  onChange,
  max = SPECIFY_MAX,
  className = '',
}: {
  label?: string
  placeholder?: string
  value: string
  error?: string | null
  onChange(value: string): void
  /** Most characters allowed. */
  max?: number
  className?: string
}) {
  return (
    <Field
      label={label}
      placeholder={placeholder}
      maxLength={max}
      autoComplete="off"
      className={className}
      value={value}
      error={error}
      data-specify
      onChange={(e) => onChange(e.target.value)}
    />
  )
}
