export interface SpotAmenityData {
  wifi: number;
  noise: string;
  plugs: boolean | null;
  tip: string;
}

export interface MapKitFields {
  phone?: string | null;
  website?: string | null;
  poi_category?: string | null;
  external_place_id?: string | null;
  type?: string;
}

export interface SpotReviewRow {
  wifi: number;
  noise: string;
  plugs: boolean;
  tip: string;
}

export function baselineEnrichment(type = "unknown"): SpotAmenityData {
  const tipSuffix =
    "Not yet rated—add a community review or report a problem to update from the web.";

  switch (type.toLowerCase()) {
    case "park":
      return {
        wifi: 2,
        noise: "Medium",
        plugs: null,
        tip:
          `Not yet rated by the community. Outdoor park—outlet availability unknown until reviewed. ${tipSuffix}`,
      };
    case "library":
      return {
        wifi: 3,
        noise: "Low",
        plugs: null,
        tip:
          `Not yet rated by the community. Be the first to review WiFi, noise, and outlets. ${tipSuffix}`,
      };
    case "coffee":
      return {
        wifi: 3,
        noise: "Medium",
        plugs: null,
        tip:
          `Not yet rated by the community. Be the first to review this café for remote work. ${tipSuffix}`,
      };
    case "coworking":
      return {
        wifi: 3,
        noise: "Low",
        plugs: null,
        tip:
          `Not yet rated by the community. Be the first to review this space. ${tipSuffix}`,
      };
    default:
      return {
        wifi: 3,
        noise: "Medium",
        plugs: null,
        tip: tipSuffix,
      };
  }
}

export function resolveTypeFromPoi(
  searchType: string,
  poiCategory?: string | null,
): string {
  const poi = (poiCategory ?? "").toLowerCase();
  if (poi.includes("park")) return "park";
  if (poi.includes("library")) return "library";
  if (poi.includes("cafe") || poi.includes("coffee") || poi.includes("bakery")) {
    return "coffee";
  }
  if (poi.includes("coworking")) return "coworking";
  return searchType;
}

export function mapKitTipsSuffix(fields: MapKitFields): string {
  const parts: string[] = [];
  if (fields.phone?.trim()) {
    parts.push(`Phone: ${fields.phone.trim()}`);
  }
  if (fields.website?.trim()) {
    parts.push(`Website: ${fields.website.trim()}`);
  }
  if (parts.length === 0) return "";
  return "\n\n" + parts.join(" · ");
}

export function enrichFromCommunityReviews(
  reviews: SpotReviewRow[],
): SpotAmenityData {
  const wifi = clampWifi(
    Math.round(reviews.reduce((sum, r) => sum + r.wifi, 0) / reviews.length),
  );
  const plugs = reviews.filter((r) => r.plugs).length >=
    Math.ceil(reviews.length / 2);
  const noise = majorityNoise(reviews.map((r) => r.noise));

  const tip =
    `Based on ${reviews.length} WorkHaven community review(s). WiFi averages ${wifi}/5; noise mostly ${noise}; outlets ${
      plugs ? "usually available" : "often limited"
    }.`;

  return { wifi, noise, plugs, tip };
}

export function applyTypeHeuristics(
  type: string,
  data: SpotAmenityData,
): SpotAmenityData {
  if (type.toLowerCase() === "park" && data.plugs === true) {
    return { ...data, plugs: false, wifi: Math.min(data.wifi, 3) };
  }
  return data;
}

export function parseAmenityJson(content: string): SpotAmenityData {
  const jsonText = extractJson(content);
  const parsed = JSON.parse(jsonText) as {
    wifi: number;
    noise: string;
    plugs?: boolean | null;
    tip?: string;
  };

  let plugs: boolean | null = null;
  if (parsed.plugs === true) plugs = true;
  else if (parsed.plugs === false) plugs = false;

  return {
    wifi: clampWifi(parsed.wifi),
    noise: normalizeNoise(parsed.noise),
    plugs,
    tip: parsed.tip?.trim() || "Researched via web sources.",
  };
}

export function clampWifi(value: number): number {
  if (!Number.isFinite(value)) return 3;
  return Math.min(5, Math.max(1, Math.round(value)));
}

export function normalizeNoise(value: string): string {
  const lower = value?.toLowerCase() ?? "medium";
  if (lower.includes("low")) return "Low";
  if (lower.includes("high")) return "High";
  return "Medium";
}

function majorityNoise(values: string[]): string {
  const counts: Record<string, number> = { Low: 0, Medium: 0, High: 0 };
  for (const value of values) {
    const normalized = normalizeNoise(value);
    counts[normalized] = (counts[normalized] ?? 0) + 1;
  }
  return Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0];
}

function extractJson(content: string): string {
  const start = content.indexOf("{");
  const end = content.lastIndexOf("}");
  if (start >= 0 && end > start) {
    return content.slice(start, end + 1);
  }
  return content;
}
