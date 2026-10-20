-- =====================================================================
-- Landa Clothing Wholesale Business — barcode tracking
-- Print a barcode label, stick it on a bale / bundle / order / item,
-- then scan it at each step to record where it is on its journey.
-- Adds one table (16 in total). Run once in the Supabase SQL editor
-- (safe to re-run).
-- =====================================================================

-- Journey steps and places, editable in Settings
alter table public.landa_clothing_wholesale_business_settings
  add column if not exists tag_stages text[] not null
    default array['Received', 'Sorting', 'In stock', 'Reserved', 'Packed', 'Dispatched', 'Delivered'],
  add column if not exists tag_locations text[] not null
    default array['Bale yard', 'Sorting table', 'Stock room', 'Packing area', 'Loading bay', 'On truck', 'At customer'];

-- One row per printed label. "scans" holds the full history:
-- [{"at": time, "stage": ..., "location": ..., "note": ...}, ...]
create table if not exists public.landa_clothing_wholesale_business_tracked_barcode_tags (
  code text primary key,
  label text not null default '',
  kind text not null default 'bundle' check (kind in ('bundle', 'bale', 'order', 'item')),
  ref_id text,
  category text,
  grade text,
  qty int check (qty is null or qty >= 0),
  brand text,
  stage text not null default 'Received',
  location text not null default '',
  note text not null default '',
  scans jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  last_scan_at timestamptz not null default now()
);
create index if not exists landa_clothing_wholesale_business_tags_last_scan_idx
  on public.landa_clothing_wholesale_business_tracked_barcode_tags (last_scan_at desc);

alter table public.landa_clothing_wholesale_business_tracked_barcode_tags enable row level security;
drop policy if exists landa_clothing_wholesale_business_session_access on public.landa_clothing_wholesale_business_tracked_barcode_tags;
create policy landa_clothing_wholesale_business_session_access on public.landa_clothing_wholesale_business_tracked_barcode_tags
  for all to anon, authenticated
  using (public.landa_clothing_wholesale_business_session_is_valid())
  with check (public.landa_clothing_wholesale_business_session_is_valid());
grant select, insert, update, delete on public.landa_clothing_wholesale_business_tracked_barcode_tags to anon, authenticated;
drop trigger if exists landa_clothing_wholesale_business_sync_ping on public.landa_clothing_wholesale_business_tracked_barcode_tags;
create trigger landa_clothing_wholesale_business_sync_ping
  after insert or update or delete or truncate on public.landa_clothing_wholesale_business_tracked_barcode_tags
  for each statement execute function public.landa_clothing_wholesale_business_touch_sync_ping();

-- Make 1-200 new labels at once: codes LND-000001, LND-000002, ...
create or replace function public.landa_clothing_wholesale_business_create_barcode_tags(
  p_count int, p_label text, p_kind text, p_ref text, p_category text, p_grade text,
  p_qty int, p_brand text, p_stage text, p_location text
) returns text[] language plpgsql volatile security definer set search_path = public as $$
declare n int; c text; out text[] := '{}'; st text := coalesce(nullif(trim(p_stage), ''), 'Received'); lc text := coalesce(trim(p_location), '');
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if coalesce(p_count, 0) < 1 or p_count > 200 then raise exception 'Make between 1 and 200 labels at a time'; end if;
  for i in 1..p_count loop
    insert into public.landa_clothing_wholesale_business_id_counters (prefix, last_value) values ('TAG', 1)
    on conflict (prefix) do update set last_value = public.landa_clothing_wholesale_business_id_counters.last_value + 1
    returning last_value into n;
    c := 'LND-' || lpad(n::text, 6, '0');
    insert into public.landa_clothing_wholesale_business_tracked_barcode_tags
      (code, label, kind, ref_id, category, grade, qty, brand, stage, location, scans)
    values (c, coalesce(trim(p_label), ''), coalesce(nullif(p_kind, ''), 'bundle'), nullif(trim(p_ref), ''),
      nullif(trim(p_category), ''), nullif(trim(p_grade), ''), p_qty, nullif(trim(p_brand), ''), st, lc,
      jsonb_build_array(jsonb_build_object('at', now(), 'stage', st, 'location', lc, 'note', 'Label created')));
    out := out || c;
  end loop;
  perform public.landa_clothing_wholesale_business_write_log(format('%s barcode label(s) created: %s%s', p_count, out[1],
    case when p_count > 1 then ' to ' || out[p_count] else '' end));
  return out;
