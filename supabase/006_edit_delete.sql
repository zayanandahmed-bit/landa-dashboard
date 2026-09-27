-- =====================================================================
-- Landa Clothing Wholesale Business — edit and delete everywhere
-- Every function keeps stock correct (gives pieces back / takes them out)
-- and refuses to do anything that would push stock below zero.
-- Run once in the Supabase SQL editor (safe to re-run).
-- =====================================================================

create or replace function public.landa_clothing_wholesale_business_update_bale(
  p_bale text, p_date date, p_supplier text, p_type text, p_weight numeric, p_cost numeric
) returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if nullif(trim(p_supplier), '') is null or nullif(trim(p_type), '') is null then raise exception 'Supplier and bale type are required'; end if;
  if coalesce(p_weight, 0) <= 0 then raise exception 'Weight must be more than 0'; end if;
  update public.landa_clothing_wholesale_business_bales_received
  set received_date = coalesce(p_date, received_date), supplier = trim(p_supplier), bale_type = trim(p_type),
      weight_kg = p_weight, cost = coalesce(p_cost, cost)
  where id = p_bale;
  if not found then raise exception 'Bale % not found', p_bale; end if;
  perform public.landa_clothing_wholesale_business_write_log(format('Bale %s edited', p_bale));
end $$;

-- p_remove_stock = true: the bale's sorted pieces leave stock with it.
-- false: the bale record and its piece history go, stock counts stay as they are.
create or replace function public.landa_clothing_wholesale_business_delete_bale(p_bale text, p_remove_stock boolean default true)
returns int language plpgsql volatile security definer set search_path = public as $$
declare r record; n int; cur int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  perform 1 from public.landa_clothing_wholesale_business_bales_received where id = p_bale for update;
  if not found then raise exception 'Bale % not found', p_bale; end if;
  select coalesce(sum(qty), 0)::int into n from public.landa_clothing_wholesale_business_sorted_pieces where bale_id = p_bale;
  if p_remove_stock then
    for r in
      select category, grade, sum(qty)::int as q from public.landa_clothing_wholesale_business_sorted_pieces
      where bale_id = p_bale and category is not null group by 1, 2
    loop
      update public.landa_clothing_wholesale_business_stock_items set qty = qty - r.q, updated_at = now()
      where category = r.category and grade = r.grade returning qty into cur;
      if cur < 0 then
        raise exception 'Some pieces from this bale (%, %) are already sold, so stock would go below zero. Choose "keep stock as it is", or fix the counts on the Inventory page first.', r.category, r.grade;
      end if;
    end loop;
  end if;
  delete from public.landa_clothing_wholesale_business_bales_received where id = p_bale;
  perform public.landa_clothing_wholesale_business_write_log(format('Bale %s deleted (%s pcs, stock %s)', p_bale, n, case when p_remove_stock then 'removed' else 'kept' end));
  return n;
end $$;

