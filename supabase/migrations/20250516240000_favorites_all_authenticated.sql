-- Allow any authenticated user (including anonymous) to manage their own favorites.

drop policy if exists "Community writers manage favorites" on public.favorites;

create policy "Users manage own favorites"
    on public.favorites for all to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
