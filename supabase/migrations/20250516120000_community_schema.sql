-- WorkHaven community schema: canonical spots, shared UGC, server-side enrichment.

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    display_name text,
    avatar_url text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Profiles are viewable by authenticated users"
    on public.profiles for select
    to authenticated
    using (true);

create policy "Users can update own profile"
    on public.profiles for update
    to authenticated
    using (auth.uid() = id)
    with check (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- Spots (canonical, Grok-enriched on server)
-- ---------------------------------------------------------------------------
create table public.spots (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    address text not null,
    latitude double precision not null,
    longitude double precision not null,
    geog extensions.geography(point, 4326) not null,
    type text not null default 'unknown',
    wifi_rating smallint not null default 3 check (wifi_rating between 1 and 5),
    noise_rating text not null default 'Medium',
    outlets boolean not null default false,
    tips text not null default 'No tips available',
    enriched_at timestamptz,
    enrichment_version integer not null default 1,
    external_place_id text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index spots_geog_idx on public.spots using gist (geog);
create index spots_name_address_idx on public.spots (lower(name), lower(address));

create or replace function public.spots_set_geog()
returns trigger
language plpgsql
as $$
begin
    new.geog := extensions.st_setsrid(extensions.st_makepoint(new.longitude, new.latitude), 4326)::extensions.geography;
    new.updated_at := now();
    return new;
end;
$$;

create trigger spots_set_geog_trigger
    before insert or update of latitude, longitude on public.spots
    for each row
    execute function public.spots_set_geog();

alter table public.spots enable row level security;

create policy "Spots are readable by authenticated users"
    on public.spots for select
    to authenticated
    using (true);

-- Inserts/updates only via service role (edge functions).

-- ---------------------------------------------------------------------------
-- Reviews, photos, tips, favorites
-- ---------------------------------------------------------------------------
create table public.spot_reviews (
    id uuid primary key default gen_random_uuid(),
    spot_id uuid not null references public.spots (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    wifi smallint not null check (wifi between 1 and 5),
    noise text not null,
    plugs boolean not null,
    tip text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (spot_id, user_id)
);

create table public.spot_photos (
    id uuid primary key default gen_random_uuid(),
    spot_id uuid not null references public.spots (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    storage_path text not null,
    likes integer not null default 0 check (likes >= 0),
    dislikes integer not null default 0 check (dislikes >= 0),
    created_at timestamptz not null default now()
);

create table public.spot_tips (
    id uuid primary key default gen_random_uuid(),
    spot_id uuid not null references public.spots (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    text text not null,
    likes integer not null default 0 check (likes >= 0),
    dislikes integer not null default 0 check (dislikes >= 0),
    created_at timestamptz not null default now()
);

create table public.favorites (
    user_id uuid not null references auth.users (id) on delete cascade,
    spot_id uuid not null references public.spots (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, spot_id)
);

alter table public.spot_reviews enable row level security;
alter table public.spot_photos enable row level security;
alter table public.spot_tips enable row level security;
alter table public.favorites enable row level security;

-- Community writers: signed-in (non-anonymous) users only.
create or replace function public.is_community_writer()
returns boolean
language sql
stable
as $$
    select coalesce(auth.jwt() ->> 'is_anonymous', 'true') = 'false';
$$;

create policy "Reviews are readable by authenticated users"
    on public.spot_reviews for select to authenticated using (true);

create policy "Community writers insert reviews"
    on public.spot_reviews for insert to authenticated
    with check (public.is_community_writer() and auth.uid() = user_id);

create policy "Community writers update own reviews"
    on public.spot_reviews for update to authenticated
    using (public.is_community_writer() and auth.uid() = user_id)
    with check (public.is_community_writer() and auth.uid() = user_id);

create policy "Community writers delete own reviews"
    on public.spot_reviews for delete to authenticated
    using (public.is_community_writer() and auth.uid() = user_id);

create policy "Photos are readable by authenticated users"
    on public.spot_photos for select to authenticated using (true);

create policy "Community writers insert photos"
    on public.spot_photos for insert to authenticated
    with check (public.is_community_writer() and auth.uid() = user_id);

create policy "Community writers update own photos"
    on public.spot_photos for update to authenticated
    using (public.is_community_writer() and auth.uid() = user_id);

create policy "Community writers delete own photos"
    on public.spot_photos for delete to authenticated
    using (public.is_community_writer() and auth.uid() = user_id);

create policy "Tips are readable by authenticated users"
    on public.spot_tips for select to authenticated using (true);

create policy "Community writers insert tips"
    on public.spot_tips for insert to authenticated
    with check (public.is_community_writer() and auth.uid() = user_id);

create policy "Community writers update own tips"
    on public.spot_tips for update to authenticated
    using (public.is_community_writer() and auth.uid() = user_id);

create policy "Community writers delete own tips"
    on public.spot_tips for delete to authenticated
    using (public.is_community_writer() and auth.uid() = user_id);

create policy "Users read own favorites"
    on public.favorites for select to authenticated
    using (auth.uid() = user_id);

create policy "Community writers manage favorites"
    on public.favorites for all to authenticated
    using (public.is_community_writer() and auth.uid() = user_id)
    with check (public.is_community_writer() and auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Auth: auto-create profile
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name)
    values (
        new.id,
        coalesce(new.raw_user_meta_data ->> 'full_name', 'WorkHaven User')
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Nearby spots RPC
-- ---------------------------------------------------------------------------
create or replace function public.nearby_spots(
    p_lat double precision,
    p_lng double precision,
    p_radius_meters double precision default 32186.88
)
returns setof public.spots
language sql
stable
security invoker
as $$
    select s.*
    from public.spots s
    where extensions.st_dwithin(
        s.geog,
        extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
        p_radius_meters
    )
    order by extensions.st_distance(
        s.geog,
        extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography
    );
$$;

grant execute on function public.nearby_spots(double precision, double precision, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: spot photos
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('spot-photos', 'spot-photos', true)
on conflict (id) do update set public = true;

create policy "Spot photos are publicly readable"
    on storage.objects for select
    using (bucket_id = 'spot-photos');

create policy "Community writers upload spot photos"
    on storage.objects for insert to authenticated
    with check (
        bucket_id = 'spot-photos'
        and public.is_community_writer()
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "Community writers update own spot photos"
    on storage.objects for update to authenticated
    using (
        bucket_id = 'spot-photos'
        and public.is_community_writer()
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "Community writers delete own spot photos"
    on storage.objects for delete to authenticated
    using (
        bucket_id = 'spot-photos'
        and public.is_community_writer()
        and (storage.foldername(name))[1] = auth.uid()::text
    );
