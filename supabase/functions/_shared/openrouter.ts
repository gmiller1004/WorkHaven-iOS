import {
  applyTypeHeuristics,
  parseAmenityJson,
  type SpotAmenityData,
} from "./spot-enrichment.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

function extractMessageContent(payload: Record<string, unknown>): string {
  const choice = payload?.choices as Array<Record<string, unknown>> | undefined;
  const message = choice?.[0]?.message as Record<string, unknown> | undefined;
  if (!message) return "";

  const content = message.content;
  if (typeof content === "string" && content.trim()) {
    return content.trim();
  }

  if (Array.isArray(content)) {
    const parts = content
      .filter((part): part is Record<string, unknown> =>
        typeof part === "object" && part !== null
      )
      .map((part) => {
        if (part.type === "text" && typeof part.text === "string") {
          return part.text;
        }
        if (typeof part.text === "string") return part.text;
        return "";
      })
      .filter((text) => text.length > 0);
    if (parts.length > 0) return parts.join("\n");
  }

  if (typeof message.refusal === "string" && message.refusal.trim()) {
    return message.refusal.trim();
  }

  return "";
}

async function callChatCompletions(
  apiKey: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const response = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://workhaven.app",
      "X-Title": "WorkHaven",
    },
    body: JSON.stringify(body),
  });

  const rawText = await response.text();
  if (!response.ok) {
    throw new Error(`OpenRouter HTTP ${response.status}: ${rawText.slice(0, 600)}`);
  }

  try {
    return JSON.parse(rawText) as Record<string, unknown>;
  } catch {
    throw new Error(`OpenRouter non-JSON response: ${rawText.slice(0, 300)}`);
  }
}

function buildResearchPrompt(params: {
  name: string;
  address: string;
  type: string;
  phone?: string | null;
  website?: string | null;
}): string {
  const contextLines = [
    `Venue: "${params.name}"`,
    `Address: "${params.address}"`,
    `Category: ${params.type}`,
  ];
  if (params.phone?.trim()) contextLines.push(`Phone: ${params.phone.trim()}`);
  if (params.website?.trim()) {
    contextLines.push(`Website: ${params.website.trim()}`);
  }

  return (
    `Research this place for remote laptop work.\n${contextLines.join("\n")}\n\n` +
    `Find credible web information about WiFi quality (1-5), noise (Low/Medium/High), power outlets, and work-friendliness.\n` +
    `Rules:\n` +
    `- Do NOT guess from venue type alone.\n` +
    `- If outlet availability is unclear, set "plugs" to null (unknown), NOT false.\n` +
    `- Only set "plugs" to false when sources clearly say there are no outlets.\n` +
    `- If evidence is weak, use conservative WiFi/noise and null plugs.\n` +
    `Respond ONLY with JSON: {"wifi":1-5,"noise":"Low"|"Medium"|"High","plugs":true|false|null,"tip":"string"}`
  );
}

function onlineModelId(model: string): string {
  const base = model.replace(/:online$/i, "");
  return `${base}:online`;
}

async function researchWithOnlineModel(
  apiKey: string,
  model: string,
  prompt: string,
): Promise<string> {
  const onlineModel = onlineModelId(model);
  console.log(`OpenRouter :online attempt: ${onlineModel}`);

  const payload = await callChatCompletions(apiKey, {
    model: onlineModel,
    messages: [{ role: "user", content: prompt }],
    temperature: 0.2,
    max_tokens: 700,
  });

  const content = extractMessageContent(payload);
  if (content) return content;

  throw new Error(`No content from ${onlineModel}`);
}

async function researchWithWebSearchTool(
  apiKey: string,
  model: string,
  prompt: string,
): Promise<string> {
  const baseModel = model.replace(/:online$/i, "");
  console.log(`OpenRouter web_search attempt: ${baseModel}`);

  const payload = await callChatCompletions(apiKey, {
    model: baseModel,
    messages: [{ role: "user", content: prompt }],
    tools: [{
      type: "openrouter:web_search",
      parameters: {
        engine: "exa",
        max_results: 3,
        max_total_results: 3,
        search_context_size: "low",
      },
    }],
    temperature: 0.2,
    max_tokens: 700,
  });

  const content = extractMessageContent(payload);
  if (content) return content;

  throw new Error(`No content from web_search (${baseModel})`);
}

export async function researchSpotWithOpenRouter(
  apiKey: string,
  model: string,
  params: {
    name: string;
    address: string;
    type: string;
    phone?: string | null;
    website?: string | null;
  },
): Promise<SpotAmenityData> {
  const prompt = buildResearchPrompt(params);
  const errors: string[] = [];

  try {
    const content = await researchWithOnlineModel(apiKey, model, prompt);
    return applyTypeHeuristics(params.type, parseAmenityJson(content));
  } catch (error) {
    errors.push(error instanceof Error ? error.message : String(error));
  }

  try {
    const content = await researchWithWebSearchTool(apiKey, model, prompt);
    return applyTypeHeuristics(params.type, parseAmenityJson(content));
  } catch (error) {
    errors.push(error instanceof Error ? error.message : String(error));
  }

  throw new Error(errors.join(" | "));
}
