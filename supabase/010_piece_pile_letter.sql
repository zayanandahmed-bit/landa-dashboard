-- =====================================================================
-- Landa Clothing Wholesale Business — piece barcodes start with their pile
-- A-<batch>-01 (A good), W-... (Washing), M-... (Mending), D-... (Damaged),
-- so you know which pile each sticker goes on. Only changes how NEW piece
-- codes are made; existing stickers keep working. Run once in the Supabase
-- SQL editor (safe to re-run).
-- =====================================================================

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
        pc := left(conds[i], 1) || '-' || c || '-' || lpad(n::text, width, '0');   -- A- / W- / M- / D- first: which pile it goes on
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
