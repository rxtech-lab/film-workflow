import "server-only";

import { gatewayModels, imageNanoUsdPerUnit, isChatModel, isImageModel, tokenPricing, type GatewayModel } from "@/lib/ai/gateway-models";
import { NANO_USD_PER_POINT } from "@/lib/billing/config";
import { exactUnitPrice, unitPrice } from "@/lib/billing/unit-pricing";
import type { Capability, UnitKind } from "@/lib/db/schema";

export type CatalogModel = {
  id: string;
  provider: "gateway" | "google" | "azure" | "openai";
  displayName: string;
  capability: Capability;
  estimate?: { unit: UnitKind; pointsPerUnit: number };
};

function unitModel(input: Omit<CatalogModel, "estimate">, unit: Exclude<UnitKind, "tokens">): CatalogModel {
  if (input.provider === "gateway") return input;
  const price = unitPrice(input.provider, input.id, unit);
  if (!price) throw new Error(`PRICE_NOT_FOUND:${input.provider}:${input.id}:${unit}`);
  return { ...input, estimate: { unit, pointsPerUnit: Math.ceil(price.nanoUsdPerUnit / NANO_USD_PER_POINT) } };
}

function gatewayUnitModel(
  input: Omit<CatalogModel, "estimate">,
  unit: Exclude<UnitKind, "tokens">,
  pricing: { provider: "google" | "azure" | "openai"; model: string },
): CatalogModel {
  const price = unitPrice(pricing.provider, pricing.model, unit);
  if (!price) throw new Error(`PRICE_NOT_FOUND:${pricing.provider}:${pricing.model}:${unit}`);
  return { ...input, estimate: { unit, pointsPerUnit: Math.ceil(price.nanoUsdPerUnit / NANO_USD_PER_POINT) } };
}

/**
 * Models the API routes call on a provider directly rather than through the
 * gateway. These are not in the gateway model list — or, for Imagen, are
 * reachable both ways and kept on the direct path the desktop already stores in
 * its saved selections — so they stay hand-priced against `UNIT_PRICES`.
 */
export const DIRECT_MODEL_CATALOG: readonly CatalogModel[] = [
  unitModel({ id: "imagen-4.0-fast-generate-001", provider: "google", displayName: "Imagen 4 Fast", capability: "image" }, "images"),
  unitModel({ id: "imagen-4.0-generate-001", provider: "google", displayName: "Imagen 4", capability: "image" }, "images"),
  unitModel({ id: "imagen-4.0-ultra-generate-001", provider: "google", displayName: "Imagen 4 Ultra", capability: "image" }, "images"),
  unitModel({ id: "gemini-3.1-flash-tts-preview", provider: "google", displayName: "Gemini 3.1 Flash TTS", capability: "speech" }, "audio_seconds"),
  unitModel({ id: "azure-neural-tts", provider: "azure", displayName: "Azure Neural TTS", capability: "speech" }, "characters"),
  unitModel({ id: "lyria-3-pro-preview", provider: "google", displayName: "Lyria 3 Pro", capability: "music" }, "audio_seconds"),
  unitModel({ id: "whisper-1", provider: "openai", displayName: "Whisper", capability: "transcription" }, "audio_minutes"),
  unitModel({ id: "azure-fast-transcription", provider: "azure", displayName: "Azure Fast Transcription", capability: "transcription" }, "audio_minutes"),
] as const;

/** Served only when the gateway model list is unreachable on a cold cache, so the pickers never come back empty. */
export const GATEWAY_FALLBACK_CATALOG: readonly CatalogModel[] = [
  { id: "openai/gpt-5.4-mini", provider: "gateway", displayName: "GPT-5.4 mini", capability: "chat" },
  { id: "google/gemini-3-flash", provider: "gateway", displayName: "Gemini 3 Flash", capability: "chat" },
  gatewayUnitModel(
    { id: "openai/gpt-image-1", provider: "gateway", displayName: "GPT Image 1", capability: "image" },
    "images",
    { provider: "openai", model: "gpt-image-1:medium" },
  ),
] as const;

const CAPABILITY_ORDER: Capability[] = ["chat", "image", "speech", "music", "transcription", "translation"];

/**
 * Per-image price from the hand-maintained table, for gateway models the
 * gateway itself prices by tokens (`openai/gpt-image-1`). Exact matches only —
 * inheriting the `gpt-image-1*` wildcard would quote GPT Image 1's rate for
 * every cheaper sibling, so an unlisted variant stays unpriced and unoffered.
 */
