-- =====================================================================
-- Landa Clothing Wholesale Business — barcode lots (the owner's sheet)
-- Create: Brand, Product type, Date, Supplier, A / Washing / Mending / Damaged
-- -> a readable code like AKPFJ02102026W30-64 that gets printed as a barcode.
-- Scan: move it along the journey, or record a treatment (Washing / Mending):
-- originally flagged vs recovered.
-- Adds columns only (still 16 tables). Run once in the Supabase SQL editor
-- (safe to re-run).
-- =====================================================================

alter table public.landa_clothing_wholesale_business_tracked_barcode_tags
  add column if not exists product_type text,
  add column if not exists supplier text,
  add column if not exists lot_date date,
  add column if not exists count_a int not null default 0 check (count_a >= 0),
  add column if not exists count_washing int not null default 0 check (count_washing >= 0),
  add column if not exists count_mending int not null default 0 check (count_mending >= 0),
  add column if not exists count_damaged int not null default 0 check (count_damaged >= 0),
  add column if not exists washing_flagged int check (washing_flagged >= 0),
  add column if not exists washing_recovered int check (washing_recovered >= 0),
  add column if not exists mending_flagged int check (mending_flagged >= 0),
  add column if not exists mending_recovered int check (mending_recovered >= 0);

-- Save a new lot. If the code is already taken, -2, -3 ... is added.
create or replace function public.landa_clothing_wholesale_business_create_lot_tag(
  p_code text, p_brand text, p_type text, p_date date, p_supplier text,
  p_a int, p_washing int, p_mending int, p_damaged int, p_stage text, p_location text
) returns text language plpgsql volatile security definer set search_path = public as $$
declare base text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')); c text; k int := 1;
        st text := coalesce(nullif(trim(p_stage), ''), 'Received'); lc text := coalesce(trim(p_location), '');
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if base !~ '^[A-Z0-9-]{3,40}$' then raise exception 'The item code can only use letters, numbers and - (3 to 40 characters)'; end if;
  if nullif(trim(p_brand), '') is null or nullif(trim(p_type), '') is null or nullif(trim(p_supplier), '') is null then
    raise exception 'Brand, product type and supplier are needed';
  end if;
  if least(coalesce(p_a, 0), coalesce(p_washing, 0), coalesce(p_mending, 0), coalesce(p_damaged, 0)) < 0 then raise exception 'Counts cannot be negative'; end if;
  c := base;
  while exists (select 1 from public.landa_clothing_wholesale_business_tracked_barcode_tags where code = c) loop
    k := k + 1; c := base || '-' || k;
  end loop;
  insert into public.landa_clothing_wholesale_business_tracked_barcode_tags
    (code, label, kind, brand, product_type, supplier, lot_date, count_a, count_washing, count_mending, count_damaged, qty, stage, location, scans)
  values (c, trim(p_brand) || ' ' || trim(p_type), 'bundle', trim(p_brand), trim(p_type), trim(p_supplier), p_date,
    coalesce(p_a, 0), coalesce(p_washing, 0), coalesce(p_mending, 0), coalesce(p_damaged, 0),
    coalesce(p_a, 0) + coalesce(p_washing, 0) + coalesce(p_mending, 0) + coalesce(p_damaged, 0), st, lc,
    jsonb_build_array(jsonb_build_object('at', now(), 'stage', st, 'location', lc, 'note', 'Label created')));
  perform public.landa_clothing_wholesale_business_write_log(format('Barcode %s created (%s %s from %s)', c, trim(p_brand), trim(p_type), trim(p_supplier)));
  return c;
end $$;

create or replace function public.landa_clothing_wholesale_business_update_lot_tag(
  p_code text, p_brand text, p_type text, p_date date, p_supplier text,
  p_a int, p_washing int, p_mending int, p_damaged int
) returns void language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if least(coalesce(p_a, 0), coalesce(p_washing, 0), coalesce(p_mending, 0), coalesce(p_damaged, 0)) < 0 then raise exception 'Counts cannot be negative'; end if;
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    brand = nullif(trim(p_brand), ''), product_type = nullif(trim(p_type), ''), lot_date = p_date, supplier = nullif(trim(p_supplier), ''),
    label = trim(coalesce(p_brand, '') || ' ' || coalesce(p_type, '')),
    count_a = coalesce(p_a, 0), count_washing = coalesce(p_washing, 0), count_mending = coalesce(p_mending, 0), count_damaged = coalesce(p_damaged, 0),
    qty = coalesce(p_a, 0) + coalesce(p_washing, 0) + coalesce(p_mending, 0) + coalesce(p_damaged, 0)
  where code = upper(trim(p_code));
  if not found then raise exception 'No label with code %', p_code; end if;
end $$;

-- A treatment result: e.g. Washing, 30 originally flagged, 26 recovered
create or replace function public.landa_clothing_wholesale_business_record_lot_treatment(
  p_code text, p_treatment text, p_flagged int, p_recovered int, p_note text
) returns void language plpgsql volatile security definer set search_path = public as $$
declare tr text := lower(trim(p_treatment)); msg text;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if tr not in ('washing', 'mending') then raise exception 'Pick Washing or Mending'; end if;
  if coalesce(p_flagged, -1) < 0 or coalesce(p_recovered, -1) < 0 then raise exception 'Enter how many were flagged and how many were recovered'; end if;
  if p_recovered > p_flagged then raise exception 'Recovered (%) cannot be more than originally flagged (%)', p_recovered, p_flagged; end if;
  msg := format('%s: %s flagged, %s recovered%s', initcap(tr), p_flagged, p_recovered, case when nullif(trim(p_note), '') is not null then ' — ' || trim(p_note) else '' end);
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    washing_flagged = case when tr = 'washing' then p_flagged else washing_flagged end,
    washing_recovered = case when tr = 'washing' then p_recovered else washing_recovered end,
    mending_flagged = case when tr = 'mending' then p_flagged else mending_flagged end,
    mending_recovered = case when tr = 'mending' then p_recovered else mending_recovered end,
    note = msg, last_scan_at = now(),
    scans = scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', stage, 'location', location, 'note', msg,
      'treatment', tr, 'flagged', p_flagged, 'recovered', p_recovered))
  where code = upper(trim(p_code));
  if not found then raise exception 'No label with code %', p_code; end if;
end $$;
