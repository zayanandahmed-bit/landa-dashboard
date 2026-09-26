-- =====================================================================
-- Landa Clothing Wholesale Business — email alerts upgrade
-- Run once in the Supabase SQL editor (safe to re-run).
-- =====================================================================

alter table public.landa_clothing_wholesale_business_settings
  add column if not exists email_webapp_url text not null default '',
  add column if not exists email_daily_digest boolean not null default true,
  add column if not exists email_instant_alerts boolean not null default true,
  add column if not exists email_robot_connected_at timestamptz;

update public.landa_clothing_wholesale_business_settings
set alert_email = 'zayantechtricks@gmail.com'
where id = 1 and alert_email = '';

-- Long-lived login for the Google Apps Script email robot, so it can read
-- the data for the 9 AM digest and hourly urgent alerts. Only a logged-in
-- dashboard user can create it; creating a new one replaces the old one.
create or replace function public.landa_clothing_wholesale_business_create_email_robot_session()
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare t uuid;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  delete from public.landa_clothing_wholesale_business_login_sessions where device = 'email-robot';
  insert into public.landa_clothing_wholesale_business_login_sessions (device, expires_at)
  values ('email-robot', now() + interval '10 years')
  returning token into t;
  update public.landa_clothing_wholesale_business_settings set email_robot_connected_at = now() where id = 1;
  perform public.landa_clothing_wholesale_business_write_log('Email robot connected');
  return t;
end $$;
