-- Ensure baseline spots never store a false "no outlets" default.

update public.spots
set outlets = null
where enrichment_source = 'baseline'
   or (enrichment_source is null and outlets = false);
