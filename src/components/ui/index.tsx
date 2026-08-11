import { useEffect, useId, useRef, useState } from 'react'
import type { ReactNode, InputHTMLAttributes, TextareaHTMLAttributes, SelectHTMLAttributes } from 'react'

/* ------------------------------------------------------------------ text --- */

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  error?: string | null
  hint?: string
}

export function Field({ label, error, hint, className = '', ...props }: FieldProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className={`field ${error ? 'field-error' : ''}`}
        aria-invalid={!!error}
        aria-describedby={error ? `${id}-err` : undefined}
        {...props}
      />
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && (
        <p className="err" id={`${id}-err`}>
          {error}
        </p>
      )}
    </div>
  )
}

export function PasswordField({ label, error, hint, className = '', ...props }: FieldProps) {
  const [shown, setShown] = useState(false)
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type={shown ? 'text' : 'password'}
          className={`field pr-16 ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
        <button
          type="button"
          onClick={() => setShown((s) => !s)}
          className="absolute right-1.5 top-1/2 -translate-y-1/2 rounded-lg px-2.5 py-1.5
                     text-xs font-bold uppercase tracking-wide text-soil-600 hover:bg-soil-100"
          aria-pressed={shown}
        >
          {shown ? 'Hide' : 'Show'}
        </button>
      </div>
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface AreaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  label: string
  error?: string | null
  max?: number
}

export function TextArea({ label, error, max, className = '', value, ...props }: AreaProps) {
  const id = useId()
  const len = String(value ?? '').length
  return (
    <div className={className}>
      <div className="flex items-baseline justify-between">
        <label className="label" htmlFor={id}>
          {label}
        </label>
        {max && (
          <span className={`num text-[12px] ${len > max ? 'text-red-600' : 'text-soil-400'}`}>
            {len}/{max}
          </span>
        )}
      </div>
      <textarea
        id={id}
        rows={4}
        value={value}
        maxLength={max}
        className={`field resize-y ${error ? 'field-error' : ''}`}
        {...props}
      />
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label: string
  error?: string | null
  options: { value: string; label: string }[]
}

export function Select({ label, error, options, className = '', ...props }: SelectProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <select id={id} className={`field appearance-none bg-white ${error ? 'field-error' : ''}`} {...props}>
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      {error && <p className="err">{error}</p>}
    </div>
  )
}


/* -------------------------------------------------------------- phone --- */

interface PhoneProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {
  label?: string
  error?: string | null
}

/**
 * Philippine mobile entry with a fixed +63 prefix, so the person types the
 * 10 digits they actually know. normalisePhone() accepts what comes out of
 * this either way — 9171234567 or 09171234567.
 */
export function PhoneField({ label = 'Phone Number', error, className = '', ...props }: PhoneProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="flex gap-2">
        <span className="flex w-16 shrink-0 items-center justify-center rounded-lg bg-soil-100 text-[15px] font-semibold text-soil-800">
          +63
        </span>
        <input
          id={id}
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          placeholder="917 123 4567"
          className={`field-soft ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
      </div>
      {error ? (
        <p className="err">{error}</p>
      ) : (
        <p className="mt-1.5 text-[12px] text-soil-400">
          Enter your 10-digit mobile number (e.g. 917 123 4567)
        </p>
      )}
    </div>
  )
}

