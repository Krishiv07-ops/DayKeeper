-- DayKeeper scheduled email reminders
-- Run only AFTER adding these Supabase Vault secrets:
--   resend_api_key       = your Resend API key (re_...)
--   resend_from_email    = DayKeeper <reminders@your-verified-domain>
-- Optional:
--   daykeeper_timezone   = Asia/Kolkata
--
-- This job runs every minute. It sends due reminders once, retries failed
-- provider requests up to 3 times, and records provider responses.

create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists public.reminder_email_log (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  occurrence_date date not null,
  reminder_type text not null check (reminder_type in ('day_before', 'event_day')),
  recipient_email text not null,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  attempts integer not null default 0,
  provider_request_id bigint,
  provider_status_code integer,
  provider_response text,
  created_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  sent_at timestamptz,
  unique (event_id, occurrence_date, reminder_type)
);

alter table public.reminder_email_log enable row level security;
revoke all on public.reminder_email_log from anon, authenticated;

create or replace function public.daykeeper_next_occurrence(
  p_event_date date,
  p_recurrence text,
  p_today date
)
returns date
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_year integer;
  v_month integer;
  v_day integer;
  v_last_day integer;
  v_candidate date;
begin
  if p_recurrence <> 'annual' then
    return p_event_date;
  end if;

  v_year := extract(year from p_today)::integer;
  v_month := extract(month from p_event_date)::integer;
  v_day := extract(day from p_event_date)::integer;

  loop
    v_last_day := extract(day from
      (make_date(v_year, v_month, 1) + interval '1 month - 1 day')
    )::integer;
    v_candidate := make_date(v_year, v_month, least(v_day, v_last_day));

    if v_candidate >= p_today then
      return v_candidate;
    end if;

    v_year := v_year + 1;
  end loop;
end;
$$;