end $$;

-- A scan: record the new step / place, keep the history
create or replace function public.landa_clothing_wholesale_business_scan_barcode_tag(
  p_code text, p_stage text, p_location text, p_note text
) returns void language plpgsql volatile security definer set search_path = public as $$
declare cd text := upper(trim(p_code));
begin
  perform public.landa_clothing_wholesale_business_require_session();
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    stage = coalesce(nullif(trim(p_stage), ''), stage),
    location = coalesce(nullif(trim(p_location), ''), location),
    note = coalesce(trim(p_note), ''),
    last_scan_at = now(),
    scans = scans || jsonb_build_array(jsonb_build_object('at', now(),
      'stage', coalesce(nullif(trim(p_stage), ''), stage),
      'location', coalesce(nullif(trim(p_location), ''), location),
      'note', coalesce(trim(p_note), '')))
  where code = cd;
  if not found then raise exception 'No label with code %', cd; end if;
end $$;

create or replace function public.landa_clothing_wholesale_business_update_barcode_tag(
  p_code text, p_label text, p_kind text, p_ref text, p_category text, p_grade text, p_qty int, p_brand text
) returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    label = coalesce(trim(p_label), ''), kind = coalesce(nullif(p_kind, ''), kind), ref_id = nullif(trim(p_ref), ''),
    category = nullif(trim(p_category), ''), grade = nullif(trim(p_grade), ''), qty = p_qty, brand = nullif(trim(p_brand), '')
  where code = upper(trim(p_code));
  if not found then raise exception 'No label with code %', p_code; end if;
end $$;

-- Remove one wrong entry from the history (index 0 = oldest).
-- The current step / place then follow whatever is now the latest entry.
create or replace function public.landa_clothing_wholesale_business_remove_barcode_tag_scan(p_code text, p_index int)
returns void language plpgsql volatile security definer set search_path = public as $$
declare t record; last jsonb;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into t from public.landa_clothing_wholesale_business_tracked_barcode_tags where code = upper(trim(p_code)) for update;
  if not found then raise exception 'No label with code %', p_code; end if;
  if jsonb_array_length(t.scans) <= 1 then raise exception 'A label must keep at least one history entry'; end if;
  if p_index < 0 or p_index >= jsonb_array_length(t.scans) then raise exception 'That history entry no longer exists'; end if;
  last := (t.scans - p_index) -> -1;
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    scans = scans - p_index,
    stage = coalesce(last ->> 'stage', stage),
    location = coalesce(last ->> 'location', location),
    note = coalesce(last ->> 'note', ''),
    last_scan_at = coalesce((last ->> 'at')::timestamptz, last_scan_at)
  where code = t.code;
end $$;

create or replace function public.landa_clothing_wholesale_business_delete_barcode_tag(p_code text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  delete from public.landa_clothing_wholesale_business_tracked_barcode_tags where code = upper(trim(p_code));
  if not found then raise exception 'No label with code %', p_code; end if;
  perform public.landa_clothing_wholesale_business_write_log(format('Barcode label %s deleted', upper(trim(p_code))));
end $$;

-- "Wipe everything" now also clears the labels
create or replace function public.landa_clothing_wholesale_business_wipe_all_business_data() returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  update public.landa_clothing_wholesale_business_live_sorting_session set bale_id = null, category = null, updated_at = now() where true;
  delete from public.landa_clothing_wholesale_business_tracked_barcode_tags where true;
  delete from public.landa_clothing_wholesale_business_sorted_pieces where true;
  delete from public.landa_clothing_wholesale_business_customer_order_lines where true;
  delete from public.landa_clothing_wholesale_business_customer_orders where true;
  delete from public.landa_clothing_wholesale_business_bales_received where true;
  delete from public.landa_clothing_wholesale_business_wholesale_customers where true;
  delete from public.landa_clothing_wholesale_business_activity_log where true;
  delete from public.landa_clothing_wholesale_business_id_counters where prefix in ('B', 'O', 'C', 'TAG');
  update public.landa_clothing_wholesale_business_stock_items set qty = 0, updated_at = now() where true;
  perform public.landa_clothing_wholesale_business_write_log('All bales, orders, wholesalers and barcode labels wiped — fresh start');
end $$;
