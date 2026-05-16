# WorkHaven Supabase

Community backend for canonical spots, shared reviews/photos, and server-side Grok enrichment.

## Setup

1. **Dashboard → Authentication → Providers**
   - Enable **Anonymous sign-ins**
   - Enable **Apple** (for posting reviews/photos)

2. **Secrets** (Dashboard → Edge Functions → Secrets, or CLI):
   ```bash
   supabase secrets set GROK_API_KEY=your-xai-key
   ```

3. **Deploy** (from repo root):
   ```bash
   supabase db push
   supabase functions deploy discover-enrich
   ```

   With GitHub integration, pushing `main` applies migrations under `supabase/migrations/`.

## iOS app keys

Add to `wh/Secrets.xcconfig` (see `Secrets.xcconfig.example`):

```
SUPABASE_URL = https://taxvfpiaplablxurktza.supabase.co
SUPABASE_ANON_KEY = your-anon-key
```

Expose in `Info.plist` as `SUPABASE_URL` and `SUPABASE_ANON_KEY` (same pattern as `GROK_API_KEY`).

## Architecture

| Piece | Role |
|-------|------|
| `spots` | Canonical venues + Grok enrichment cache |
| `spot_reviews`, `spot_photos`, `spot_tips` | Community UGC (writers = non-anonymous) |
| `nearby_spots` RPC | Geo query for the app |
| `discover-enrich` | MKLocalSearch results → match/create → Grok once per spot |
