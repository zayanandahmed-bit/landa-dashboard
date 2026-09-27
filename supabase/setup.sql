-- =====================================================================
-- Landa Clothing Wholesale Business — Supabase database setup
--
-- Every table, view and function starts with
--   landa_clothing_wholesale_business_
-- so nothing collides with the other apps sharing this Supabase project.
--
-- Safe to run more than once.
-- After running it, set the dashboard password (see the bottom of this file).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create or replace function public.landa_clothing_wholesale_business_today_karachi() returns date
language sql stable set search_path = public as $$
  select (now() at time zone 'Asia/Karachi')::date
$$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table if not exists public.landa_clothing_wholesale_business_settings (
  id int primary key default 1 check (id = 1),
  biz_name text not null default 'My Landa Business',
  alert_email text not null default '',
  sort_days int not null default 3,
  dispatch_days int not null default 2,
  due_days int not null default 10,
  runout_days int not null default 7,
  dead_days int not null default 14,
  sensor_lockout_seconds int not null default 3,
  updated_at timestamptz not null default now()
);
insert into public.landa_clothing_wholesale_business_settings (id) values (1) on conflict (id) do nothing;

-- Dashboard password (bcrypt hash). Never readable from the browser.
create table if not exists public.landa_clothing_wholesale_business_access_passwords (
  id int primary key default 1 check (id = 1),
  password_hash text not null,
  updated_at timestamptz not null default now()
);

-- One row per logged-in device. The browser sends its token in the
-- x-landa-session header; every table policy checks it.
create table if not exists public.landa_clothing_wholesale_business_login_sessions (
  token uuid primary key default gen_random_uuid(),
  device text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);

create table if not exists public.landa_clothing_wholesale_business_id_counters (
  prefix text primary key,
  last_value int not null default 0
);

