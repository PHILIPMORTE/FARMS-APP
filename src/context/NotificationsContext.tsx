import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import type { Notification } from '@/lib/types'

interface NotificationsState {
  items: Notification[]
  unread: number
  loading: boolean
  error: string | null
  markAllRead(): Promise<void>
  markRead(id: string): Promise<void>
  reload(): Promise<void>
}

const Ctx = createContext<NotificationsState | null>(null)

export function NotificationsProvider({ children }: { children: ReactNode }) {
  const { profile } = useAuth()
  const [items, setItems] = useState<Notification[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const profileId = profile?.id ?? null

  const load = useCallback(async () => {
    if (!profileId) {
      setItems([])
      setError(null)
      setLoading(false)
      return
    }
    try {
      const { data, error: qError } = await supabase
        .from('notifications')
        .select('*')
        .eq('user_id', profileId)
        .order('created_at', { ascending: false })
        .limit(100)

      if (qError) {
        setError(qError.message)
        setItems([])
      } else {
        setError(null)
        setItems((data as Notification[]) ?? [])
      }
    } catch (err) {
      setError((err as Error).message)
      setItems([])
    } finally {
      setLoading(false)
    }
  }, [profileId])

  useEffect(() => {
    load()
    if (!profileId) return

    const channel = supabase
      .channel(`notifications-${profileId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${profileId}` },
        () => load(),
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [profileId, load])

  const unread = items.filter((n) => n?.unread).length

  const markAllRead = useCallback(async () => {
    if (!profileId || unread === 0) return
    setItems((prev) => prev.map((n) => ({ ...n, unread: false })))
    const { error: uError } = await supabase
      .from('notifications')
      .update({ unread: false })
      .eq('user_id', profileId)
      .eq('unread', true)
    if (uError) load()
  }, [profileId, unread, load])

  const markRead = useCallback(async (id: string) => {
    setItems((prev) => prev.map((n) => (n.id === id ? { ...n, unread: false } : n)))
    await supabase.from('notifications').update({ unread: false }).eq('id', id)
  }, [])

  const value = useMemo<NotificationsState>(
    () => ({ items, unread, loading, error, markAllRead, markRead, reload: load }),
    [items, unread, loading, error, markAllRead, markRead, load],
  )

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useNotifications(): NotificationsState {
  const ctx = useContext(Ctx)

  if (!ctx) {
    return {
      items: [],
      unread: 0,
      loading: false,
      error: null,
      markAllRead: async () => {},
      markRead: async () => {},
      reload: async () => {},
    }
  }
  return ctx
}
