-- =====================================================================
-- Landa Clothing Wholesale Business — category chosen in the piece popup
-- A piece is counted first (grade only); the popup then sets its category
-- and brand. Stock moves into the category the moment it is chosen.
-- Run once in the Supabase SQL editor (safe to re-run).
-- =====================================================================

alter table public.landa_clothing_wholesale_business_sorted_pieces alter column category drop not null;

create or replace view public.landa_clothing_wholesale_business_bale_yield_totals with (security_invoker = true) as
  select bale_id, coalesce(category, 'Unassigned') as category, grade, sum(qty)::int as qty
  from public.landa_clothing_wholesale_business_sorted_pieces
  group by bale_id, coalesce(category, 'Unassigned'), grade;

create or replace function public.landa_clothing_wholesale_business_put_pieces_in_stock(
  p_bale text, p_category text, p_grade text, p_qty int, p_source text, p_device text
) returns bigint language plpgsql volatile security definer set search_path = public as $$
declare st text; pid bigint;
begin
  select status into st from public.landa_clothing_wholesale_business_bales_received where id = p_bale for update;
  if st is null then raise exception 'Bale % not found', p_bale; end if;
  if st = 'sorted' then raise exception 'Bale % is already finished', p_bale; end if;
  if p_category is not null then
    update public.landa_clothing_wholesale_business_stock_items set qty = qty + p_qty, updated_at = now()
    where category = p_category and grade = p_grade;
    if not found then raise exception 'Unknown item % · %', p_category, p_grade; end if;
  elsif p_grade not in ('A', 'B', 'C', 'Reject') then
    raise exception 'Unknown grade %', p_grade;
  end if;
  insert into public.landa_clothing_wholesale_business_sorted_pieces (bale_id, category, grade, qty, source, device_id)
  values (p_bale, p_category, p_grade, p_qty, p_source, p_device)
  returning id into pid;
  if st = 'received' then
    update public.landa_clothing_wholesale_business_bales_received set status = 'sorting' where id = p_bale;
  end if;
  return pid;
end $$;

create or replace function public.landa_clothing_wholesale_business_remove_last_piece(p_bale text) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare r record;
begin
  select * into r from public.landa_clothing_wholesale_business_sorted_pieces
  where bale_id = p_bale and source <> 'bulk'
  order by id desc limit 1 for update;
  if not found then return null; end if;
  if r.category is not null then
    update public.landa_clothing_wholesale_business_stock_items set qty = qty - r.qty, updated_at = now()
    where category = r.category and grade = r.grade;
  end if;
  delete from public.landa_clothing_wholesale_business_sorted_pieces where id = r.id;
  return r.id;
end $$;

-- Button press: grade only (category optional), bale = the live bale
create or replace function public.landa_clothing_wholesale_business_record_one_piece(
  p_grade text, p_bale text default null, p_category text default null, p_brand text default null
) returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text; pid bigint;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select bale_id into b from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  b := coalesce(p_bale, b);
  if b is null then raise exception 'Pick a bale on the sorting screen first'; end if;
  pid := public.landa_clothing_wholesale_business_put_pieces_in_stock(b, nullif(trim(p_category), ''), initcap(p_grade), 1, 'button', null);
  if nullif(trim(p_brand), '') is not null then
    update public.landa_clothing_wholesale_business_sorted_pieces set brand = trim(p_brand) where id = pid;
  end if;
  return pid;
end $$;

-- Sensor box: grade only, category comes from the popup
create or replace function public.landa_clothing_wholesale_business_sensor_piece_counted(p_device_id text, p_device_key text, p_grade text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text;
begin
  perform public.landa_clothing_wholesale_business_check_sensor_device(p_device_id, p_device_key);
  select bale_id into b from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  if b is null then raise exception 'No bale selected on the sorting screen'; end if;
  return public.landa_clothing_wholesale_business_put_pieces_in_stock(b, null, initcap(p_grade), 1, 'sensor', p_device_id);
end $$;

-- Popup save: set/change category (moves stock) and brand
create or replace function public.landa_clothing_wholesale_business_set_piece_details(
  p_piece bigint, p_category text, p_brand text
) returns void language plpgsql volatile security definer set search_path = public as $$
declare r record; c text := nullif(trim(p_category), '');
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into r from public.landa_clothing_wholesale_business_sorted_pieces where id = p_piece for update;
  if not found then raise exception 'Piece % not found (was it undone?)', p_piece; end if;
  if c is not null and c is distinct from r.category then
    update public.landa_clothing_wholesale_business_stock_items set qty = qty + r.qty, updated_at = now()
    where category = c and grade = r.grade;
    if not found then raise exception 'Unknown category %', c; end if;
    if r.category is not null then
      update public.landa_clothing_wholesale_business_stock_items set qty = qty - r.qty, updated_at = now()
      where category = r.category and grade = r.grade;
    end if;
  end if;
  update public.landa_clothing_wholesale_business_sorted_pieces
  set category = coalesce(c, category), brand = coalesce(nullif(trim(p_brand), ''), brand)
  where id = p_piece;
end $$;

-- Starting a new live bale clears the old "category now" (no longer used)
update public.landa_clothing_wholesale_business_live_sorting_session set category = null where id = 1;