create or replace function public.daykeeper_html_escape(p_value text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select replace(
    replace(
      replace(
        replace(
          replace(coalesce(p_value, ''), '&', '&amp;'),
        '<', '&lt;'),
      '>', '&gt;'),
    '"', '&quot;'),
  '''', '&#39;');
$$;

create or replace function public.dispatch_due_reminder_emails()
returns void
language plpgsql
security definer
set search_path = public, auth, vault, net, pg_temp
as $$
declare
  v_api_key text;
  v_from_email text;
  v_timezone text;
  v_local_now timestamp without time zone;
  v_item record;
  v_log_id bigint;
  v_request_id bigint;
  v_subject text;
  v_html text;
  v_text text;
begin
  select decrypted_secret into v_api_key
  from vault.decrypted_secrets
  where name = 'resend_api_key'
  limit 1;

  select decrypted_secret into v_from_email
  from vault.decrypted_secrets
  where name = 'resend_from_email'
  limit 1;

  select decrypted_secret into v_timezone
  from vault.decrypted_secrets
  where name = 'daykeeper_timezone'
  limit 1;

  if coalesce(v_api_key, '') = '' then
    raise exception 'Missing Supabase Vault secret: resend_api_key';
  end if;
  if coalesce(v_from_email, '') = '' then
    raise exception 'Missing Supabase Vault secret: resend_from_email';
  end if;

  v_timezone := coalesce(nullif(v_timezone, ''), 'Asia/Kolkata');
  v_local_now := now() at time zone v_timezone;

  -- Resolve asynchronous pg_net responses from the previous scheduler runs.
  update public.reminder_email_log l
  set status = case
        when r.status_code between 200 and 299 then 'sent'
        else 'failed'
      end,
      provider_status_code = r.status_code,
      provider_response = left(coalesce(r.content, ''), 4000),
      sent_at = case when r.status_code between 200 and 299 then now() else null end
  from net._http_response r
  where l.provider_request_id = r.id
    and l.status = 'queued';

  for v_item in
    select
      e.id as event_id,
      e.user_id,
      u.email as recipient_email,
      e.title,
      e.reminder_time,
      o.occurrence_date,
      r.reminder_type
    from public.events e
    join auth.users u on u.id = e.user_id
    cross join lateral (
      select public.daykeeper_next_occurrence(
        e.event_date, e.recurrence, v_local_now::date
      ) as occurrence_date
    ) o
    cross join lateral (
      values
        ('day_before'::text, e.reminder_before, o.occurrence_date - 1),
        ('event_day'::text, e.reminder_day, o.occurrence_date)
    ) r(reminder_type, enabled, target_date)
    where r.enabled
      and r.target_date = v_local_now::date
      and e.reminder_time <= v_local_now::time
      and u.email is not null
  loop
    v_log_id := null;

    insert into public.reminder_email_log (
      event_id, user_id, occurrence_date, reminder_type,
      recipient_email, status, attempts, last_attempt_at
    )
    values (
      v_item.event_id, v_item.user_id, v_item.occurrence_date,
      v_item.reminder_type, v_item.recipient_email, 'queued', 1, now()
    )
    on conflict (event_id, occurrence_date, reminder_type)
    do update set
      status = 'queued',
      attempts = public.reminder_email_log.attempts + 1,
      provider_request_id = null,
      provider_status_code = null,
      provider_response = null,
      last_attempt_at = now()
    where public.reminder_email_log.status = 'failed'
      and public.reminder_email_log.attempts < 3
    returning id into v_log_id;

    if v_log_id is null then
      continue;
    end if;

    if v_item.reminder_type = 'day_before' then
      v_subject := 'Reminder: ' || v_item.title || ' is tomorrow';
      v_text := 'A reminder from DayKeeper: ' || v_item.title || ' is tomorrow.';
      v_html := '<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;padding:32px;color:#202124">'
        || '<p style="color:#777;font-size:12px;letter-spacing:2px">DAYKEEPER</p>'
        || '<h1 style="font-size:26px">A little heads-up ✨</h1>'
        || '<p><strong>' || public.daykeeper_html_escape(v_item.title)
        || '</strong> is tomorrow.</p>'
        || '<p style="color:#666">Make a little room for what matters.</p>'
        || '<p style="margin-top:32px;color:#999;font-size:12px">Sent by DayKeeper</p></div>';
    else
      v_subject := 'Today: ' || v_item.title;
      v_text := 'A reminder from DayKeeper: today is ' || v_item.title || '.';
      v_html := '<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;padding:32px;color:#202124">'
        || '<p style="color:#777;font-size:12px;letter-spacing:2px">DAYKEEPER</p>'
        || '<h1 style="font-size:26px">Today is the day ✨</h1>'
        || '<p>Remember: <strong>' || public.daykeeper_html_escape(v_item.title)
        || '</strong> is today.</p>'
        || '<p style="color:#666">Make a little room for what matters.</p>'
        || '<p style="margin-top:32px;color:#999;font-size:12px">Sent by DayKeeper</p></div>';
    end if;

    begin
      v_request_id := net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || v_api_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
          'from', v_from_email,
          'to', jsonb_build_array(v_item.recipient_email),
          'subject', v_subject,
          'html', v_html,
          'text', v_text
        ),
        timeout_milliseconds := 10000
      );

      update public.reminder_email_log
      set provider_request_id = v_request_id,
          status = 'queued'
      where id = v_log_id;
    exception when others then
      update public.reminder_email_log
      set status = 'failed',
          provider_response = left(sqlerrm, 4000)
      where id = v_log_id;
    end;
  end loop;
end;
$$;

revoke all on function public.dispatch_due_reminder_emails() from public, anon, authenticated;
revoke all on function public.daykeeper_next_occurrence(date, text, date) from public, anon, authenticated;
revoke all on function public.daykeeper_html_escape(text) from public, anon, authenticated;

-- Replace any previous copy of this job, then check for due reminders each minute.
select cron.unschedule(jobid)
from cron.job
where jobname = 'daykeeper-send-reminders';

select cron.schedule(
  'daykeeper-send-reminders',
  '* * * * *',
  'select public.dispatch_due_reminder_emails();'
);
