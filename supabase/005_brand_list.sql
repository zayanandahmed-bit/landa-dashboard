-- =====================================================================
-- Landa Clothing Wholesale Business — saved brand list
-- Brands you add in Settings show up as a dropdown / buttons on the
-- sorting screen. Stored in the settings row (no new table).
-- Run once in the Supabase SQL editor (safe to re-run).
-- =====================================================================

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
