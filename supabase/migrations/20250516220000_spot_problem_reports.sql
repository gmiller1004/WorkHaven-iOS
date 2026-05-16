-- User-reported problems with spot listings (research errors, closures, etc.).

create table public.spot_problem_reports (
    id uuid primary key default gen_random_uuid(),
    spot_id uuid not null references public.spots (id) on delete cascade,
    user_id uuid references auth.users (id) on delete set null,
    category text not null,
    details text not null default '',
    status text not null default 'open',
    created_at timestamptz not null default now(),
    constraint spot_problem_reports_category_check check (
        category in (
            'out_of_business',
            'outlets_listed_but_none',
            'outlets_missing_but_listed',
            'wifi_listed_but_none',
            'wifi_overrated',
            'noise_inaccurate',
            'wrong_address',
            'other'
        )
    ),
    constraint spot_problem_reports_status_check check (
        status in ('open', 'reviewed', 'resolved')
    )
);

create index spot_problem_reports_spot_id_idx on public.spot_problem_reports (spot_id);
create index spot_problem_reports_status_idx on public.spot_problem_reports (status);

alter table public.spot_problem_reports enable row level security;

create policy "Authenticated users can submit problem reports"
    on public.spot_problem_reports for insert
    to authenticated
    with check (auth.uid() = user_id);

-- Reads reserved for service role / admin review (no public select).