create table if not exists public.landa_clothing_wholesale_business_categories (
  name text primary key check (name <> '' and position('|' in name) = 0),
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.landa_clothing_wholesale_business_stock_items (
  category text not null references public.landa_clothing_wholesale_business_categories(name) on update cascade on delete cascade,
  grade text not null check (grade in ('A', 'B', 'C', 'Reject')),
  qty int not null default 0,
  price numeric(12, 2) not null default 0 check (price >= 0),
  min_qty int not null default 0 check (min_qty >= 0),
  updated_at timestamptz not null default now(),
  primary key (category, grade)
);

create table if not exists public.landa_clothing_wholesale_business_bales_received (
  id text primary key,
  received_date date not null default public.landa_clothing_wholesale_business_today_karachi(),
  supplier text not null,
  bale_type text not null,
  weight_kg numeric(10, 2) not null check (weight_kg > 0),
  cost numeric(12, 2) not null default 0 check (cost >= 0),
  status text not null default 'received' check (status in ('received', 'sorting', 'sorted')),
  sorted_date date,
  created_at timestamptz not null default now()
);

-- Every piece that comes out of a bale. Sensor/button pieces are one row
-- each (qty 1, brand filled in by the popup); hand-counted piles are one
-- row per category+grade with source 'bulk'.
create table if not exists public.landa_clothing_wholesale_business_sorted_pieces (
  id bigint generated always as identity primary key,
  bale_id text not null references public.landa_clothing_wholesale_business_bales_received(id) on delete cascade,
  category text not null,
  grade text not null check (grade in ('A', 'B', 'C', 'Reject')),
  qty int not null default 1 check (qty > 0),
  brand text,
  source text not null default 'button' check (source in ('sensor', 'button', 'bulk')),
  device_id text,
  created_at timestamptz not null default now()
);
create index if not exists landa_clothing_wholesale_business_sorted_pieces_bale_idx on public.landa_clothing_wholesale_business_sorted_pieces (bale_id, id desc);
create index if not exists landa_clothing_wholesale_business_sorted_pieces_pending_idx on public.landa_clothing_wholesale_business_sorted_pieces (id) where brand is null and source <> 'bulk';

create table if not exists public.landa_clothing_wholesale_business_wholesale_customers (
  id text primary key,
  name text not null check (name <> ''),
  city text not null default '',
  phone text not null default '',
  credit_limit numeric(12, 2) not null default 0 check (credit_limit >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.landa_clothing_wholesale_business_customer_orders (
  id text primary key,
  order_date date not null default public.landa_clothing_wholesale_business_today_karachi(),
  customer_id text not null references public.landa_clothing_wholesale_business_wholesale_customers(id),
  status text not null default 'new' check (status in ('new', 'packed', 'dispatched', 'delivered', 'cancelled')),
  paid numeric(12, 2) not null default 0 check (paid >= 0),
  courier text,
  tracking text,
  dispatch_date date,
  history jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.landa_clothing_wholesale_business_customer_order_lines (
  id bigint generated always as identity primary key,
  order_id text not null references public.landa_clothing_wholesale_business_customer_orders(id) on delete cascade,
  category text not null,
  grade text not null,
  qty int not null check (qty > 0),
  price numeric(12, 2) not null check (price >= 0)
);
create index if not exists landa_clothing_wholesale_business_order_lines_order_idx on public.landa_clothing_wholesale_business_customer_order_lines (order_id);

create table if not exists public.landa_clothing_wholesale_business_activity_log (
  id bigint generated always as identity primary key,
  happened_on date not null default public.landa_clothing_wholesale_business_today_karachi(),
  message text not null,
  created_at timestamptz not null default now()
);

-- Which bale + category the sensor boxes are currently counting into.
create table if not exists public.landa_clothing_wholesale_business_live_sorting_session (
  id int primary key default 1 check (id = 1),
  bale_id text references public.landa_clothing_wholesale_business_bales_received(id) on delete set null,
  category text,
  updated_at timestamptz not null default now()
);
insert into public.landa_clothing_wholesale_business_live_sorting_session (id) values (1) on conflict (id) do nothing;

create table if not exists public.landa_clothing_wholesale_business_sensor_devices (
  id text primary key,
  name text not null,
  key_hash text not null,
  last_seen timestamptz,
  created_at timestamptz not null default now()
);

-- Holds no business data: one row per table with the time it last changed.
-- Browsers listen to it over Realtime and reload when it moves.
create table if not exists public.landa_clothing_wholesale_business_sync_pings (
  table_name text primary key,
  changed_at timestamptz not null default now()
);

-- Starter categories (prices set later on the Inventory page)
do $$
declare c text; i int := 0;
begin
  if not exists (select 1 from public.landa_clothing_wholesale_business_categories) then
    foreach c in array array['Ladies Tops', 'Jeans', 'Jackets', 'Sweaters', 'Men Shirts', 'Kids Wear'] loop
      i := i + 1;
      insert into public.landa_clothing_wholesale_business_categories (name, sort_order) values (c, i);
      insert into public.landa_clothing_wholesale_business_stock_items (category, grade, min_qty)
      values (c, 'A', 60), (c, 'B', 40), (c, 'C', 0), (c, 'Reject', 0);
    end loop;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Views (security_invoker so the table policies still apply)
-- ---------------------------------------------------------------------

create or replace view public.landa_clothing_wholesale_business_bale_yield_totals with (security_invoker = true) as
  select bale_id, category, grade, sum(qty)::int as qty
  from public.landa_clothing_wholesale_business_sorted_pieces
  group by bale_id, category, grade;

create or replace view public.landa_clothing_wholesale_business_brand_piece_counts with (security_invoker = true) as
  select brand,
         sum(qty)::int as pieces,
         coalesce(sum(qty) filter (where grade = 'A'), 0)::int as a_pieces,
         max(created_at) as last_seen
  from public.landa_clothing_wholesale_business_sorted_pieces
  where brand is not null and brand <> ''
  group by brand;

-- ---------------------------------------------------------------------
-- Session / password
-- ---------------------------------------------------------------------

create or replace function public.landa_clothing_wholesale_business_session_is_valid() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.landa_clothing_wholesale_business_login_sessions s
    where s.token::text = coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-landa-session', '')
      and s.expires_at > now()
  )
$$;

create or replace function public.landa_clothing_wholesale_business_require_session() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.landa_clothing_wholesale_business_session_is_valid() then
    raise exception 'Locked: please log in again' using errcode = '28000';
  end if;
end $$;

create or replace function public.landa_clothing_wholesale_business_unlock_dashboard(p_password text, p_device text default '')
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare h text; t uuid;
begin
  select password_hash into h from public.landa_clothing_wholesale_business_access_passwords where id = 1;
  if h is null then
    raise exception 'No password has been set in the database yet';
  end if;
  if extensions.crypt(coalesce(p_password, ''), h) <> h then
    perform pg_sleep(1);
    raise exception 'Wrong password' using errcode = '28P01';
  end if;
  delete from public.landa_clothing_wholesale_business_login_sessions where expires_at < now();
  insert into public.landa_clothing_wholesale_business_login_sessions (device) values (left(coalesce(p_device, ''), 200)) returning token into t;
  return t;
end $$;

create or replace function public.landa_clothing_wholesale_business_logout_dashboard() returns void
language sql volatile security definer set search_path = public as $$
  delete from public.landa_clothing_wholesale_business_login_sessions
  where token::text = coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-landa-session', '')
$$;

-- ---------------------------------------------------------------------
-- Internal helpers (not callable from the browser)
-- ---------------------------------------------------------------------

create or replace function public.landa_clothing_wholesale_business_next_id(p_prefix text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v int;
begin
  insert into public.landa_clothing_wholesale_business_id_counters (prefix, last_value) values (p_prefix, 1)
  on conflict (prefix) do update set last_value = public.landa_clothing_wholesale_business_id_counters.last_value + 1
  returning last_value into v;
  return p_prefix || '-' || lpad(v::text, 3, '0');
end $$;

create or replace function public.landa_clothing_wholesale_business_write_log(p_message text, p_day date default null) returns void
language sql volatile security definer set search_path = public as $$
  insert into public.landa_clothing_wholesale_business_activity_log (happened_on, message)
  values (coalesce(p_day, public.landa_clothing_wholesale_business_today_karachi()), p_message)
$$;

create or replace function public.landa_clothing_wholesale_business_rs(p numeric) returns text
language sql immutable as $$ select 'Rs ' || to_char(round(coalesce(p, 0)), 'FM999,999,999,990') $$;

create or replace function public.landa_clothing_wholesale_business_put_pieces_in_stock(
  p_bale text, p_category text, p_grade text, p_qty int, p_source text, p_device text
) returns bigint language plpgsql volatile security definer set search_path = public as $$
declare st text; pid bigint;
begin
  select status into st from public.landa_clothing_wholesale_business_bales_received where id = p_bale for update;
  if st is null then raise exception 'Bale % not found', p_bale; end if;
  if st = 'sorted' then raise exception 'Bale % is already finished', p_bale; end if;
  update public.landa_clothing_wholesale_business_stock_items set qty = qty + p_qty, updated_at = now()
  where category = p_category and grade = p_grade;
  if not found then raise exception 'Unknown item % · %', p_category, p_grade; end if;
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
  update public.landa_clothing_wholesale_business_stock_items set qty = qty - r.qty, updated_at = now()
  where category = r.category and grade = r.grade;
  delete from public.landa_clothing_wholesale_business_sorted_pieces where id = r.id;
  return r.id;
end $$;

create or replace function public.landa_clothing_wholesale_business_touch_sync_ping() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.landa_clothing_wholesale_business_sync_pings (table_name, changed_at) values (tg_table_name, now())
  on conflict (table_name) do update set changed_at = excluded.changed_at;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Actions called by the dashboard (all need a valid login session)
-- ---------------------------------------------------------------------

create or replace function public.landa_clothing_wholesale_business_add_log_entry(p_message text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  perform public.landa_clothing_wholesale_business_write_log(p_message);
end $$;

create or replace function public.landa_clothing_wholesale_business_add_bale(
  p_date date, p_supplier text, p_type text, p_weight numeric, p_cost numeric
) returns text language plpgsql volatile security definer set search_path = public as $$
declare v text; d date := coalesce(p_date, public.landa_clothing_wholesale_business_today_karachi());
begin
  perform public.landa_clothing_wholesale_business_require_session();
  v := public.landa_clothing_wholesale_business_next_id('B');
  insert into public.landa_clothing_wholesale_business_bales_received (id, received_date, supplier, bale_type, weight_kg, cost)
  values (v, d, trim(p_supplier), trim(p_type), p_weight, coalesce(p_cost, 0));
  perform public.landa_clothing_wholesale_business_write_log(format('Bale %s received from %s (%s kg, %s)', v, trim(p_supplier), p_weight, public.landa_clothing_wholesale_business_rs(p_cost)), d);
  return v;
end $$;

create or replace function public.landa_clothing_wholesale_business_record_bulk_sorting(
  p_bale text, p_yields jsonb, p_finish boolean default true, p_date date default null
) returns int language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  for r in select * from jsonb_to_recordset(coalesce(p_yields, '[]'::jsonb)) as x(category text, grade text, qty int) loop
    if coalesce(r.qty, 0) > 0 then
      perform public.landa_clothing_wholesale_business_put_pieces_in_stock(p_bale, r.category, r.grade, r.qty, 'bulk', null);
      n := n + r.qty;
    end if;
  end loop;
  if n > 0 then
    perform public.landa_clothing_wholesale_business_write_log(format('%s pcs counted by hand into bale %s', n, p_bale), p_date);
  end if;
  if p_finish then
    perform public.landa_clothing_wholesale_business_finish_bale_sorting(p_bale, p_date);
  end if;
  return n;
end $$;

create or replace function public.landa_clothing_wholesale_business_finish_bale_sorting(p_bale text, p_date date default null)
returns void language plpgsql volatile security definer set search_path = public as $$
declare d date := coalesce(p_date, public.landa_clothing_wholesale_business_today_karachi()); total int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  update public.landa_clothing_wholesale_business_bales_received set status = 'sorted', sorted_date = d
  where id = p_bale and status <> 'sorted';
  if not found then raise exception 'Bale % not found or already finished', p_bale; end if;
  select coalesce(sum(qty), 0) into total from public.landa_clothing_wholesale_business_sorted_pieces where bale_id = p_bale;
  update public.landa_clothing_wholesale_business_live_sorting_session set bale_id = null, category = null, updated_at = now()
  where bale_id = p_bale;
  perform public.landa_clothing_wholesale_business_write_log(format('Bale %s finished — %s pcs sorted', p_bale, total), d);
end $$;

create or replace function public.landa_clothing_wholesale_business_record_one_piece(
  p_grade text, p_bale text default null, p_category text default null, p_brand text default null
) returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text; c text; pid bigint;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select bale_id, category into b, c from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  b := coalesce(p_bale, b);
  c := coalesce(p_category, c);
  if b is null or c is null then
    raise exception 'Pick a bale and category on the sorting screen first';
  end if;
  pid := public.landa_clothing_wholesale_business_put_pieces_in_stock(b, c, initcap(p_grade), 1, 'button', null);
  if nullif(trim(p_brand), '') is not null then
    update public.landa_clothing_wholesale_business_sorted_pieces set brand = trim(p_brand) where id = pid;
  end if;
  return pid;
end $$;

create or replace function public.landa_clothing_wholesale_business_undo_last_piece(p_bale text default null) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare b text;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select bale_id into b from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  return public.landa_clothing_wholesale_business_remove_last_piece(coalesce(p_bale, b));
end $$;

create or replace function public.landa_clothing_wholesale_business_create_order(
  p_customer text, p_date date, p_lines jsonb, p_paid numeric default 0
) returns text language plpgsql volatile security definer set search_path = public as $$
declare v text; r record; avail int; tot numeric; d date := coalesce(p_date, public.landa_clothing_wholesale_business_today_karachi());
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then raise exception 'An order needs at least one item'; end if;
  for r in
    select category, grade, sum(qty)::int as qty
    from jsonb_to_recordset(p_lines) as x(category text, grade text, qty int)
    group by category, grade
  loop
    select qty into avail from public.landa_clothing_wholesale_business_stock_items
    where category = r.category and grade = r.grade for update;
    if avail is null then raise exception 'Unknown item % · %', r.category, r.grade; end if;
    if r.qty is null or r.qty <= 0 then raise exception 'Every item needs a quantity'; end if;
    if avail < r.qty then raise exception 'Only % pcs of % · % in stock', avail, r.category, r.grade; end if;
  end loop;

  v := public.landa_clothing_wholesale_business_next_id('O');
  insert into public.landa_clothing_wholesale_business_customer_orders (id, order_date, customer_id, history)
  values (v, d, p_customer, jsonb_build_array(jsonb_build_object('s', 'new', 'd', d)));
  insert into public.landa_clothing_wholesale_business_customer_order_lines (order_id, category, grade, qty, price)
  select v, category, grade, qty, price
  from jsonb_to_recordset(p_lines) as x(category text, grade text, qty int, price numeric);
  update public.landa_clothing_wholesale_business_stock_items s set qty = s.qty - x.q, updated_at = now()
  from (select category, grade, sum(qty) as q from jsonb_to_recordset(p_lines) as y(category text, grade text, qty int) group by 1, 2) x
  where s.category = x.category and s.grade = x.grade;

  select sum(qty * price) into tot from public.landa_clothing_wholesale_business_customer_order_lines where order_id = v;
  update public.landa_clothing_wholesale_business_customer_orders set paid = least(greatest(coalesce(p_paid, 0), 0), tot) where id = v;
  perform public.landa_clothing_wholesale_business_write_log(format('Order %s for %s — %s', v,
    (select name from public.landa_clothing_wholesale_business_wholesale_customers where id = p_customer), public.landa_clothing_wholesale_business_rs(tot)), d);
  return v;
end $$;

create or replace function public.landa_clothing_wholesale_business_set_order_status(
  p_order text, p_status text, p_courier text default null, p_tracking text default null, p_date date default null
) returns void language plpgsql volatile security definer set search_path = public as $$
declare o record; d date := coalesce(p_date, public.landa_clothing_wholesale_business_today_karachi()); nxt text;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into o from public.landa_clothing_wholesale_business_customer_orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;
  if p_status = 'cancelled' then
    if o.status not in ('new', 'packed') then raise exception 'Only new or packed orders can be cancelled'; end if;
    update public.landa_clothing_wholesale_business_stock_items s set qty = s.qty + x.q, updated_at = now()
    from (select category, grade, sum(qty) as q from public.landa_clothing_wholesale_business_customer_order_lines where order_id = p_order group by 1, 2) x
    where s.category = x.category and s.grade = x.grade;
  else
    nxt := case o.status when 'new' then 'packed' when 'packed' then 'dispatched' when 'dispatched' then 'delivered' end;
    if nxt is distinct from p_status then
      raise exception 'Order % cannot go from % to %', p_order, o.status, p_status;
    end if;
  end if;
  update public.landa_clothing_wholesale_business_customer_orders set
    status = p_status,
    history = history || jsonb_build_array(jsonb_build_object('s', p_status, 'd', d)),
    courier = case when p_status = 'dispatched' then nullif(trim(p_courier), '') else courier end,
    tracking = case when p_status = 'dispatched' then nullif(trim(p_tracking), '') else tracking end,
    dispatch_date = case when p_status = 'dispatched' then d else dispatch_date end
  where id = p_order;
  perform public.landa_clothing_wholesale_business_write_log(format('Order %s → %s', p_order, initcap(p_status)), d);
end $$;

create or replace function public.landa_clothing_wholesale_business_add_payment(p_order text, p_amount numeric) returns void
language plpgsql volatile security definer set search_path = public as $$
declare tot numeric;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter an amount'; end if;
  select sum(qty * price) into tot from public.landa_clothing_wholesale_business_customer_order_lines where order_id = p_order;
  update public.landa_clothing_wholesale_business_customer_orders set paid = least(tot, paid + p_amount)
  where id = p_order and status <> 'cancelled';
  if not found then raise exception 'Order % not found', p_order; end if;
  perform public.landa_clothing_wholesale_business_write_log(format('%s received on %s', public.landa_clothing_wholesale_business_rs(p_amount), p_order));
end $$;

create or replace function public.landa_clothing_wholesale_business_save_customer(
  p_id text, p_name text, p_city text, p_phone text, p_limit numeric
) returns text language plpgsql volatile security definer set search_path = public as $$
declare v text := nullif(p_id, '');
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if v is null then
    v := public.landa_clothing_wholesale_business_next_id('C');
    insert into public.landa_clothing_wholesale_business_wholesale_customers (id, name, city, phone, credit_limit)
    values (v, trim(p_name), coalesce(trim(p_city), ''), coalesce(p_phone, ''), coalesce(p_limit, 0));
    perform public.landa_clothing_wholesale_business_write_log(format('New wholesaler %s (%s)', trim(p_name), v));
  else
    update public.landa_clothing_wholesale_business_wholesale_customers
    set name = trim(p_name), city = coalesce(trim(p_city), ''), phone = coalesce(p_phone, ''), credit_limit = coalesce(p_limit, 0)
    where id = v;
  end if;
  return v;
end $$;

create or replace function public.landa_clothing_wholesale_business_add_category(p_name text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare n text := trim(p_name);
begin
  perform public.landa_clothing_wholesale_business_require_session();
  insert into public.landa_clothing_wholesale_business_categories (name, sort_order)
  values (n, (select coalesce(max(sort_order), 0) + 1 from public.landa_clothing_wholesale_business_categories))
  on conflict (name) do nothing;
  insert into public.landa_clothing_wholesale_business_stock_items (category, grade, min_qty)
  values (n, 'A', 60), (n, 'B', 40), (n, 'C', 0), (n, 'Reject', 0)
  on conflict (category, grade) do nothing;
end $$;

create or replace function public.landa_clothing_wholesale_business_update_stock_item(
  p_category text, p_grade text, p_qty int, p_price numeric, p_min int
) returns void language plpgsql volatile security definer set search_path = public as $$
declare old int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select qty into old from public.landa_clothing_wholesale_business_stock_items where category = p_category and grade = p_grade for update;
  if old is null then raise exception 'Unknown item % · %', p_category, p_grade; end if;
  update public.landa_clothing_wholesale_business_stock_items set qty = p_qty, price = p_price, min_qty = p_min, updated_at = now()
  where category = p_category and grade = p_grade;
  if old <> p_qty then
    perform public.landa_clothing_wholesale_business_write_log(format('Stock count %s · %s: %s → %s', p_category, p_grade, old, p_qty));
  end if;
end $$;

create or replace function public.landa_clothing_wholesale_business_create_sensor_device(p_name text) returns json
language plpgsql volatile security definer set search_path = public, extensions as $$
declare v text; k text;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  v := public.landa_clothing_wholesale_business_next_id('D');
  k := encode(extensions.gen_random_bytes(16), 'hex');
  insert into public.landa_clothing_wholesale_business_sensor_devices (id, name, key_hash)
  values (v, trim(p_name), extensions.crypt(k, extensions.gen_salt('bf')));
  perform public.landa_clothing_wholesale_business_write_log(format('Sensor device %s (%s) added', v, trim(p_name)));
  return json_build_object('id', v, 'key', k);
end $$;

create or replace function public.landa_clothing_wholesale_business_wipe_all_business_data() returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  update public.landa_clothing_wholesale_business_live_sorting_session set bale_id = null, category = null, updated_at = now() where true;
  delete from public.landa_clothing_wholesale_business_sorted_pieces where true;
  delete from public.landa_clothing_wholesale_business_customer_order_lines where true;
  delete from public.landa_clothing_wholesale_business_customer_orders where true;
  delete from public.landa_clothing_wholesale_business_bales_received where true;
  delete from public.landa_clothing_wholesale_business_wholesale_customers where true;
  delete from public.landa_clothing_wholesale_business_activity_log where true;
  delete from public.landa_clothing_wholesale_business_id_counters where prefix in ('B', 'O', 'C');
  update public.landa_clothing_wholesale_business_stock_items set qty = 0, updated_at = now() where true;
  perform public.landa_clothing_wholesale_business_write_log('All bales, orders and wholesalers wiped — fresh start');
end $$;

-- ---------------------------------------------------------------------
-- Actions called by the ESP32 sensor box (device id + key, no login)
-- ---------------------------------------------------------------------

create or replace function public.landa_clothing_wholesale_business_check_sensor_device(p_device_id text, p_device_key text) returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare h text;
begin
  select key_hash into h from public.landa_clothing_wholesale_business_sensor_devices where id = p_device_id;
  if h is null or extensions.crypt(coalesce(p_device_key, ''), h) <> h then
    raise exception 'Unknown sensor device' using errcode = '28000';
  end if;
  update public.landa_clothing_wholesale_business_sensor_devices set last_seen = now() where id = p_device_id;
end $$;

create or replace function public.landa_clothing_wholesale_business_sensor_piece_counted(p_device_id text, p_device_key text, p_grade text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text; c text;
begin
  perform public.landa_clothing_wholesale_business_check_sensor_device(p_device_id, p_device_key);
  select bale_id, category into b, c from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  if b is null or c is null then
    raise exception 'No bale/category selected on the sorting screen';
  end if;
  return public.landa_clothing_wholesale_business_put_pieces_in_stock(b, c, initcap(p_grade), 1, 'sensor', p_device_id);
end $$;

create or replace function public.landa_clothing_wholesale_business_sensor_undo_piece(p_device_id text, p_device_key text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare b text;
begin
  perform public.landa_clothing_wholesale_business_check_sensor_device(p_device_id, p_device_key);
  select bale_id into b from public.landa_clothing_wholesale_business_live_sorting_session where id = 1;
  return public.landa_clothing_wholesale_business_remove_last_piece(b);
end $$;

-- ---------------------------------------------------------------------
-- Security: row level security, grants, realtime
-- ---------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'settings', 'categories', 'stock_items', 'bales_received', 'sorted_pieces',
    'wholesale_customers', 'customer_orders', 'customer_order_lines', 'activity_log',
    'live_sorting_session', 'sensor_devices'
  ] loop
    execute format('alter table public.landa_clothing_wholesale_business_%s enable row level security', t);
    execute format('drop policy if exists landa_clothing_wholesale_business_session_access on public.landa_clothing_wholesale_business_%s', t);
    execute format('create policy landa_clothing_wholesale_business_session_access on public.landa_clothing_wholesale_business_%s for all to anon, authenticated using (public.landa_clothing_wholesale_business_session_is_valid()) with check (public.landa_clothing_wholesale_business_session_is_valid())', t);
    execute format('grant select, insert, update, delete on public.landa_clothing_wholesale_business_%s to anon, authenticated', t);
    execute format('drop trigger if exists landa_clothing_wholesale_business_sync_ping on public.landa_clothing_wholesale_business_%s', t);
    execute format('create trigger landa_clothing_wholesale_business_sync_ping after insert or update or delete or truncate on public.landa_clothing_wholesale_business_%s for each statement execute function public.landa_clothing_wholesale_business_touch_sync_ping()', t);
  end loop;
end $$;

-- Locked tables: nothing from the browser, only through the functions above
alter table public.landa_clothing_wholesale_business_access_passwords enable row level security;
alter table public.landa_clothing_wholesale_business_login_sessions enable row level security;
alter table public.landa_clothing_wholesale_business_id_counters enable row level security;
revoke all on public.landa_clothing_wholesale_business_access_passwords, public.landa_clothing_wholesale_business_login_sessions, public.landa_clothing_wholesale_business_id_counters from anon, authenticated;

-- Sync pings: readable by anyone (contain only table names + times)
alter table public.landa_clothing_wholesale_business_sync_pings enable row level security;
drop policy if exists landa_clothing_wholesale_business_public_ping_read on public.landa_clothing_wholesale_business_sync_pings;
create policy landa_clothing_wholesale_business_public_ping_read on public.landa_clothing_wholesale_business_sync_pings for select to anon, authenticated using (true);
revoke all on public.landa_clothing_wholesale_business_sync_pings from anon, authenticated;
grant select on public.landa_clothing_wholesale_business_sync_pings to anon, authenticated;

grant select on public.landa_clothing_wholesale_business_bale_yield_totals, public.landa_clothing_wholesale_business_brand_piece_counts to anon, authenticated;

revoke execute on function
  public.landa_clothing_wholesale_business_next_id(text),
  public.landa_clothing_wholesale_business_write_log(text, date),
  public.landa_clothing_wholesale_business_put_pieces_in_stock(text, text, text, int, text, text),
  public.landa_clothing_wholesale_business_remove_last_piece(text),
  public.landa_clothing_wholesale_business_touch_sync_ping(),
  public.landa_clothing_wholesale_business_check_sensor_device(text, text)
from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'landa_clothing_wholesale_business_sync_pings'
  ) then
    alter publication supabase_realtime add table public.landa_clothing_wholesale_business_sync_pings;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Email alerts (same as 002_email_alerts.sql)
-- ---------------------------------------------------------------------

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

-- ---------------------------------------------------------------------
-- Category chosen in the piece popup (same as 003_category_in_popup.sql)
-- ---------------------------------------------------------------------

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

-- ---------------------------------------------------------------------
-- Brand mode (same as 004_brand_mode.sql)
-- ---------------------------------------------------------------------

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

-- ---------------------------------------------------------------------
-- Saved brand list (same as 005_brand_list.sql)
-- ---------------------------------------------------------------------

alter table public.landa_clothing_wholesale_business_settings
  add column if not exists brand_list text[] not null default '{}';

-- Start the list with every brand already used while sorting
update public.landa_clothing_wholesale_business_settings s
set brand_list = coalesce((
  select array_agg(b order by b) from (
    select distinct brand as b from public.landa_clothing_wholesale_business_sorted_pieces
    where brand is not null and brand <> '' and brand <> 'No brand'
  ) x), '{}')
where s.id = 1 and s.brand_list = '{}';

-- ---------------------------------------------------------------------
-- Edit and delete everywhere (same as 006_edit_delete.sql)
-- ---------------------------------------------------------------------

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

-- ---------------------------------------------------------------------
-- Set / change the dashboard password (run separately, replace the text):
--
-- insert into public.landa_clothing_wholesale_business_access_passwords (id, password_hash)
-- values (1, extensions.crypt('YOUR-PASSWORD-HERE', extensions.gen_salt('bf')))
-- on conflict (id) do update set password_hash = excluded.password_hash, updated_at = now();
--
-- To log every device out:  delete from public.landa_clothing_wholesale_business_login_sessions;
-- ---------------------------------------------------------------------
