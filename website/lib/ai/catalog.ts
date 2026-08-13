import "server-only";

import { NANO_USD_PER_POINT } from "@/lib/billing/config";
import { unitPrice } from "@/lib/billing/unit-pricing";
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

export const MODEL_CATALOG: readonly CatalogModel[] = [
  { id: "openai/gpt-5.4-mini", provider: "gateway", displayName: "GPT-5.4 mini", capability: "chat" },
  { id: "google/gemini-3-flash-preview", provider: "gateway", displayName: "Gemini 3 Flash", capability: "chat" },
  unitModel({ id: "imagen-4.0-fast-generate-001", provider: "google", displayName: "Imagen 4 Fast", capability: "image" }, "images"),
  unitModel({ id: "imagen-4.0-generate-001", provider: "google", displayName: "Imagen 4", capability: "image" }, "images"),
  unitModel({ id: "imagen-4.0-ultra-generate-001", provider: "google", displayName: "Imagen 4 Ultra", capability: "image" }, "images"),
  gatewayUnitModel(
    { id: "openai/gpt-image-1", provider: "gateway", displayName: "GPT Image 1", capability: "image" },
    "images",
    { provider: "openai", model: "gpt-image-1:medium" },
  ),
  unitModel({ id: "gemini-3.1-flash-tts-preview", provider: "google", displayName: "Gemini 3.1 Flash TTS", capability: "speech" }, "audio_seconds"),
  unitModel({ id: "azure-neural-tts", provider: "azure", displayName: "Azure Neural TTS", capability: "speech" }, "characters"),
  unitModel({ id: "lyria-3-pro-preview", provider: "google", displayName: "Lyria 3 Pro", capability: "music" }, "audio_seconds"),
  unitModel({ id: "whisper-1", provider: "openai", displayName: "Whisper", capability: "transcription" }, "audio_minutes"),
  unitModel({ id: "azure-fast-transcription", provider: "azure", displayName: "Azure Fast Transcription", capability: "transcription" }, "audio_minutes"),
] as const;

export function catalogForCapability(capability?: string | null) {
  if (!capability) return MODEL_CATALOG;
  return MODEL_CATALOG.filter((model) => model.capability === capability);
}

export function requireCatalogModel(id: string, capability: Capability) {
  const model = MODEL_CATALOG.find((entry) => entry.id === id && entry.capability === capability);
  if (!model) throw new Error(`MODEL_NOT_ALLOWED:${capability}:${id}`);
  return model;
}
