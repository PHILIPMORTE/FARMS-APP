# Deploying FARMS

Four things your teacher asked for, in order. Budget about an hour, mostly waiting
for DNS.

---

## Step 1 — Push the code to GitHub

Your repository already exists at `github.com/PHILIPMORTE/FARMS-APP`.

```powershell
cd "C:\path\to\FARMS APP"

git add .
git commit -m "Final build for deployment"
git push origin main
```

If this is a fresh folder and git has not been set up yet:

```powershell
git init
git branch -M main
git remote add origin https://github.com/PHILIPMORTE/FARMS-APP.git
git add .
git commit -m "FARMS system"
git push -u origin main
```

**Before you push, confirm `.env` is NOT going up.** It holds your Supabase keys.

```powershell
git check-ignore .env
```

If that prints `.env`, you are safe. If it prints nothing, stop and add `.env`
to `.gitignore` first.

---

## Step 2 — Claim the Name.com domain

1. Go to `education.github.com/pack` and sign in with your GitHub account.
2. Find **Name.com** in the list of offers and click **Get access**.
3. It sends you to Name.com with a coupon applied. Create an account there.
4. Search for a domain and register it. The free offer covers one year on
   selected endings, usually `.com.co`, `.me`, or similar. Pick whatever the
   coupon actually covers.

Suggested names: `farms-pagatban.me`, `farmspagatban.com.co`.

Keep the Name.com login details. Step 3 needs them.

---

## Step 3 — Host the site and point the domain at it

GitHub Pages cannot run this app well because it is a single-page app that also
needs environment variables at build time. Use **Vercel** instead. It is free,
connects straight to your GitHub repo, and rebuilds every time you push.

### 3a. Deploy on Vercel

1. Go to `vercel.com` and sign in **with GitHub**.
2. **Add New → Project**, then import `FARMS-APP`.
3. Vercel detects Vite on its own. Leave the build settings alone:
   - Build command: `npm run build`
   - Output directory: `dist`
4. Open **Environment Variables** and add both of these, copying the values
   from your local `.env`:

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | `https://xxxx.supabase.co` |
   | `VITE_SUPABASE_ANON_KEY` | `eyJhbGci...` |

   Miss this and the site loads but nothing connects.
5. Click **Deploy**. You get a working URL such as `farms-app.vercel.app`.

Test that URL before going any further.

### 3b. Attach your Name.com domain

1. In Vercel: **Project → Settings → Domains → Add**, and enter your domain.
2. Vercel shows you the DNS records it wants. Usually:

   | Type | Host | Value |
   |---|---|---|
   | A | `@` | `76.76.21.21` |
   | CNAME | `www` | `cname.vercel-dns.com` |

   Use the values Vercel actually shows you, not these, in case they change.
3. In Name.com: **My Domains → your domain → DNS Records**. Delete the parking
   records Name.com added, then add the two records from Vercel.
4. Wait. DNS usually takes 10–30 minutes, occasionally a few hours. Vercel
   issues the HTTPS certificate on its own once the records resolve.

---

## Step 4 — Configure the database for the internet

Supabase is already cloud-hosted, so the database is on the internet the moment
you deploy. What it does not yet know is your new address, and sign-in will fail
until you tell it.

### 4a. Supabase redirect URLs

**Authentication → URL Configuration**

- **Site URL**: `https://yourdomain.com`
- **Redirect URLs**: add each of these on its own line

  ```
  https://yourdomain.com/auth/callback
  https://www.yourdomain.com/auth/callback
  https://farms-app.vercel.app/auth/callback
  http://localhost:5173/auth/callback
  ```

Keep the localhost one so you can still develop.

### 4b. Google sign-in

In **Google Cloud Console → Credentials → your OAuth client**:

- **Authorized JavaScript origins**: `https://yourdomain.com`
- **Authorized redirect URIs**: `https://xxxx.supabase.co/auth/v1/callback`

The redirect URI stays pointed at Supabase, not at your domain. That trips
people up.

### 4c. Confirm the migrations are all applied

In the Supabase SQL Editor, run every file in `supabase/` in order, if you have
not already:

```
schema.sql
update-patch.sql
migration-2a.sql
migration-2b.sql
migration-3.sql  ...  migration-20.sql
```

Then check nothing is missing:

```sql
select routine_name
  from information_schema.routines
 where routine_schema = 'public'
 order by routine_name;
```

You should see around 30 functions, including `purchase_product`,
`harvest_schedule`, `add_or_merge_planting` and `farmer_confirm_payment`.

### 4d. Check Row Level Security is on

```sql
select tablename, rowsecurity
  from pg_tables
 where schemaname = 'public'
 order by tablename;
```

Every row should show `rowsecurity = true`. This is what stops one farm reading
another farm's data once the site is public. Do not skip it.

---

## After it is live

Walk through this on the real domain, not localhost:

- [ ] Register a new Farm Owner and get the verification screen
- [ ] Approve them from the admin panel
- [ ] Add a planting, then harvest it
- [ ] List the harvest on the market
- [ ] Buy it from a Buyer account
- [ ] Sign in with Google
- [ ] Open it on a phone

---

## If something breaks

**Blank white page** — environment variables missing in Vercel. Add them and
redeploy.

**404 when refreshing a page like `/owner/market`** — `vercel.json` was not
picked up. It is in the repo root; confirm it was pushed.

**Google sign-in returns to a "redirect not allowed" error** — the callback URL
is not in the Supabase redirect list. Check 4a.

**Site loads but sign-in fails** — check the Supabase URL and anon key in
Vercel, and confirm the Site URL in 4a matches your domain exactly, including
whether you use `www`.
