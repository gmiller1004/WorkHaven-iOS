# WorkHaven Supabase

Community backend for canonical spots, shared reviews/photos, and server-side enrichment.

## Setup

1. **Dashboard → Authentication → Providers**
   - Enable **Anonymous sign-ins** (read spots and community UGC)
   - Enable **Apple** (for posting reviews/photos/tips)
   - Under Apple: add your app's **Services ID**, **Key ID**, **Team ID**, and `.p8` key from Apple Developer
   - Enable **Automatic linking** of anonymous users to Apple sign-in (so the same device keeps its session when upgrading from anonymous)

2. **Xcode**
   - Target → Signing & Capabilities → **Sign in with Apple** (entitlement is in `wh/wh.entitlements`)

3. **Secrets** (Dashboard → Edge Functions → Secrets, or CLI):
   ```bash
   supabase secrets set OPENROUTER_API_KEY=your-openrouter-key
   supabase secrets set OPENROUTER_RESEARCH_MODEL=google/gemini-2.0-flash-lite
   ```

4. **Deploy** (from repo root):
   ```bash
   supabase db push
   supabase functions deploy discover-enrich
   supabase functions deploy research-spot
   ```

   With GitHub integration, pushing `main` applies migrations under `supabase/migrations/`.

## iOS app keys

Add to `wh/Secrets.xcconfig` (see `Secrets.xcconfig.example`):

```
SUPABASE_URL = https://taxvfpiaplablxurktza.supabase.co
SUPABASE_ANON_KEY = your-anon-key
```

Expose in `Info.plist` as `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

## Architecture

| Piece | Role |
|-------|------|
| `spots` | Canonical venues; amenity fields from baseline, community reviews, or on-demand web research |
| `spot_reviews`, `spot_photos`, `spot_tips` | Community UGC (writers = non-anonymous) |
| `nearby_spots` RPC | Geo query for the app |
| `discover-enrich` | Fast discovery: MapKit metadata + conservative baselines (no AI) |
| `research-spot` | On-demand OpenRouter web search for one spot (~30–60s) |

### Enrichment sources

| Source | When |
|--------|------|
| `baseline` | New spot from discovery (type-based defaults + MapKit phone/website in tips) |
| `community_reviews` | ≥1 review; WiFi/noise/plugs aggregated from reviews |
| `web_search` | User taps **Research this spot** (OpenRouter + Exa web search) |

Re-aggregate after a review: `{ "spot_ids": ["uuid"] }` on `discover-enrich`.

On-demand research: `{ "spot_id": "uuid" }` on `research-spot`.

`spots.enrichment_source`: `baseline` | `community_reviews` | `web_search`
