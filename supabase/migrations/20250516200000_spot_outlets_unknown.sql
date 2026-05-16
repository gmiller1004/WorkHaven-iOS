-- outlets NULL = unknown (not surveyed). true/false = known availability.

alter table public.spots
    alter column outlets drop not null,
    alter column outlets drop default;

comment on column public.spots.outlets is
    'NULL = unknown; true/false = known outlet availability';

-- Baseline listings should not imply "no outlets"
update public.spots
set outlets = null
where enrichment_source = 'baseline' or enrichment_source is null;
