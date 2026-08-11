import { useNavigate } from 'react-router-dom'
import { useNotifications } from '@/context/NotificationsContext'
import { Empty, Spinner } from '@/components/ui'
import { relativeDate } from '@/lib/format'
import type { NotifType } from '@/lib/types'

const ICON: Record<string, string> = {
  harvest: '🌾',
  sale: '💰',
  purchase: '📦',
  job_post: '📋',
  application: '✉️',
  hired: '🎉',
  rejected: '📭',
  general: '🔔',
}

const TINT: Record<string, string> = {
  harvest: 'bg-green-100',
  sale: 'bg-green-100',
  purchase: 'bg-blue-100',
  job_post: 'bg-amber-100',
  application: 'bg-amber-100',
  hired: 'bg-green-100',
  rejected: 'bg-soil-100',
  general: 'bg-soil-100',
}

export default function NotificationsPage() {
  const { items, unread, loading, error, markAllRead, markRead, reload } = useNotifications()
  const navigate = useNavigate()

  if (loading) return <Spinner label="Loading notifications" />

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-bold">Notifications</h1>
          <p className="mt-0.5 text-[13px] text-soil-600">
            {unread > 0 ? `${unread} unread` : 'You are all caught up'}
          </p>
        </div>
        {unread > 0 && (
          <button className="btn-ghost" onClick={markAllRead}>
            Mark all as read
          </button>
        )}
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-[13px] text-red-700"
        >
          <p className="font-semibold">Notifications could not be loaded.</p>
          <p className="mt-1 break-words">{error}</p>
          <button onClick={reload} className="mt-2 font-semibold underline">
            Try again
          </button>
        </div>
      )}

      {!error && items.length === 0 ? (
        <Empty
          title="Nothing yet"
          body="Sales, job applications and hiring decisions all show up here."
        />
      ) : (
        <ul className="card divide-y divide-soil-200">
          {items.map((n) => {
            const type = (n?.type ?? 'general') as NotifType
            return (
              <li key={n.id}>
                <button
                  onClick={() => {
                    markRead(n.id)
                    if (n.link) navigate(n.link)
                  }}
                  className={`flex w-full items-start gap-3 px-4 py-3.5 text-left transition hover:bg-soil-50 ${
                    n.unread ? 'bg-brand-50/60' : ''
                  }`}
                >
                  <span
                    className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-[17px] ${
                      TINT[type] ?? 'bg-soil-100'
                    }`}
                    aria-hidden
                  >
                    {ICON[type] ?? '🔔'}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span
                      className={`block text-[14px] leading-snug ${n.unread ? 'font-semibold' : ''}`}
                    >
                      {n.message ?? ''}
                    </span>
                    <span className="mt-0.5 block text-[12px] text-soil-400">
                      {n.created_at ? relativeDate(n.created_at) : ''}
                    </span>
                  </span>
                  {n.unread && (
                    <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-brand-600" />
                  )}
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
