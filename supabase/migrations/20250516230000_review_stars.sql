-- Explicit 1–5 star rating from users (separate from WiFi/noise/outlet fields).

alter table public.spot_reviews
    add column if not exists stars smallint
    check (stars is null or (stars between 1 and 5));

comment on column public.spot_reviews.stars is
    'User overall rating 1-5; distinct from wifi/noise/plugs amenity fields';
