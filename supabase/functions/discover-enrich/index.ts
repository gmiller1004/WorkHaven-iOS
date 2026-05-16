import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import {
  baselineEnrichment,
  enrichFromCommunityReviews,
  mapKitTipsSuffix,
  resolveTypeFromPoi,
  type MapKitFields,
  type SpotReviewRow,
} from "../_shared/spot-enrichment.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const MIN_REVIEWS_FOR_COMMUNITY = 1;

interface DiscoverLocation extends MapKitFields {
  name: string;
  address: string;
  latitude: number;
  longitude: number;
  type: string;
}

interface DiscoverRequest {
  locations?: DiscoverLocation[];
  spot_ids?: string[];
}

interface SpotRow {
  id: string;
  name: string;
  address: string;
  latitude: number;
  longitude: number;
  type: string;
  phone?: string | null;
  website?: string | null;
  poi_category?: string | null;
  external_place_id?: string | null;
  wifi_rating: number;
  noise_rating: string;
  outlets: boolean | null;
  tips: string;
  enriched_at: string | null;
  enrichment_source?: string;
  enrichment_review_count?: number;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error("Missing Supabase environment variables");
    }

    const body = (await req.json()) as DiscoverRequest;
    const locations = body.locations ?? [];
    const spotIds = body.spot_ids ?? [];

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const results: SpotRow[] = [];

    for (const location of locations) {
      const spot = await findOrCreateSpot(supabase, location);
      if (spot) results.push(spot);
    }

    for (const spotId of spotIds) {
      const spot = await reEnrichFromReviews(supabase, spotId);
      if (spot) results.push(spot);
    }

    return jsonResponse({ spots: results });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("discover-enrich error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// deno-lint-ignore no-explicit-any
async function findOrCreateSpot(
  supabase: any,
  location: DiscoverLocation,
): Promise<SpotRow | null> {
  const resolvedType = resolveTypeFromPoi(location.type, location.poi_category);
  const mapKit: MapKitFields = {
    phone: location.phone,
    website: location.website,
    poi_category: location.poi_category,
    external_place_id: location.external_place_id,
    type: resolvedType,
  };

  const existing = await findExistingSpot(supabase, location);

  if (existing) {
    const updated = await updateMapKitFields(
      supabase,
      existing as SpotRow,
      location,
      resolvedType,
    );
    const reviews = await fetchReviewsForSpot(supabase, updated.id);
    if (reviews.length >= MIN_REVIEWS_FOR_COMMUNITY) {
      return await persistCommunityEnrichment(
        supabase,
        updated,
        reviews,
      );
    }
    return updated;
  }

  const baseline = baselineEnrichment(resolvedType);
  const tips = baseline.tip + mapKitTipsSuffix(mapKit);

  const { data, error } = await supabase
    .from("spots")
    .insert({
      name: location.name,
      address: location.address,
      latitude: location.latitude,
      longitude: location.longitude,
      type: resolvedType,
      phone: location.phone ?? null,
      website: location.website ?? null,
      poi_category: location.poi_category ?? null,
      external_place_id: location.external_place_id ?? null,
      wifi_rating: baseline.wifi,
      noise_rating: baseline.noise,
      outlets: baseline.plugs,
      tips,
      enriched_at: new Date().toISOString(),
      enrichment_source: "baseline",
      enrichment_review_count: 0,
    })
    .select()
    .single();

  if (error) {
    console.error("Failed to insert spot:", error.message);
    return null;
  }

  console.log(`Created baseline spot ${location.name}`);
  return data as SpotRow;
}

// deno-lint-ignore no-explicit-any
async function reEnrichFromReviews(
  supabase: any,
  spotId: string,
): Promise<SpotRow | null> {
  const { data, error } = await supabase
    .from("spots")
    .select("*")
    .eq("id", spotId)
    .single();

  if (error || !data) {
    console.error("Spot not found for re-enrich:", spotId, error?.message);
    return null;
  }

  const spot = data as SpotRow;
  const reviews = await fetchReviewsForSpot(supabase, spotId);
  if (reviews.length < MIN_REVIEWS_FOR_COMMUNITY) {
    return spot;
  }

  return await persistCommunityEnrichment(supabase, spot, reviews);
}

// deno-lint-ignore no-explicit-any
async function updateMapKitFields(
  supabase: any,
  spot: SpotRow,
  location: DiscoverLocation,
  resolvedType: string,
): Promise<SpotRow> {
  const mapKit: MapKitFields = {
    phone: location.phone ?? spot.phone,
    website: location.website ?? spot.website,
    poi_category: location.poi_category ?? spot.poi_category,
    external_place_id: location.external_place_id ?? spot.external_place_id,
    type: resolvedType,
  };

  let tips = spot.tips;
  if (spot.enrichment_source === "baseline") {
    const baseline = baselineEnrichment(resolvedType);
    tips = baseline.tip + mapKitTipsSuffix(mapKit);
  }

  const { data, error } = await supabase
    .from("spots")
    .update({
      type: resolvedType,
      phone: mapKit.phone ?? null,
      website: mapKit.website ?? null,
      poi_category: mapKit.poi_category ?? null,
      external_place_id: mapKit.external_place_id ?? null,
      tips,
      updated_at: new Date().toISOString(),
    })
    .eq("id", spot.id)
    .select()
    .single();

  if (error) {
    console.error("Failed to update MapKit fields:", error.message);
    return spot;
  }

  return data as SpotRow;
}

// deno-lint-ignore no-explicit-any
async function persistCommunityEnrichment(
  supabase: any,
  spot: SpotRow,
  reviews: SpotReviewRow[],
): Promise<SpotRow> {
  const enrichment = enrichFromCommunityReviews(reviews);

  const { data, error } = await supabase
    .from("spots")
    .update({
      wifi_rating: enrichment.wifi,
      noise_rating: enrichment.noise,
      outlets: enrichment.plugs,
      tips: enrichment.tip,
      enriched_at: new Date().toISOString(),
      enrichment_source: "community_reviews",
      enrichment_review_count: reviews.length,
    })
    .eq("id", spot.id)
    .select()
    .single();

  if (error) {
    console.error("Failed to persist community enrichment:", error.message);
    return spot;
  }

  console.log(
    `Enriched ${spot.name} from ${reviews.length} community review(s)`,
  );
  return data as SpotRow;
}

// deno-lint-ignore no-explicit-any
async function fetchReviewsForSpot(
  supabase: any,
  spotId: string,
): Promise<SpotReviewRow[]> {
  const { data, error } = await supabase
    .from("spot_reviews")
    .select("wifi, noise, plugs, tip")
    .eq("spot_id", spotId)
    .order("updated_at", { ascending: false });

  if (error) {
    console.error("Failed to fetch reviews:", error.message);
    return [];
  }

  return (data ?? []) as SpotReviewRow[];
}

// deno-lint-ignore no-explicit-any
async function findExistingSpot(
  supabase: any,
  location: DiscoverLocation,
): Promise<SpotRow | null> {
  const normalizedName = location.name.trim().toLowerCase();
  const normalizedAddress = location.address.trim().toLowerCase();

  const { data: byName } = await supabase
    .from("spots")
    .select("*")
    .ilike("name", location.name.trim())
    .ilike("address", location.address.trim())
    .limit(1);

  if (byName && byName.length > 0) {
    return byName[0] as SpotRow;
  }

  const { data: nearby } = await supabase.rpc("nearby_spots", {
    p_lat: location.latitude,
    p_lng: location.longitude,
    p_radius_meters: 100,
  });

  if (!nearby || nearby.length === 0) {
    return null;
  }

  for (const candidate of nearby as SpotRow[]) {
    const candidateName = candidate.name.trim().toLowerCase();
    const candidateAddress = candidate.address.trim().toLowerCase();

    if (
      candidateName === normalizedName ||
      candidateAddress === normalizedAddress
    ) {
      return candidate;
    }
  }

  return null;
}
