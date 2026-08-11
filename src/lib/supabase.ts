import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string

if (!url || !anonKey) {
  throw new Error(
    'Supabase is not configured. Copy .env.example to .env and add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.',
  )
}

export const supabase = createClient(url, anonKey, {
  auth: {
    // Sessions live in the Supabase auth store only. No application data is
    // ever written to localStorage — everything reads from and writes to Postgres.
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})
