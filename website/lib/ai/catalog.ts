import "server-only";

import { gatewayModels, imageNanoUsdPerUnit, isChatModel, isImageModel, tokenPricing, type GatewayModel } from "@/lib/ai/gateway-models";
import { googleImageMode, googleModels, type GoogleModel } from "@/lib/ai/google-models";
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

/**
 * Non-image models the API routes call on a provider directly rather than
 * through the gateway. These run against provider-specific request shapes
 * (Azure SSML, Gemini multi-speaker, Lyria, Whisper) with no discovery endpoint
 * to enumerate them, so they stay hand-priced against `UNIT_PRICES`. Image
 * models are never listed here — they come from the gateway and from Google's
 * live model list.
 */
export const DIRECT_MODEL_CATALOG: readonly CatalogModel[] = [
  unitModel({ id: "gemini-3.1-flash-tts-preview", provider: "google", displayName: "Gemini 3.1 Flash TTS", capability: "speech" }, "audio_seconds"),
  unitModel({ id: "azure-neural-tts", provider: "azure", displayName: "Azure Neural TTS", capability: "speech" }, "characters"),
  unitModel({ id: "lyria-3-pro-preview", provider: "google", displayName: "Lyria 3 Pro", capability: "music" }, "audio_seconds"),
  unitModel({ id: "whisper-1", provider: "openai", displayName: "Whisper", capability: "transcription" }, "audio_minutes"),
  unitModel({ id: "azure-fast-transcription", provider: "azure", displayName: "Azure Fast Transcription", capability: "transcription" }, "audio_minutes"),
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

/** What Google bills when the request names no resolution. */
const DEFAULT_IMAGE_SIZE = "1K";

/**
 * Preview and GA ids are the same model at the same rate — the list serves
 * `gemini-3-pro-image-preview` and `gemini-3-pro-image` side by side under one
 * display name — so one set of rows covers both, and a GA promotion needs no
 * table edit.
 */
function googlePriceId(id: string) {
  return id.endsWith("-preview") ? id.slice(0, -"-preview".length) : id;
}

/**
 * The price row for a model called on Google directly. Google publishes no
 * pricing endpoint, so rates stay hand-maintained — but exact matches only, so a
 * newly listed model is dropped from the catalog rather than billed at a
 * sibling's rate. Resolution-tiered models are keyed `model:imageSize`; flat-
 * priced ones (Imagen) fall through to a bare row.
 */
export function googleImagePrice(id: string, resolution?: string | null) {
  const base = googlePriceId(id);
  const size = (resolution?.trim() || DEFAULT_IMAGE_SIZE).toUpperCase();
  return exactUnitPrice("google", `${base}:${size}`, "images")
    ?? exactUnitPrice("google", base, "images");
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
    return [];
  }
  return models.flatMap((model) => catalogEntry(model) ?? []);
}

function googleImageEntry(model: GoogleModel): CatalogModel | null {
  if (!googleImageMode(model)) return null;
  // The picker quotes the default resolution; the route bills the one requested.
  const price = googleImagePrice(model.id);
  if (!price) return null;
  return {
    id: model.id,
    provider: "google",
    displayName: model.displayName?.trim() || model.id,
    capability: "image",
    estimate: { unit: "images", pointsPerUnit: Math.ceil(price.nanoUsdPerUnit / NANO_USD_PER_POINT) },
  };
}

/** Live Google AI Studio image models — Imagen plus the Gemini image family, called on Google directly. */
async function googleImageCatalog(): Promise<CatalogModel[]> {
  let models: GoogleModel[];
  try {
    models = await googleModels();
  } catch (cause) {
    console.error("Google model list unavailable", { cause: cause instanceof Error ? cause.message : "UNKNOWN_ERROR" });
    return [];
  }
  // One model can be listed under several ids sharing a display name — "Nano
  // Banana Pro" is `gemini-3-pro-image`, `gemini-3-pro-image-preview` and
  // `nano-banana-pro-preview` — which would put three identical rows in the
  // picker. Collapse by name, keeping the id that reads as canonical: GA over
  // preview, then the shortest.
  const canonical = new Map<string, CatalogModel>();
  for (const model of models) {
    const entry = googleImageEntry(model);
    if (!entry) continue;
    const previous = canonical.get(entry.displayName);
    if (!previous || preferredId(entry.id, previous.id) === entry.id) canonical.set(entry.displayName, entry);
  }
  return [...canonical.values()];
}

function preferredId(a: string, b: string) {
  const preview = (id: string) => id.endsWith("-preview");
  if (preview(a) !== preview(b)) return preview(a) ? b : a;
  return a.length <= b.length ? a : b;
}

/** The full catalog: live gateway models, live Google image models, and the direct non-image models, deduped and sorted the way the desktop pickers sort. */
export async function modelCatalog(): Promise<CatalogModel[]> {
  const [gatewayList, googleImages] = await Promise.all([gatewayCatalog(), googleImageCatalog()]);
  const direct = [...googleImages, ...DIRECT_MODEL_CATALOG];
  const claimed = new Set(direct.map((model) => `${model.capability}:${model.id}`));
  const gateway = gatewayList
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
