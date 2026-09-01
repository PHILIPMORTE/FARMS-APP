import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'
import { initials } from '@/lib/format'
import { displayPhone } from '@/lib/validation'
import type { ReactNode } from 'react'

export function AccountHeader({ subtitle, extra }: { subtitle?: string; extra?: ReactNode }) {
  const { profile, signOut, refresh } = useAuth()
  const navigate = useNavigate()
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<string | null>(null)

  useEffect(() => {
    setPreview(profile?.avatar_url ?? null)
  }, [profile?.avatar_url])

  async function out() {
    await signOut()
    toast.success('Signed out')
    navigate('/', { replace: true })
  }

  async function pickPhoto(file: File) {
    if (!profile) return
    if (file.size > 3 * 1024 * 1024) {
      toast.error('That photo is over 3 MB. Try a smaller one.')
      return
    }
    setBusy(true)
    const { data: sess } = await supabase.auth.getSession()
    const uid = sess.session?.user.id
    const ext = file.name.split('.').pop()?.toLowerCase() || 'jpg'
    const path = `${uid}/avatar-${Date.now()}.${ext}`

    const { error: upErr } = await supabase.storage
      .from('avatars')
      .upload(path, file, { upsert: true, contentType: file.type })

    if (upErr) {
      setBusy(false)
      toast.error(`Upload failed: ${upErr.message}`)
      return
    }

    const url = supabase.storage.from('avatars').getPublicUrl(path).data.publicUrl
    const { error } = await supabase.from('profiles').update({ avatar_url: url }).eq('id', profile.id)
    setBusy(false)

    if (error) {
      toast.error(error.message)
      return
    }
    setPreview(url)
    toast.success('Profile picture updated')
    await refresh()
  }

  async function removePhoto() {
    if (!profile) return
    setBusy(true)
    await supabase.from('profiles').update({ avatar_url: null }).eq('id', profile.id)
    setBusy(false)
    setPreview(null)
    toast.success('Profile picture removed')
    await refresh()
  }

  return (
    <div className="card animate-fade-up flex flex-wrap items-center gap-4 p-5">
      <div className="group relative shrink-0">
        <label
          htmlFor="avatar"
          className="block cursor-pointer overflow-hidden rounded-full transition hover:opacity-90"
        >
          {preview ? (
            <img
              src={preview}
              alt="Your profile picture"
              className="h-16 w-16 rounded-full object-cover ring-2 ring-brand-600/20"
            />
          ) : (
            <span className="flex h-16 w-16 items-center justify-center rounded-full bg-brand-600 text-lg font-bold text-white">
              {initials(profile?.name ?? '')}
            </span>
          )}
          <span className="absolute inset-0 flex items-center justify-center rounded-full bg-soil-900/55 text-[11px] font-bold text-white opacity-0 transition group-hover:opacity-100">
            {busy ? '…' : 'Change'}
          </span>
        </label>
        <input
          id="avatar"
          type="file"
          accept="image/jpeg,image/png,image/webp"
          className="sr-only"
          disabled={busy}
          onChange={(e) => {
            const f = e.target.files?.[0]
            if (f) pickPhoto(f)
          }}
        />
      </div>

      <div className="min-w-0 flex-1">
        <h2 className="truncate text-lg font-bold">{profile?.name || 'Your account'}</h2>
        {subtitle && <p className="truncate text-sm text-soil-600">{subtitle}</p>}
        <p className="num text-sm text-soil-400">{displayPhone(profile?.phone)}</p>
        {preview ? (
          <button
            onClick={removePhoto}
            disabled={busy}
            className="mt-1 text-[12px] font-semibold text-soil-400 hover:text-red-600"
          >
            Remove photo
          </button>
        ) : (
          <label htmlFor="avatar" className="mt-1 block cursor-pointer text-[12px] font-semibold text-brand-700 hover:underline">
            Add a profile picture (optional)
          </label>
        )}
        {extra}
      </div>

      <button className="btn-ghost" onClick={out}>
        Log out
      </button>
    </div>
  )
}
