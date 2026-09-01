import { useEffect, useId, useRef, useState } from 'react'
import type { ReactNode, InputHTMLAttributes, TextareaHTMLAttributes, SelectHTMLAttributes } from 'react'

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
      {label && (
        <label className="label" htmlFor={id}>
          {label}
        </label>
      )}
      <div className="relative">
        <select
          id={id}
          className={`field select-arrow appearance-none bg-white pr-10 ${error ? 'field-error' : ''}`}
          {...props}
        >
          {options.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
        <svg
          aria-hidden
          className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-soil-400"
          width="16" height="16" viewBox="0 0 24 24" fill="none"
          stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  )
}

interface PhoneProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {
  label?: string
  error?: string | null
}

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

interface SackProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'step'> {
  label: string
  error?: string | null
  hint?: string
}

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
    if (!open) {
      document.body.style.overflow = ''
      return
    }
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', onKey)
    panel.current?.querySelector<HTMLElement>('input,select,textarea,button')?.focus()
    return () => {
      document.removeEventListener('keydown', onKey)
    }
  }, [open, onClose])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 w-screen">
      <div
        className="absolute inset-0 bg-soil-900/40 backdrop-blur-[2px]"
        onClick={onClose}
        aria-hidden
      />

      <div className="relative flex h-full items-end justify-center p-0 sm:items-center sm:p-4">
        <div
          ref={panel}
          role="dialog"
          aria-modal="true"
          aria-label={title}
          className="dialog-panel relative flex w-full max-w-md animate-scale-in flex-col
                     rounded-t-2xl bg-white shadow-2xl sm:rounded-xl"
        >
          <div className="flex shrink-0 items-start justify-between gap-4 rounded-t-2xl border-b border-soil-200 bg-white px-5 py-3.5 sm:rounded-t-xl">
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

          <div
            className="min-h-0 flex-1 touch-pan-y overflow-y-auto overscroll-contain px-5 py-4"
            style={{ WebkitOverflowScrolling: 'touch' }}
          >
            {children}
          </div>

        {footer && (
          <div className="flex shrink-0 gap-2 border-t border-soil-200 bg-white px-5 py-3.5 [&>*]:flex-1">
            {footer}
          </div>
        )}
        </div>
      </div>
    </div>
  )
}

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
  return <span className={`chip animate-pop ${TONES[tone]}`}>{children}</span>
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
    <div className="card px-4 py-3.5 transition hover:-translate-y-0.5 hover:shadow-md">
      <p className="text-[12px] font-medium text-soil-600">{label}</p>
      <p key={value} className={`num mt-1 animate-count-up text-[21px] font-bold leading-tight ${colour}`}>
        {value}
      </p>
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
    <div className="card flex animate-fade-up flex-col items-center px-6 py-12 text-center">
      <h3 className="text-[15px] font-bold">{title}</h3>
      <p className="mt-1 max-w-sm text-sm text-soil-600">{body}</p>
      {action && <div className="mt-4">{action}</div>}
    </div>
  )
}

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return (
    <div className="flex animate-fade-up flex-col items-center justify-center gap-3 py-16">
      <span className="relative flex h-9 w-9">
        <span className="absolute inset-0 animate-ping rounded-full bg-brand-600/25" />
        <span className="relative h-9 w-9 animate-spin rounded-full border-[3px] border-soil-200 border-t-brand-600" />
      </span>
      <span className="text-sm text-soil-400">{label}</span>
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

export function ViewToggle({
  view,
  onChange,
}: {
  view: 'grid' | 'table'
  onChange(v: 'grid' | 'table'): void
}) {
  return (
    <div className="inline-flex shrink-0 rounded-lg bg-soil-100 p-0.5">
      {(['grid', 'table'] as const).map((v) => (
        <button
          key={v}
          onClick={() => onChange(v)}
          aria-pressed={view === v}
          aria-label={v === 'grid' ? 'Card view' : 'Table view'}
          className={`rounded-md px-2.5 py-1.5 transition ${
            view === v ? 'bg-white text-soil-900 shadow-sm' : 'text-soil-400 hover:text-soil-600'
          }`}
        >
          {v === 'grid' ? (
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <rect x="3" y="3" width="7" height="7" rx="1" />
              <rect x="14" y="3" width="7" height="7" rx="1" />
              <rect x="3" y="14" width="7" height="7" rx="1" />
              <rect x="14" y="14" width="7" height="7" rx="1" />
            </svg>
          ) : (
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <path d="M3 6h18M3 12h18M3 18h18" />
            </svg>
          )}
        </button>
      ))}
    </div>
  )
}

export function DataTable({
  headers,
  children,
  minWidth = '42rem',
}: {
  headers: { label: string; align?: 'left' | 'right' | 'center' }[]
  children: ReactNode
  minWidth?: string
}) {
  return (
    <div className="card overflow-x-auto">
      <table className="w-full text-left text-[13px]" style={{ minWidth }}>
        <thead className="border-b border-soil-200 bg-soil-50 text-[11px] uppercase tracking-wide text-soil-600">
          <tr>
            {headers.map((h, i) => (
              <th
                key={i}
                className={`px-4 py-2.5 font-semibold ${
                  h.align === 'right' ? 'text-right' : h.align === 'center' ? 'text-center' : ''
                }`}
              >
                {h.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-soil-200">{children}</tbody>
      </table>
    </div>
  )
}
