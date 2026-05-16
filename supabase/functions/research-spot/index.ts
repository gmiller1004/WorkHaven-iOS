import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { researchSpotWithOpenRouter } from "../_shared/openrouter.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const OPENROUTER_RESEARCH_MODEL = Deno.env.get("OPENROUTER_RESEARCH_MODEL") ??
  "google/gemini-2.0-flash-001";
const MIN_REVIEWS_FOR_COMMUNITY = 1;

interface ResearchRequest {
  spot_id: string;
  /** When true, allows web research even if community reviews exist (problem-report flow). */
  from_problem_report?: boolean;
}

interface SpotRow {
  id: string;
  name: string;
  address: string;
  type: string;
  phone?: string | null;
  website?: string | null;
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
    const openRouterKey = Deno.env.get("OPENROUTER_API_KEY");

    if (!supabaseUrl || !serviceRoleKey) {
      return errorResponse("Missing Supabase environment variables");
    }
    if (!openRouterKey) {
      return errorResponse("OPENROUTER_API_KEY is not configured in Supabase secrets");
    }

    let body: ResearchRequest;
    try {
      body = (await req.json()) as ResearchRequest;
    } catch {
      return errorResponse("Invalid JSON body");
    }

    if (!body.spot_id) {
      return errorResponse("spot_id is required");
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const { data: spot, error: spotError } = await supabase
      .from("spots")
      .select("*")
      .eq("id", body.spot_id)
      .maybeSingle();

    if (spotError) {
      console.error("Spot lookup error:", spotError.message, body.spot_id);
      return errorResponse(`Database error: ${spotError.message}`);
    }

    if (!spot) {
      console.error("Spot not found:", body.spot_id);
      return errorResponse(
        `Spot not found in the community catalog (id: ${body.spot_id}). Try refreshing your spot list.`,
      );
    }

    const { count: reviewCount, error: reviewError } = await supabase
      .from("spot_reviews")
      .select("id", { count: "exact", head: true })
      .eq("spot_id", body.spot_id);

    if (reviewError) {
      return errorResponse(reviewError.message);
    }

    if (
      !body.from_problem_report &&
      (reviewCount ?? 0) >= MIN_REVIEWS_FOR_COMMUNITY
    ) {
      return errorResponse(
        "This spot has community reviews—use Report a Problem to refresh from the web if something looks wrong.",
      );
    }

    console.log(`Researching spot ${spot.name} (${body.spot_id}) via OpenRouter`);

    const enrichment = await researchSpotWithOpenRouter(
      openRouterKey,
      OPENROUTER_RESEARCH_MODEL,
      {
        name: spot.name,
        address: spot.address,
        type: spot.type,
        phone: spot.phone,
        website: spot.website,
      },
    );

    const { data: updated, error: updateError } = await supabase
      .from("spots")
      .update({
        wifi_rating: enrichment.wifi,
        noise_rating: enrichment.noise,
        outlets: enrichment.plugs,
        tips: enrichment.tip,
        enriched_at: new Date().toISOString(),
        enrichment_source: "web_search",
        enrichment_review_count: reviewCount ?? 0,
      })
      .eq("id", body.spot_id)
      .select()
      .single();

    if (updateError) {
      return errorResponse(updateError.message);
    }

    console.log(`Researched ${spot.name} via web_search (OpenRouter)`);
    return jsonResponse({ spot: updated as SpotRow });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("research-spot error:", message);
    return errorResponse(message);
  }
});

function errorResponse(message: string): Response {
  return jsonResponse({ error: message, spot: null });
}

function jsonResponse(payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
