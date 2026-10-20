-- =====================================================================
-- Landa Clothing Wholesale Business — batch code + a barcode per piece
-- A batch (e.g. AKPFJ02102026W30-64) holds the details entered at the start.
-- Each piece gets its own barcode (AKPFJ02102026W30-64-01 ... -64) linked to
-- the batch. Pieces start with a condition from the counts (A / Washing /
-- Mending / Damaged); scanning a piece updates that piece AND its batch.
-- Adds columns only (still 16 tables). Run once in the Supabase SQL editor
-- (safe to re-run).
-- =====================================================================

alter table public.landa_clothing_wholesale_business_tracked_barcode_tags
  add column if not exists batch_code text
    references public.landa_clothing_wholesale_business_tracked_barcode_tags(code) on update cascade on delete cascade,
  add column if not exists condition text check (condition in ('A', 'Washing', 'Mending', 'Damaged')),
  add column if not exists original_condition text check (original_condition in ('A', 'Washing', 'Mending', 'Damaged'));
create index if not exists landa_clothing_wholesale_business_tags_batch_idx
  on public.landa_clothing_wholesale_business_tracked_barcode_tags (batch_code);

-- allow kind = 'batch'
do $$
declare c text;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.landa_clothing_wholesale_business_tracked_barcode_tags'::regclass
      and contype = 'c' and pg_get_constraintdef(oid) ilike '%kind%'
  loop
    execute format('alter table public.landa_clothing_wholesale_business_tracked_barcode_tags drop constraint %I', c);
  end loop;
end $$;
alter table public.landa_clothing_wholesale_business_tracked_barcode_tags
  add constraint landa_clothing_wholesale_business_tags_kind_ck check (kind in ('bundle', 'bale', 'order', 'item', 'batch'));

-- lots made before this update become batches
update public.landa_clothing_wholesale_business_tracked_barcode_tags
set kind = 'batch' where product_type is not null and batch_code is null and kind = 'bundle';

-- Create a batch (+ optionally one barcode per piece). Returns {"batch": code, "pieces": [codes]}
drop function if exists public.landa_clothing_wholesale_business_create_lot_tag(text, text, text, date, text, int, int, int, int, text, text);
create or replace function public.landa_clothing_wholesale_business_create_lot_tag(
  p_code text, p_brand text, p_type text, p_date date, p_supplier text,
  p_a int, p_washing int, p_mending int, p_damaged int, p_stage text, p_location text, p_make_pieces boolean
) returns json language plpgsql volatile security definer set search_path = public as $$
declare base text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')); c text; k int := 1;
        st text := coalesce(nullif(trim(p_stage), ''), 'Received'); lc text := coalesce(trim(p_location), '');
        conds text[] := array['A', 'Washing', 'Mending', 'Damaged'];
        ns int[] := array[coalesce(p_a, 0), coalesce(p_washing, 0), coalesce(p_mending, 0), coalesce(p_damaged, 0)];
        tot int; width int; n int := 0; pc text; pieces text[] := '{}';
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if base !~ '^[A-Z0-9-]{3,40}$' then raise exception 'The item code can only use letters, numbers and - (3 to 40 characters)'; end if;
  if nullif(trim(p_brand), '') is null or nullif(trim(p_type), '') is null or nullif(trim(p_supplier), '') is null then
    raise exception 'Brand, product type and supplier are needed';
  end if;
  if least(ns[1], ns[2], ns[3], ns[4]) < 0 then raise exception 'Counts cannot be negative'; end if;
  tot := ns[1] + ns[2] + ns[3] + ns[4];
  if p_make_pieces and tot > 2000 then raise exception 'Up to 2000 piece barcodes per batch'; end if;
  c := base;
  while exists (select 1 from public.landa_clothing_wholesale_business_tracked_barcode_tags where code = c) loop
    k := k + 1; c := base || '-' || k;
  end loop;
  insert into public.landa_clothing_wholesale_business_tracked_barcode_tags
    (code, label, kind, brand, product_type, supplier, lot_date, count_a, count_washing, count_mending, count_damaged, qty, stage, location, scans)
  values (c, trim(p_brand) || ' ' || trim(p_type), 'batch', trim(p_brand), trim(p_type), trim(p_supplier), p_date,
    ns[1], ns[2], ns[3], ns[4], tot, st, lc,
    jsonb_build_array(jsonb_build_object('at', now(), 'stage', st, 'location', lc,
      'note', case when p_make_pieces then format('Batch created with %s piece barcodes', tot) else 'Batch created' end)));
  if p_make_pieces then
    width := greatest(2, length(tot::text));
    for i in 1..4 loop
      for j in 1..ns[i] loop
        n := n + 1;
        pc := c || '-' || lpad(n::text, width, '0');
        insert into public.landa_clothing_wholesale_business_tracked_barcode_tags
          (code, label, kind, batch_code, brand, product_type, supplier, lot_date, qty, condition, original_condition, stage, location, scans)
        values (pc, trim(p_brand) || ' ' || trim(p_type), 'item', c, trim(p_brand), trim(p_type), trim(p_supplier), p_date, 1,
          conds[i], conds[i], st, lc,
          jsonb_build_array(jsonb_build_object('at', now(), 'stage', st, 'location', lc, 'condition', conds[i], 'note', 'Label created · ' || conds[i])));
        pieces := pieces || pc;
      end loop;
    end loop;
  end if;
  perform public.landa_clothing_wholesale_business_write_log(format('Batch %s created (%s %s from %s, %s pcs%s)', c, trim(p_brand), trim(p_type), trim(p_supplier), tot,
    case when p_make_pieces then ', with piece barcodes' else '' end));
  return json_build_object('batch', c, 'pieces', to_json(pieces));
