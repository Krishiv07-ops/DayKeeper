# DayKeeper

A responsive, premium-minimal important-days reminder app. Built with Vite and Supabase Auth/Postgres. Each user's events are protected by row-level security.

## Deploy on Vercel

1. Import this GitHub repository into Vercel.
2. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` as environment variables.
3. Build command: `npm run build`; output directory: `dist`.
4. Deploy.

## Supabase setup

1. Create a Supabase project.
2. In Project Settings → API, copy the Project URL and anon/public key into the Vercel environment variables above.
3. Open SQL Editor in Supabase and run `supabase/schema.sql`.
4. In Authentication → URL Configuration, set the Site URL to the deployed Vercel URL.

Never expose a Supabase service-role key in frontend code. The app uses only the public anon key and relies on database RLS policies to isolate users' events.

## Current scope

Email/password signup and login, private event CRUD, annual and one-time events, categories, favourites, search/filtering, month calendar, per-event reminder preferences, and responsive dark/light themes.

Email reminders are implemented through Resend + Supabase Cron. To activate them, create a Resend account, verify a sender domain, add `resend_api_key` and `resend_from_email` to Supabase Vault (optionally `daykeeper_timezone`, default `Asia/Kolkata`), then run `supabase/reminders.sql` in the Supabase SQL Editor. The SQL installs an every-minute scheduler, sends due reminders, records provider responses in `reminder_email_log`, and retries failed requests up to three times. Resend Free currently includes 3,000 emails/month with a 100/day limit. Email delivery is not active until these external setup steps are completed and an end-to-end test succeeds. WhatsApp and AI natural-language parsing are planned follow-ups.
