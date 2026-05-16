-- Track how spot amenity fields were produced (baseline, community, or web research).

alter table public.spots
    add column if not exists enrichment_source text not null default 'baseline',
    add column if not exists enrichment_review_count integer not null default 0;

comment on column public.spots.enrichment_source is
    'baseline | community_reviews | web_search';

alter table public.spots
    add constraint spots_enrichment_source_check
    check (enrichment_source in ('baseline', 'community_reviews', 'web_search'));