end $$;

-- Scan one piece: change its condition / step / place. Its batch is updated too.
create or replace function public.landa_clothing_wholesale_business_update_piece_tag(
  p_code text, p_condition text, p_stage text, p_location text, p_note text
) returns void language plpgsql volatile security definer set search_path = public as $$
declare t record; nc text; st text; lc text; msg text;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  select * into t from public.landa_clothing_wholesale_business_tracked_barcode_tags where code = upper(trim(p_code)) for update;
  if not found then raise exception 'No label with code %', p_code; end if;
  if t.batch_code is null then raise exception '% is not a piece barcode', t.code; end if;
  nc := coalesce(nullif(trim(p_condition), ''), t.condition);
  if nc is not null and nc not in ('A', 'Washing', 'Mending', 'Damaged') then raise exception 'Unknown condition %', nc; end if;
  st := coalesce(nullif(trim(p_stage), ''), t.stage);
  lc := coalesce(nullif(trim(p_location), ''), t.location);
  msg := concat_ws(' · ',
    case when nc is distinct from t.condition then coalesce(t.condition, '—') || ' → ' || nc end,
    case when st is distinct from t.stage then st end,
    case when lc is distinct from t.location then '📍 ' || lc end,
    nullif(trim(p_note), ''));
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    condition = nc, stage = st, location = lc, note = coalesce(trim(p_note), ''), last_scan_at = now(),
    scans = scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', st, 'location', lc, 'condition', nc, 'note', coalesce(nullif(msg, ''), 'Scanned')))
  where code = t.code;
  -- the batch: always "last updated now"; condition changes go into its history
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    last_scan_at = now(),
    scans = case when nc is distinct from t.condition
      then scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', stage, 'location', location, 'piece', t.code,
        'note', format('Piece %s: %s → %s', t.code, coalesce(t.condition, '—'), nc)))
      else scans end
  where code = t.batch_code;
end $$;

