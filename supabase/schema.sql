create extension if not exists pgcrypto;
create table if not exists public.events (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null check (char_length(title) between 1 and 120),
 event_date date not null,
 category text not null default 'Personal milestones',
 notes text,
 recurrence text not null default 'annual' check (recurrence in ('annual','once')),
 reminder_day boolean not null default true,
 reminder_before boolean not null default true,
 reminder_time time not null default '08:00',
 favorite boolean not null default false,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.events enable row level security;
drop policy if exists "Users read own events" on public.events;
drop policy if exists "Users insert own events" on public.events;
drop policy if exists "Users update own events" on public.events;
drop policy if exists "Users delete own events" on public.events;
create policy "Users read own events" on public.events for select using (auth.uid() = user_id);
create policy "Users insert own events" on public.events for insert with check (auth.uid() = user_id);
create policy "Users update own events" on public.events for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "Users delete own events" on public.events for delete using (auth.uid() = user_id);
create index if not exists events_user_date_idx on public.events(user_id,event_date);
