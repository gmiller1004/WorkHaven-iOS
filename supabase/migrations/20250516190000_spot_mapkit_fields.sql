-- MapKit metadata from discovery (phone, website, POI category).

alter table public.spots
    add column if not exists phone text,
    add column if not exists website text,
    add column if not exists poi_category text;

comment on column public.spots.phone is 'Phone number from Apple Maps at discovery time';
comment on column public.spots.website is 'Website URL from Apple Maps at discovery time';
comment on column public.spots.poi_category is 'MKPointOfInterestCategory raw value when available';