-- Move every piece of a batch to the same step / place (used when the whole batch moves)
create or replace function public.landa_clothing_wholesale_business_move_batch_pieces(
  p_batch text, p_stage text, p_location text, p_note text
) returns int language plpgsql volatile security definer set search_path = public as $$
declare k int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    stage = coalesce(nullif(trim(p_stage), ''), stage), location = coalesce(nullif(trim(p_location), ''), location),
    last_scan_at = now(),
    scans = scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', coalesce(nullif(trim(p_stage), ''), stage),
      'location', coalesce(nullif(trim(p_location), ''), location), 'condition', condition,
      'note', 'Moved with batch' || case when nullif(trim(p_note), '') is not null then ' · ' || trim(p_note) else '' end))
  where batch_code = upper(trim(p_batch));
  get diagnostics k = row_count;
  return k;
end $$;

-- Treatment on a whole batch: "Washing: 30 flagged, 26 recovered".
-- If the batch has piece barcodes, that many Washing pieces are switched to A (or back).
create or replace function public.landa_clothing_wholesale_business_record_lot_treatment(
  p_code text, p_treatment text, p_flagged int, p_recovered int, p_note text
) returns void language plpgsql volatile security definer set search_path = public as $$
declare tr text := lower(trim(p_treatment)); cond text; bc text := upper(trim(p_code)); msg text;
        npieces int; nflag int; cur int; delta int;
begin
  perform public.landa_clothing_wholesale_business_require_session();
  if tr not in ('washing', 'mending') then raise exception 'Pick Washing or Mending'; end if;
  cond := initcap(tr);
  if coalesce(p_flagged, -1) < 0 or coalesce(p_recovered, -1) < 0 then raise exception 'Enter how many were flagged and how many were recovered'; end if;
  if p_recovered > p_flagged then raise exception 'Recovered (%) cannot be more than originally flagged (%)', p_recovered, p_flagged; end if;
  perform 1 from public.landa_clothing_wholesale_business_tracked_barcode_tags where code = bc for update;
  if not found then raise exception 'No label with code %', p_code; end if;
  select count(*) into npieces from public.landa_clothing_wholesale_business_tracked_barcode_tags where batch_code = bc;
  if npieces > 0 then
    select count(*) filter (where original_condition = cond), count(*) filter (where original_condition = cond and condition = 'A')
      into nflag, cur from public.landa_clothing_wholesale_business_tracked_barcode_tags where batch_code = bc;
    if p_recovered > nflag then raise exception 'This batch only has % % pieces', nflag, lower(cond); end if;
    delta := p_recovered - cur;
    if delta > 0 then
      update public.landa_clothing_wholesale_business_tracked_barcode_tags set condition = 'A', last_scan_at = now(),
        scans = scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', stage, 'location', location, 'condition', 'A', 'note', cond || ' → A (recovered, batch update)'))
      where code in (select code from public.landa_clothing_wholesale_business_tracked_barcode_tags
                     where batch_code = bc and original_condition = cond and condition = cond order by code limit delta);
    elsif delta < 0 then
      update public.landa_clothing_wholesale_business_tracked_barcode_tags set condition = cond, last_scan_at = now(),
        scans = scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', stage, 'location', location, 'condition', cond, 'note', 'A → ' || cond || ' (batch correction)'))
      where code in (select code from public.landa_clothing_wholesale_business_tracked_barcode_tags
                     where batch_code = bc and original_condition = cond and condition = 'A' order by code desc limit -delta);
    end if;
  end if;
  msg := format('%s: %s flagged, %s recovered%s', cond, p_flagged, p_recovered, case when nullif(trim(p_note), '') is not null then ' — ' || trim(p_note) else '' end);
  update public.landa_clothing_wholesale_business_tracked_barcode_tags set
    washing_flagged = case when tr = 'washing' then p_flagged else washing_flagged end,
    washing_recovered = case when tr = 'washing' then p_recovered else washing_recovered end,
    mending_flagged = case when tr = 'mending' then p_flagged else mending_flagged end,
    mending_recovered = case when tr = 'mending' then p_recovered else mending_recovered end,
    note = msg, last_scan_at = now(),
    scans = scans || jsonb_build_array(jsonb_build_object('at', now(), 'stage', stage, 'location', location, 'note', msg,
      'treatment', tr, 'flagged', p_flagged, 'recovered', p_recovered))
  where code = bc;
end $$;
