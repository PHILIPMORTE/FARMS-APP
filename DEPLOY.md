# Deploying FARMS

## 1. Push to GitHub

```bash
git init
git add .
git commit -m "FARMS - Philippine farm management system"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/farms.git
git push -u origin main
```

**Check before pushing:** `.env` must NOT appear in `git status`. It holds your
Supabase keys. `.gitignore` already excludes it.

## 2. Deploy on Vercel (free)

1. vercel.com → sign in with GitHub → **Add New Project**
2. Import the `farms` repository
3. Framework preset: **Vite** (usually auto-detected)
4. Expand **Environment Variables** and add both:

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | your project URL |
   | `VITE_SUPABASE_ANON_KEY` | your anon key |

   Copy these from your local `.env`. The build fails without them.
5. **Deploy**

You get a URL like `https://farms-abc123.vercel.app`.

## 3. Point Supabase and Google at the live URL

Sign-in will fail until you do this.

**Supabase → Authentication → URL Configuration**
- Site URL: `https://your-app.vercel.app`
- Redirect URLs: add `https://your-app.vercel.app/auth/callback`
  (keep the localhost entry so local development still works)

**Google Cloud Console → Credentials → your OAuth client**
- Authorised JavaScript origins: add `https://your-app.vercel.app`
- Redirect URIs: unchanged — still the Supabase callback

## 4. Test on the live URL

- Register a Farm Owner
- Sign in with Google
- Load `https://your-app.vercel.app/owner/dashboard` directly and refresh
  (this is what `vercel.json` fixes — without it you get a 404)

## Updating later

```bash
git add .
git commit -m "describe what changed"
git push
```

Vercel rebuilds automatically. Database changes still have to be run by hand in
the Supabase SQL Editor — pushing code never touches your database.

## Note on the anon key

`VITE_SUPABASE_ANON_KEY` is meant to be public and ships inside the browser
bundle. Your data is protected by Row Level Security, not by hiding this key.
The key that must never be committed or exposed is the **service_role** key —
this project does not use it anywhere.
