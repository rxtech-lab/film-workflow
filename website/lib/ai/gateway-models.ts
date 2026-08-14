import "server-only";

import { NANO_USD_PER_USD } from "@/lib/billing/config";

/**
 * The live Vercel AI Gateway model list.
 *
 * This reads the gateway's OpenAI-compatible `/v1/models` endpoint — the same
 * endpoint and payload shape the desktop app already consumes in
 * `OpenAIModelsClient`, so both sides classify models by the same `type`/`tags`
 * rules instead of maintaining two divergent hand-written lists.
 *
 * `@ai-sdk/gateway`'s `getAvailableModels()` is deliberately not used: its
 * response schema keeps only per-token pricing and drops the per-image,
 * per-character and per-second rates the catalog needs to quote credits.
 */
const MODELS_URL = "https://ai-gateway.vercel.sh/v1/models";
const CATALOG_TTL_MS = 15 * 60 * 1000;

export type GatewayImageVariantPrice = {
  cost?: string | null;
  quality?: string | null;
  size?: string | null;
  style?: string | null;
  operation?: string | null;
};

export type GatewayPricing = {
  input?: string | null;
  output?: string | null;
  input_cache_read?: string | null;
  input_cache_write?: string | null;
  image?: string | null;
  image_dimension_quality_pricing?: GatewayImageVariantPrice[] | null;
  speech_input_character_cost?: string | null;
  transcription_duration_cost_per_second?: string | null;
};

export type GatewayModel = {
  id: string;
  name?: string | null;
  description?: string | null;
  type?: string | null;
  tags?: string[] | null;
  pricing?: GatewayPricing | null;
};

export type TokenPricing = {
  input: number;
  output: number;
  cachedInputTokens: number | null;
  cacheCreationInputTokens: number | null;
};

let cache: { loadedAt: number; models: GatewayModel[] } | null = null;
let inFlight: Promise<GatewayModel[]> | null = null;

function entry(value: unknown): GatewayModel[] {
  if (typeof value !== "object" || value === null) return [];
  const raw = value as Record<string, unknown>;
  if (typeof raw.id !== "string" || !raw.id) return [];
  return [{
    id: raw.id,
    name: typeof raw.name === "string" ? raw.name : null,
    description: typeof raw.description === "string" ? raw.description : null,
    type: typeof raw.type === "string" ? raw.type : null,
    tags: Array.isArray(raw.tags) ? raw.tags.filter((tag): tag is string => typeof tag === "string") : null,
    pricing: typeof raw.pricing === "object" && raw.pricing !== null ? raw.pricing as GatewayPricing : null,
  }];
}

async function fetchModels(): Promise<GatewayModel[]> {
  const key = process.env.AI_GATEWAY_API_KEY?.trim();
  if (!key) throw new Error("AI_GATEWAY_NOT_CONFIGURED");
  const response = await fetch(MODELS_URL, { headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`GATEWAY_MODELS_${response.status}`);
  const body = await response.json() as unknown;
  // Standard OpenAI shape: `{ data: [...] }`. Tolerate a raw array like the desktop client does.
  const list = Array.isArray(body) ? body : Array.isArray((body as { data?: unknown })?.data) ? (body as { data: unknown[] }).data : null;
  if (!list) throw new Error("INVALID_PROVIDER_RESPONSE");
  return list.flatMap(entry);
}

/**
 * The gateway model list, cached for 15 minutes.
 *
 * A failed refresh serves the last good snapshot rather than emptying the
 * catalog — a gateway blip must not make every model disappear from the picker.
 */
export async function gatewayModels(): Promise<GatewayModel[]> {
  if (cache && Date.now() - cache.loadedAt < CATALOG_TTL_MS) return cache.models;
  inFlight ??= fetchModels()
    .then((models) => {
      cache = { loadedAt: Date.now(), models };
      return models;
    })
    .catch((cause: unknown) => {
      if (cache) return cache.models;
      throw cause;
    })
    .finally(() => { inFlight = null; });
  return inFlight;
}

export function resetGatewayModelCache() {
  cache = null;
  inFlight = null;
}

/** Model kinds that are definitively *not* speech-to-text. `speech` belongs here: it means text-to-**speech**. */
const NON_TRANSCRIPTION_TYPES = new Set(["speech", "image", "video", "embedding", "language", "reranking", "realtime"]);

export function isImageModel(model: GatewayModel) {
  if (model.type?.toLowerCase() === "image") return true;
  return model.tags?.some((tag) => tag.toLowerCase() === "image-generation") ?? false;
}

/**
 * Best-effort detection of a speech-to-text model, ported from the desktop
 * client: a declared type settles the question either way, then tags, then the
 * naming conventions providers actually follow.
 */
export function isTranscriptionModel(model: GatewayModel) {
  const kind = model.type?.toLowerCase();
  if (kind) {
    if (kind === "transcription" || kind === "audio") return true;
    if (NON_TRANSCRIPTION_TYPES.has(kind)) return false;
  }
  if (model.tags?.some((tag) => /transcription|speech-to-text/i.test(tag))) return true;
  const name = model.id.toLowerCase();
  // "-tts" and "text-to-speech" are the opposite direction — exclude them.
  if (name.includes("tts") || name.includes("text-to-speech")) return false;
  return name.includes("whisper") || name.includes("transcribe") || name.includes("stt");
}

/** Chat models: whatever the gateway declares as `language`, or — when it declares nothing — anything that is not an image or transcription model. */
export function isChatModel(model: GatewayModel) {
  const kind = model.type?.toLowerCase();
  if (kind) return kind === "language";
  return !isImageModel(model) && !isTranscriptionModel(model);
}

function usd(value: string | null | undefined) {
  if (value === null || value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function nonNegativeUsd(value: string | null | undefined) {
  if (value === null || value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

/** Per-token prices, or null when the gateway does not publish both sides — a model we cannot settle is a model we do not offer. */
export function tokenPricing(model: GatewayModel): TokenPricing | null {
  const input = nonNegativeUsd(model.pricing?.input);
  const output = nonNegativeUsd(model.pricing?.output);
  if (input === null || output === null) return null;
  return {
    input,
    output,
    cachedInputTokens: nonNegativeUsd(model.pricing?.input_cache_read),
    cacheCreationInputTokens: nonNegativeUsd(model.pricing?.input_cache_write),
  };
}

/**
 * Nano-USD per generated image, or null when the gateway prices the model by
 * tokens (`openai/gpt-image-*`) or publishes no price at all. Quality-specific
 * rows win over the base rate; rows keyed by size, style or operation are
 * skipped because this API does not select on them.
 */
export function imageNanoUsdPerUnit(model: GatewayModel, quality?: string | null): number | null {
  const variant = quality
    ? model.pricing?.image_dimension_quality_pricing?.find((row) =>
      row.quality?.toLowerCase() === quality.toLowerCase() && !row.size && !row.style && !row.operation)
    : undefined;
  const price = usd(variant?.cost) ?? usd(model.pricing?.image);
  return price === null ? null : Math.round(price * NANO_USD_PER_USD);
}