create or replace function public.landa_clothing_wholesale_business_delete_piece(p_piece bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare r record; cur int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into r from public.landa_clothing_wholesale_business_sorted_pieces where id = p_piece for update;
  if not found then raise exception 'Piece % not found', p_piece; end if;
  if r.category is not null then
    update public.landa_clothing_wholesale_business_stock_items set qty = qty - r.qty, updated_at = now()
    where category = r.category and grade = r.grade returning qty into cur;
    if cur < 0 then raise exception 'That piece has already been sold, so stock would go below zero'; end if;
  end if;
  delete from public.landa_clothing_wholesale_business_sorted_pieces where id = p_piece;
end $$;

-- p_category / p_grade null = keep as is. p_brand null = keep, '' = clear.
create or replace function public.landa_clothing_wholesale_business_update_piece(
  p_piece bigint, p_category text, p_grade text, p_brand text
) returns void language plpgsql volatile security definer set search_path = public as $$
declare r record; c text; g text; cur int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into r from public.landa_clothing_wholesale_business_sorted_pieces where id = p_piece for update;
  if not found then raise exception 'Piece % not found', p_piece; end if;
  c := coalesce(nullif(trim(p_category), ''), r.category);
  g := coalesce(nullif(initcap(trim(p_grade)), ''), r.grade);
  if g not in ('A', 'B', 'C', 'Reject') then raise exception 'Unknown grade %', g; end if;
  if r.category is distinct from c or r.grade <> g then
    if r.category is not null then
      update public.landa_clothing_wholesale_business_stock_items set qty = qty - r.qty, updated_at = now()
      where category = r.category and grade = r.grade returning qty into cur;
      if cur < 0 then raise exception 'That piece has already been sold, so it cannot be moved'; end if;
    end if;
    if c is not null then
      update public.landa_clothing_wholesale_business_stock_items set qty = qty + r.qty, updated_at = now()
      where category = c and grade = g;
      if not found then raise exception 'Unknown item % · %', c, g; end if;
    end if;
  end if;
  update public.landa_clothing_wholesale_business_sorted_pieces
  set category = c, grade = g, brand = case when p_brand is null then brand else nullif(trim(p_brand), '') end
  where id = p_piece;
end $$;

-- p_lines null = leave the items alone (only edit customer/date/courier/paid)
create or replace function public.landa_clothing_wholesale_business_update_order(
  p_order text, p_customer text, p_date date, p_courier text, p_tracking text, p_paid numeric, p_lines jsonb
) returns void language plpgsql volatile security definer set search_path = public as $$
declare o record; r record; avail int; tot numeric;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into o from public.landa_clothing_wholesale_business_customer_orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if p_lines is not null then
    if coalesce(jsonb_array_length(p_lines), 0) = 0 then raise exception 'An order needs at least one item'; end if;
    if o.status <> 'cancelled' then
      -- give the old items back, then check and take the new ones
      update public.landa_clothing_wholesale_business_stock_items s set qty = s.qty + x.q, updated_at = now()
      from (select category, grade, sum(qty) as q from public.landa_clothing_wholesale_business_customer_order_lines where order_id = p_order group by 1, 2) x
      where s.category = x.category and s.grade = x.grade;
      for r in
        select category, grade, sum(qty)::int as qty
        from jsonb_to_recordset(p_lines) as x(category text, grade text, qty int, price numeric) group by 1, 2
      loop
        select qty into avail from public.landa_clothing_wholesale_business_stock_items
        where category = r.category and grade = r.grade for update;
        if avail is null then raise exception 'Unknown item % · %', r.category, r.grade; end if;
        if r.qty is null or r.qty <= 0 then raise exception 'Every item needs a quantity'; end if;
        if avail < r.qty then raise exception 'Only % pcs of % · % available', avail, r.category, r.grade; end if;
      end loop;
      update public.landa_clothing_wholesale_business_stock_items s set qty = s.qty - x.q, updated_at = now()
      from (select category, grade, sum(qty) as q from jsonb_to_recordset(p_lines) as y(category text, grade text, qty int, price numeric) group by 1, 2) x
      where s.category = x.category and s.grade = x.grade;
    end if;
    delete from public.landa_clothing_wholesale_business_customer_order_lines where order_id = p_order;
    insert into public.landa_clothing_wholesale_business_customer_order_lines (order_id, category, grade, qty, price)
    select p_order, category, grade, qty, price from jsonb_to_recordset(p_lines) as x(category text, grade text, qty int, price numeric);
  end if;
  select coalesce(sum(qty * price), 0) into tot from public.landa_clothing_wholesale_business_customer_order_lines where order_id = p_order;
  update public.landa_clothing_wholesale_business_customer_orders set
    customer_id = coalesce(nullif(p_customer, ''), customer_id),
    order_date = coalesce(p_date, order_date),
    courier = nullif(trim(p_courier), ''),
    tracking = nullif(trim(p_tracking), ''),
    paid = least(greatest(coalesce(p_paid, paid), 0), tot)
  where id = p_order;
  perform public.landa_clothing_wholesale_business_write_log(format('Order %s edited', p_order));
end $$;

create or replace function public.landa_clothing_wholesale_business_delete_order(p_order text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare o record;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into o from public.landa_clothing_wholesale_business_customer_orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if o.status <> 'cancelled' then
    update public.landa_clothing_wholesale_business_stock_items s set qty = s.qty + x.q, updated_at = now()
    from (select category, grade, sum(qty) as q from public.landa_clothing_wholesale_business_customer_order_lines where order_id = p_order group by 1, 2) x
    where s.category = x.category and s.grade = x.grade;
  end if;
  delete from public.landa_clothing_wholesale_business_customer_orders where id = p_order;
  perform public.landa_clothing_wholesale_business_write_log(format('Order %s deleted%s', p_order, case when o.status <> 'cancelled' then ' (stock returned)' else '' end));
end $$;

create or replace function public.landa_clothing_wholesale_business_delete_customer(p_id text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare n int; nm text;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select name into nm from public.landa_clothing_wholesale_business_wholesale_customers where id = p_id;
  if nm is null then raise exception 'Wholesaler not found'; end if;
  select count(*) into n from public.landa_clothing_wholesale_business_customer_orders where customer_id = p_id;
  if n > 0 then raise exception '% has % order(s). Delete or reassign those orders first.', nm, n; end if;
  delete from public.landa_clothing_wholesale_business_wholesale_customers where id = p_id;
  perform public.landa_clothing_wholesale_business_write_log(format('Wholesaler %s deleted', nm));
end $$;

create or replace function public.landa_clothing_wholesale_business_rename_category(p_old text, p_new text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare n text := trim(p_new);
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if n = '' or position('|' in n) > 0 then raise exception 'Enter a category name (no | character)'; end if;
  if exists (select 1 from public.landa_clothing_wholesale_business_categories where lower(name) = lower(n) and name <> p_old) then
    raise exception 'A category called % already exists', n;
  end if;
  update public.landa_clothing_wholesale_business_categories set name = n where name = p_old;
  if not found then raise exception 'Category % not found', p_old; end if;
  update public.landa_clothing_wholesale_business_sorted_pieces set category = n where category = p_old;
  update public.landa_clothing_wholesale_business_customer_order_lines set category = n where category = p_old;
  update public.landa_clothing_wholesale_business_live_sorting_session set category = n where category = p_old;
  perform public.landa_clothing_wholesale_business_write_log(format('Category %s renamed to %s', p_old, n));
end $$;

create or replace function public.landa_clothing_wholesale_business_delete_category(p_name text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if exists (select 1 from public.landa_clothing_wholesale_business_stock_items where category = p_name and qty <> 0) then
    raise exception '% still has stock. Set its counts to 0 on the Inventory page first.', p_name;
  end if;
  if exists (select 1 from public.landa_clothing_wholesale_business_sorted_pieces where category = p_name)
     or exists (select 1 from public.landa_clothing_wholesale_business_customer_order_lines where category = p_name) then
    raise exception '% appears in past sorting or orders, so it cannot be deleted. Rename it instead.', p_name;
  end if;
  delete from public.landa_clothing_wholesale_business_categories where name = p_name;
  if not found then raise exception 'Category % not found', p_name; end if;
  perform public.landa_clothing_wholesale_business_write_log(format('Category %s deleted', p_name));
end $$;

create or replace function public.landa_clothing_wholesale_business_rename_brand(p_old text, p_new text) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n text := trim(p_new); k int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if n = '' then raise exception 'Enter a brand name'; end if;
  update public.landa_clothing_wholesale_business_settings set updated_at = now(), brand_list = coalesce((
    select array_agg(b order by b) from (
      select distinct on (lower(b)) b from (select case when b = p_old then n else b end as b from unnest(brand_list) b) y
      order by lower(b), b
    ) x), '{}') where id = 1;
  update public.landa_clothing_wholesale_business_sorted_pieces set brand = n where brand = p_old;
  get diagnostics k = row_count;
  update public.landa_clothing_wholesale_business_live_sorting_session set brand = n where brand = p_old;
  perform public.landa_clothing_wholesale_business_write_log(format('Brand %s renamed to %s (%s pieces)', p_old, n, k));
  return k;
end $$;