function staticImageNanoUsd(id: string, quality?: string | null): number | null {
  const slash = id.indexOf("/");
  const prefix = slash === -1 ? null : id.slice(0, slash);
  const bare = slash === -1 ? id : id.slice(slash + 1);
  const provider = prefix === "openai" || prefix === "google" || prefix === "azure" ? prefix : null;
  if (!provider) return null;
  const model = provider === "openai" ? `${bare}:${quality ?? "medium"}` : bare;
  return exactUnitPrice(provider, model, "images")?.nanoUsdPerUnit ?? null;
}

/**
 * Nano-USD per image for a catalog model, preferring the gateway's published
 * price and falling back to `UNIT_PRICES`. Null means the model cannot be
 * billed, so it is neither offered nor accepted.
 */
export async function imageUnitNanoUsd(id: string, quality?: string | null): Promise<number | null> {
  const model = (await gatewayModels().catch(() => [] as GatewayModel[])).find((entry) => entry.id === id);
  // `quality` only reaches OpenAI models — quoting another vendor's discounted
  // tier for a request it never sees would undercharge the generation.
  const selected = id.startsWith("openai/") ? quality : null;
  return (model ? imageNanoUsdPerUnit(model, selected) : null) ?? staticImageNanoUsd(id, selected);
}

function catalogEntry(model: GatewayModel): CatalogModel | null {
  const displayName = model.name?.trim() || model.id;
  if (isImageModel(model)) {
    const nanoUsdPerImage = imageNanoUsdPerUnit(model) ?? staticImageNanoUsd(model.id);
    if (nanoUsdPerImage === null) return null;
    return { id: model.id, provider: "gateway", displayName, capability: "image", estimate: { unit: "images", pointsPerUnit: Math.ceil(nanoUsdPerImage / NANO_USD_PER_POINT) } };
  }
  // Chat is settled from the tokens the response reports, so it carries no per-unit estimate.
  if (isChatModel(model) && tokenPricing(model)) return { id: model.id, provider: "gateway", displayName, capability: "chat" };
  // Speech, music and transcription run against provider-specific request shapes
  // (Azure SSML, Gemini multi-speaker, Lyria, Whisper), so gateway entries for
  // those kinds are not offered — the routes could not execute them.
  return null;
}

async function gatewayCatalog(): Promise<CatalogModel[]> {
  let models: GatewayModel[];
  try {
    models = await gatewayModels();
  } catch (cause) {
    console.error("Gateway model list unavailable", { cause: cause instanceof Error ? cause.message : "UNKNOWN_ERROR" });
    return [...GATEWAY_FALLBACK_CATALOG];
  }
  const catalog = models.flatMap((model) => catalogEntry(model) ?? []);
  return catalog.length ? catalog : [...GATEWAY_FALLBACK_CATALOG];
}

/** The full catalog: live gateway models plus the direct-provider models, deduped and sorted the way the desktop pickers sort. */
export async function modelCatalog(): Promise<CatalogModel[]> {
  const direct = [...DIRECT_MODEL_CATALOG];
  const claimed = new Set(direct.map((model) => `${model.capability}:${model.id}`));
  const gateway = (await gatewayCatalog())
    // A gateway id whose bare name is already served directly (`google/imagen-4.0-generate-001`
    // vs `imagen-4.0-generate-001`) would show up twice in the picker.
    .filter((model) => !claimed.has(`${model.capability}:${model.id.slice(model.id.indexOf("/") + 1)}`));
  return [...gateway, ...direct].sort((a, b) =>
    CAPABILITY_ORDER.indexOf(a.capability) - CAPABILITY_ORDER.indexOf(b.capability)
    || a.id.localeCompare(b.id, undefined, { sensitivity: "base" }));
}

export async function catalogForCapability(capability?: string | null) {
  const catalog = await modelCatalog();
  if (!capability) return catalog;
  return catalog.filter((model) => model.capability === capability);
}

export async function requireCatalogModel(id: string, capability: Capability) {
  const model = (await modelCatalog()).find((entry) => entry.id === id && entry.capability === capability);
  if (!model) throw new Error(`MODEL_NOT_ALLOWED:${capability}:${id}`);
  return model;
}
