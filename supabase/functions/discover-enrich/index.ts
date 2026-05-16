import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const GROK_MODEL = "grok-4-1-fast-non-reasoning";
const ENRICHMENT_STALE_DAYS = 7;

interface DiscoverLocation {
  name: string;
  address: string;
  latitude: number;
  longitude: number;
  type: string;
}

interface DiscoverRequest {
  locations: DiscoverLocation[];
}

interface GrokSpotData {
  wifi: number;
  noise: string;
  plugs: boolean;
  tip: string;
}

interface SpotRow {
  id: string;
  name: string;
  address: string;
  latitude: number;
  longitude: number;
  type: string;
  wifi_rating: number;
  noise_rating: string;
  outlets: boolean;
  tips: string;
  enriched_at: string | null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const grokApiKey = Deno.env.get("GROK_API_KEY");

    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error("Missing Supabase environment variables");
    }

    const body = (await req.json()) as DiscoverRequest;
    const locations = body.locations ?? [];

    if (locations.length === 0) {
      return jsonResponse({ spots: [] });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const staleBefore = new Date();
    staleBefore.setDate(staleBefore.getDate() - ENRICHMENT_STALE_DAYS);

    const results: SpotRow[] = [];

    for (const location of locations) {
      const spot = await findOrCreateSpot(supabase, location, grokApiKey, staleBefore);
      if (spot) {
        results.push(spot);
      }
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
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

// deno-lint-ignore no-explicit-any
async function findOrCreateSpot(
  supabase: any,
  location: DiscoverLocation,
  grokApiKey: string | undefined,
  staleBefore: Date,
): Promise<SpotRow | null> {
  const existing = await findExistingSpot(supabase, location);

  if (existing) {
    const enrichedAt = existing.enriched_at
      ? new Date(existing.enriched_at)
      : null;

    if (enrichedAt && enrichedAt >= staleBefore) {
      return existing as SpotRow;
    }

    if (!grokApiKey) {
      return existing as SpotRow;
    }

    const enrichment = await enrichWithGrok(
      grokApiKey,
      location.name,
      location.address,
    );

    const { data, error } = await supabase
      .from("spots")
      .update({
        wifi_rating: enrichment.wifi,
        noise_rating: enrichment.noise,
        outlets: enrichment.plugs,
        tips: enrichment.tip,
        enriched_at: new Date().toISOString(),
        type: location.type || existing.type,
      })
      .eq("id", existing.id)
      .select()
      .single();

    if (error) {
      console.error("Failed to refresh spot:", error.message);
      return existing as SpotRow;
    }

    return data as SpotRow;
  }

  const enrichment = grokApiKey
    ? await enrichWithGrok(grokApiKey, location.name, location.address)
    : defaultEnrichment();

  const { data, error } = await supabase
    .from("spots")
    .insert({
      name: location.name,
      address: location.address,
      latitude: location.latitude,
      longitude: location.longitude,
      type: location.type,
      wifi_rating: enrichment.wifi,
      noise_rating: enrichment.noise,
      outlets: enrichment.plugs,
      tips: enrichment.tip,
      enriched_at: new Date().toISOString(),
    })
    .select()
    .single();

  if (error) {
    console.error("Failed to insert spot:", error.message);
    return null;
  }

  return data as SpotRow;
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

async function enrichWithGrok(
  apiKey: string,
  name: string,
  address: string,
): Promise<GrokSpotData> {
  const prompt =
    `For "${name}" at "${address}", estimate WiFi rating (1-5 stars), noise level (Low/Medium/High), plugs (Yes/No), and a short tip. ` +
    `Respond ONLY with JSON: {"wifi": number, "noise": "Low"|"Medium"|"High", "plugs": boolean, "tip": string}`;

  const response = await fetch("https://api.x.ai/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: GROK_MODEL,
      messages: [{ role: "user", content: prompt }],
      max_tokens: 200,
      temperature: 0.3,
    }),
  });

  if (!response.ok) {
    console.error("Grok API error:", await response.text());
    return defaultEnrichment();
  }

  const payload = await response.json();
  const content = payload?.choices?.[0]?.message?.content;

  if (!content || typeof content !== "string") {
    return defaultEnrichment();
  }

  try {
    const jsonText = extractJson(content);
    const parsed = JSON.parse(jsonText) as GrokSpotData;
    return {
      wifi: clampWifi(parsed.wifi),
      noise: normalizeNoise(parsed.noise),
      plugs: Boolean(parsed.plugs),
      tip: parsed.tip?.trim() || defaultEnrichment().tip,
    };
  } catch {
    return defaultEnrichment();
  }
}

function extractJson(content: string): string {
  const start = content.indexOf("{");
  const end = content.lastIndexOf("}");
  if (start >= 0 && end > start) {
    return content.slice(start, end + 1);
  }
  return content;
}

function defaultEnrichment(): GrokSpotData {
  return {
    wifi: 3,
    noise: "Medium",
    plugs: false,
    tip: "Auto-discovered from Apple Maps",
  };
}

function clampWifi(value: number): number {
  if (!Number.isFinite(value)) return 3;
  return Math.min(5, Math.max(1, Math.round(value)));
}

function normalizeNoise(value: string): string {
  const lower = value?.toLowerCase() ?? "medium";
  if (lower.includes("low")) return "Low";
  if (lower.includes("high")) return "High";
  return "Medium";
}
