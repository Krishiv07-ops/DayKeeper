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

Email delivery, background browser push and scheduled reminder execution are not yet enabled. The reminder preferences are saved, but a trusted server-side scheduler/email provider must be added before treating reminders as delivered. WhatsApp and AI natural-language parsing are planned follow-ups.
