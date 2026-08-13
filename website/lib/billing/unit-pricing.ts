import "server-only";

import { NANO_USD_PER_POINT } from "@/lib/billing/config";
import type { UnitKind } from "@/lib/db/schema";

export type UnitPrice = {
  provider: "google" | "azure" | "openai";
  model: string;
  unit: Exclude<UnitKind, "tokens">;
  nanoUsdPerUnit: number;
  minimumUnits?: number;
  source: string;
  reviewedAt: `${number}-${number}-${number}`;
};

export const UNIT_PRICES: readonly UnitPrice[] = [
  { provider: "google", model: "imagen-4.0-fast-generate-001", unit: "images", nanoUsdPerUnit: 20_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-13" },
  { provider: "google", model: "imagen-4.0-generate-001", unit: "images", nanoUsdPerUnit: 40_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-13" },
  { provider: "google", model: "imagen-4.0-ultra-generate-001", unit: "images", nanoUsdPerUnit: 60_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-13" },
  { provider: "google", model: "gemini-3.1-flash-image-preview", unit: "images", nanoUsdPerUnit: 67_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-13" },
  { provider: "google", model: "gemini-3-pro-image-preview", unit: "images", nanoUsdPerUnit: 134_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1:low", unit: "images", nanoUsdPerUnit: 11_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1:medium", unit: "images", nanoUsdPerUnit: 42_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1:high", unit: "images", nanoUsdPerUnit: 167_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1*", unit: "images", nanoUsdPerUnit: 42_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "whisper-1", unit: "audio_minutes", nanoUsdPerUnit: 6_000_000, source: "https://developers.openai.com/api/docs/models/whisper-1", reviewedAt: "2026-08-13" },
  { provider: "google", model: "gemini-3.1-flash-tts-preview", unit: "audio_seconds", nanoUsdPerUnit: 500_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-13" },
  { provider: "google", model: "lyria-3-pro-preview", unit: "audio_seconds", nanoUsdPerUnit: 444_445, minimumUnits: 180, source: "https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing", reviewedAt: "2026-08-13" },
  { provider: "azure", model: "azure-neural-tts", unit: "characters", nanoUsdPerUnit: 16_000, source: "https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/", reviewedAt: "2026-08-13" },
  { provider: "azure", model: "azure-hd-tts", unit: "characters", nanoUsdPerUnit: 30_000, source: "https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/", reviewedAt: "2026-08-13" },
  { provider: "azure", model: "azure-fast-transcription", unit: "audio_minutes", nanoUsdPerUnit: 6_000_000, source: "https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/", reviewedAt: "2026-08-13" },
] as const;

function matches(pattern: string, model: string) {
  if (pattern === "*") return true;
  if (!pattern.includes("*")) return pattern === model;
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*");
  return new RegExp(`^${escaped}$`, "i").test(model);
}

export function unitPrice(provider: UnitPrice["provider"], model: string, unit: UnitPrice["unit"]) {
  return UNIT_PRICES
    .filter((entry) => entry.provider === provider && entry.unit === unit && matches(entry.model, model))
    .sort((a, b) => b.model.replaceAll("*", "").length - a.model.replaceAll("*", "").length)[0] ?? null;
}

export function unitCostNanoUsd(input: { provider: UnitPrice["provider"]; model: string; unit: UnitPrice["unit"]; units: number }) {
  const price = unitPrice(input.provider, input.model, input.unit);
  if (!price) throw new Error(`PRICE_NOT_FOUND:${input.provider}:${input.model}:${input.unit}`);
  if (!Number.isFinite(input.units) || input.units < 0) throw new Error("INVALID_BILLABLE_UNITS");
  return Math.ceil(Math.max(input.units, price.minimumUnits ?? 0) * price.nanoUsdPerUnit);
}

export function estimateReservationPoints(input: { provider: UnitPrice["provider"]; model: string; unit: UnitPrice["unit"]; units: number; floorPoints?: number }) {
  const cost = unitCostNanoUsd(input);
  return Math.max(input.floorPoints ?? 1, Math.ceil(cost / NANO_USD_PER_POINT));
}
