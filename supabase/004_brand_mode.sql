-- =====================================================================
-- Landa Clothing Wholesale Business — brand mode
-- Pick a brand once on the sorting screen; every piece counted after that
-- (button or sensor) gets that brand automatically, and the popup only
-- asks for the category. Stored in the database so it follows you across
-- devices. Run once in the Supabase SQL editor (safe to re-run).
-- =====================================================================

alter table public.landa_clothing_wholesale_business_live_sorting_session
  add column if not exists brand text;

-- Switching to another bale (or finishing / wiping) turns brand mode off
create or replace function public.landa_clothing_wholesale_business_reset_brand_mode() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.bale_id is distinct from old.bale_id then new.brand := null; end if;
  return new;
end $$;

drop trigger if exists landa_clothing_wholesale_business_reset_brand_mode on public.landa_clothing_wholesale_business_live_sorting_session;
create trigger landa_clothing_wholesale_business_reset_brand_mode
  before update on public.landa_clothing_wholesale_business_live_sorting_session
  for each row execute function public.landa_clothing_wholesale_business_reset_brand_mode();

create or replace function public.landa_clothing_wholesale_business_record_one_piece(
  p_grade text, p_bale text default null, p_category text default null, p_brand text default null
) returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text; lb text; pid bigint;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select bale_id, brand into b, lb from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  b := coalesce(p_bale, b);
  if b is null then raise exception 'Pick a bale on the sorting screen first'; end if;
  pid := public.landa_clothing_wholesale_business_put_pieces_in_stock(b, nullif(trim(p_category), ''), initcap(p_grade), 1, 'button', null);
  update public.landa_clothing_wholesale_business_sorted_pieces
  set brand = coalesce(nullif(trim(p_brand), ''), lb) where id = pid and coalesce(nullif(trim(p_brand), ''), lb) is not null;
  return pid;
end $$;

create or replace function public.landa_clothing_wholesale_business_sensor_piece_counted(p_device_id text, p_device_key text, p_grade text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text; lb text; pid bigint;
begin
  perform public.landa_clothing_wholesale_business_check_sensor_device(p_device_id, p_device_key);
  select bale_id, brand into b, lb from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  if b is null then raise exception 'No bale selected on the sorting screen'; end if;
  pid := public.landa_clothing_wholesale_business_put_pieces_in_stock(b, null, initcap(p_grade), 1, 'sensor', p_device_id);
  if lb is not null then
    update public.landa_clothing_wholesale_business_sorted_pieces set brand = lb where id = pid;
  end if;
  return pid;
end $$;