/** Password field styled for the auth card — grey fill, show/hide toggle. */
export function SoftPasswordField({ label, error, className = '', ...props }: FieldProps) {
  const [shown, setShown] = useState(false)
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type={shown ? 'text' : 'password'}
          className={`field-soft pr-16 ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
        <button
          type="button"
          onClick={() => setShown((v) => !v)}
          aria-pressed={shown}
          className="absolute right-2 top-1/2 -translate-y-1/2 rounded-md px-2 py-1.5
                     text-[11px] font-bold uppercase tracking-wide text-soil-600 hover:bg-soil-200"
        >
          {shown ? 'Hide' : 'Show'}
        </button>
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

/** Text field styled for the auth card. */
export function SoftField({ label, error, className = '', ...props }: FieldProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className={`field-soft ${error ? 'field-error' : ''}`}
        aria-invalid={!!error}
        {...props}
      />
      {error && <p className="err">{error}</p>}
    </div>
  )
}

/* ---------------------------------------------------------------- sacks --- */

interface SackProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'step'> {
  label: string
  error?: string | null
  hint?: string
}

/**
 * The only input used for sack counts anywhere in the app. Locked to whole
 * numbers three ways: step="1", inputMode numeric, and a keypress guard that
 * refuses '.', ',' and 'e' outright so a decimal never even appears on screen.
 */
export function SackInput({ label, error, hint, className = '', ...props }: SackProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <input
          id={id}
          type="number"
          step="1"
          min={props.min ?? 1}
          inputMode="numeric"
          pattern="[0-9]*"
          onKeyDown={(e) => {
            if (['.', ',', 'e', 'E', '+', '-'].includes(e.key)) e.preventDefault()
            props.onKeyDown?.(e)
          }}
          className={`field num pr-16 ${error ? 'field-error' : ''}`}
          aria-invalid={!!error}
          {...props}
        />
        <span className="absolute right-3.5 top-1/2 -translate-y-1/2 text-sm font-semibold text-soil-400">
          sacks
        </span>
      </div>
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && <p className="err">{error}</p>}
    </div>
  )
}

export function PesoInput({ label, error, hint, className = '', ...props }: FieldProps) {
  const id = useId()
  return (
    <div className={className}>
      <label className="label" htmlFor={id}>
        {label}
      </label>
      <div className="relative">
        <span className="absolute left-3.5 top-1/2 -translate-y-1/2 text-[15px] font-semibold text-soil-400">
          ₱
        </span>
        <input
          id={id}
          type="number"
          min="0"
          step="0.01"
          inputMode="decimal"
          className={`field num pl-8 ${error ? 'field-error' : ''}`}
          {...props}
        />
      </div>
      {hint && !error && <p className="mt-1.5 text-[13px] text-soil-400">{hint}</p>}
      {error && <p className="err">{error}</p>}
    </div>
  )
}

/* ---------------------------------------------------------------- dialog --- */

export function Dialog({
  open,
  onClose,
  title,
  description,
  children,
  footer,
}: {
  open: boolean
  onClose(): void
  title: string
  description?: string
  children: ReactNode
  footer?: ReactNode
}) {
  const panel = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', onKey)
    document.body.style.overflow = 'hidden'
    panel.current?.querySelector<HTMLElement>('input,select,textarea,button')?.focus()
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = ''
    }
  }, [open, onClose])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center">
      <div
        className="absolute inset-0 bg-soil-900/40 backdrop-blur-[2px]"
        onClick={onClose}
        aria-hidden
      />
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="relative w-full max-w-md animate-scale-in rounded-t-xl bg-white shadow-2xl
                   sm:rounded-xl max-h-[92vh] flex flex-col"
      >
        <div className="flex items-start justify-between gap-4 border-b border-soil-200 px-5 py-3.5">
          <div>
            <h2 className="text-[16px] font-bold">{title}</h2>
            {description && <p className="mt-0.5 text-[12px] text-soil-600">{description}</p>}
          </div>
          <button
            onClick={onClose}
            aria-label="Close"
            className="-mr-1 rounded-lg p-1.5 text-soil-400 hover:bg-soil-100 hover:text-soil-800"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <path d="M18 6 6 18M6 6l12 12" strokeLinecap="round" />
            </svg>
          </button>
        </div>
        <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && (
          <div className="flex gap-2 border-t border-soil-200 px-5 py-3.5 [&>*]:flex-1">{footer}</div>
        )}
      </div>
    </div>
  )
}

/* ---------------------------------------------------------------- pieces --- */

const TONES = {
  green: 'bg-green-100 text-green-700',
  amber: 'bg-amber-100 text-amber-700',
  blue: 'bg-blue-100 text-blue-700',
  red: 'bg-red-100 text-red-600',
  grey: 'bg-soil-100 text-soil-600',
  brand: 'bg-brand-50 text-brand-700',
} as const

export function Badge({
  children,
  tone = 'grey',
}: {
  children: ReactNode
  tone?: keyof typeof TONES
}) {
  return <span className={`chip ${TONES[tone]}`}>{children}</span>
}

export function Stat({
  label,
  value,
  sub,
  accent,
}: {
  label: string
  value: string
  sub?: string
  accent?: 'brand' | 'green' | 'red'
}) {
  const colour =
    accent === 'green' ? 'text-brand-600' : accent === 'red' ? 'text-red-500' : 'text-soil-900'
  return (
    <div className="card px-4 py-3.5">
      <p className="text-[12px] font-medium text-soil-600">{label}</p>
      <p className={`num mt-1 text-[21px] font-bold leading-tight ${colour}`}>{value}</p>
      {sub && <p className="mt-0.5 text-[11px] text-soil-400">{sub}</p>}
    </div>
  )
}

export function Empty({
  title,
  body,
  action,
}: {
  title: string
  body: string
  action?: ReactNode
}) {
  return (
    <div className="card flex flex-col items-center px-6 py-12 text-center">
      <h3 className="text-[15px] font-bold">{title}</h3>
      <p className="mt-1 max-w-sm text-sm text-soil-600">{body}</p>
      {action && <div className="mt-4">{action}</div>}
    </div>
  )
}

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return (
    <div className="flex items-center justify-center gap-2.5 py-16 text-sm text-soil-400">
      <span className="h-4 w-4 animate-spin rounded-full border-2 border-soil-200 border-t-brand-600" />
      {label}
    </div>
  )
}

export function SectionHeading({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center justify-between gap-3">
      <h2 className="text-[15px] font-bold text-soil-900">{children}</h2>
      {action}
    </div>
  )
}

export function Search({
  value,
  onChange,
  placeholder,
}: {
  value: string
  onChange(v: string): void
  placeholder: string
}) {
  return (
    <div className="relative">
      <svg
        className="absolute left-3.5 top-1/2 -translate-y-1/2 text-soil-400"
        width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2"
      >
        <circle cx="11" cy="11" r="7" />
        <path d="m20 20-3.5-3.5" strokeLinecap="round" />
      </svg>
      <input
        type="search"
        className="field pl-10"
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        aria-label={placeholder}
      />
    </div>
  )
}
