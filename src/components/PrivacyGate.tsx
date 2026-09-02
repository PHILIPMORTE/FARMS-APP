import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { Spinner } from '@/components/ui'
import { friendlyError } from '@/lib/validation'
import type { ReactNode } from 'react'

export function PrivacyGate({ children }: { children: ReactNode }) {
  const { profile, signOut } = useAuth()
  const [accepted, setAccepted] = useState<boolean | null>(null)
  const [checked, setChecked] = useState(false)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_privacy_accepted')
    setAccepted(Boolean(data))
  }, [profile?.id])

  useEffect(() => {
    load()
  }, [load])

  if (accepted === null) return <Spinner label="Checking your account" />
  if (accepted) return <>{children}</>

  async function accept() {
    if (!checked) {
      toast.error('Please tick the box to continue.')
      return
    }
    setBusy(true)
    const { error } = await supabase.rpc('accept_privacy_notice')
    setBusy(false)
    if (error) {
      toast.error(friendlyError(error))
      return
    }
    setAccepted(true)
  }

  return (
    <div className="auth-wash flex min-h-screen items-center justify-center px-5 py-10">
      <div className="relative z-10 w-full max-w-lg">
        <div className="auth-card animate-fade-up rounded-2xl p-6 sm:p-8">
          <div className="text-center">
            <span className="inline-flex h-12 w-12 items-center justify-center rounded-xl bg-white text-brand-700 shadow-sm">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <path d="M12 3l8 3.5v5c0 5-3.4 9.3-8 10.5C7.4 20.8 4 16.5 4 11.5v-5z" />
                <path d="M9 12l2.2 2.2L15.5 10" />
              </svg>
            </span>
            <h1 className="mt-4 text-[22px] font-bold">Data Privacy Notice</h1>
            <p className="mt-1 text-[13px] text-soil-600">
              Please read this before using FARMS. You cannot continue without agreeing.
            </p>
          </div>

          <div className="mt-5 max-h-[42vh] space-y-3 overflow-y-auto rounded-xl bg-white/70 p-4 text-[14px] leading-relaxed text-soil-700">
            <p className="font-semibold text-soil-900">What we collect</p>
            <p>
              Your name, mobile number, and a photo of a valid government ID together with a selfie
              holding that ID. Farm owners also give their farm name, address, and map location.
              Buyers give a delivery address. Farmers record the hours they work.
            </p>

            <p className="font-semibold text-soil-900">Why we collect it</p>
            <p>
              An administrator checks your ID and selfie to confirm you are a real person before
              your account is activated. This protects everyone from fake accounts. The rest is used
              to run orders, jobs, and wages between you and the people you deal with.
            </p>

            <p className="font-semibold text-soil-900">Who can see it</p>
            <p>
              Your ID photo and selfie are stored privately. Only you and the system administrator
              can open them. Other users see only your name, your rating, and your mobile number
              when you have an active order or job together. Farm locations are shown to buyers so
              they can find the farm.
            </p>

            <p className="font-semibold text-soil-900">How long we keep it</p>
            <p>
              Records of orders, work logs, and wages are kept as the shared account of what
              happened between both parties, so either side can rely on them later.
            </p>

            <p className="font-semibold text-soil-900">Your rights</p>
            <p>
              You may ask the administrator to correct your details or remove your account. This
              system is a student capstone project for Barangay Pagatban, Bayawan City, and personal
              information is handled in line with the Data Privacy Act of 2012 (RA 10173).
            </p>
          </div>

          <label className="mt-4 flex cursor-pointer items-start gap-2.5 rounded-xl border border-soil-200 bg-white p-3.5">
            <input
              type="checkbox"
              checked={checked}
              onChange={(e) => setChecked(e.target.checked)}
              className="mt-0.5 h-4 w-4 shrink-0 rounded border-soil-300 text-brand-600 focus:ring-2 focus:ring-brand-600/30"
            />
            <span className="text-[14px] font-medium leading-relaxed text-soil-800">
              I have read and agree to the Data Privacy Notice.
            </span>
          </label>

          <button className="btn-primary mt-4 w-full py-3" onClick={accept} disabled={!checked || busy}>
            {busy ? 'Saving…' : 'Agree and continue'}
          </button>

          <button
            className="mt-2 w-full py-2 text-[13px] font-medium text-soil-500 hover:text-soil-800"
            onClick={async () => {
              await signOut()
            }}
          >
            Disagree and sign out
          </button>
        </div>
      </div>
    </div>
  )
}
