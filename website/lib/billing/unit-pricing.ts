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
  // Gemini image models are priced per output resolution, so they are keyed
  // `model:imageSize` and carry no bare row — a resolution with no row must fail
  // closed rather than settle at the 1K rate. Google rejects an unsupported size
  // before generating, so only the tiers it actually serves need a price.
  { provider: "google", model: "gemini-3.1-flash-image:512", unit: "images", nanoUsdPerUnit: 45_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-3.1-flash-image:1K", unit: "images", nanoUsdPerUnit: 67_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-3.1-flash-image:2K", unit: "images", nanoUsdPerUnit: 101_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-3.1-flash-image:4K", unit: "images", nanoUsdPerUnit: 151_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-3-pro-image:1K", unit: "images", nanoUsdPerUnit: 134_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-3-pro-image:2K", unit: "images", nanoUsdPerUnit: 134_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-3-pro-image:4K", unit: "images", nanoUsdPerUnit: 240_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  // Single-tier models take a bare row. Lite serves 1K only. 2.5 Flash Image is
  // the legacy model Google publishes one rate for, though it will accept 2K —
  // an untiered price, so a 2K request settles at the documented rate.
  { provider: "google", model: "gemini-3.1-flash-lite-image", unit: "images", nanoUsdPerUnit: 33_600_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "google", model: "gemini-2.5-flash-image", unit: "images", nanoUsdPerUnit: 39_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-08-14" },
  { provider: "openai", model: "gpt-image-1:low", unit: "images", nanoUsdPerUnit: 11_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1:medium", unit: "images", nanoUsdPerUnit: 42_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1:high", unit: "images", nanoUsdPerUnit: 167_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "gpt-image-1*", unit: "images", nanoUsdPerUnit: 42_000_000, source: "https://developers.openai.com/api/docs/models/gpt-image-1", reviewedAt: "2026-08-13" },
  { provider: "openai", model: "whisper-1", unit: "audio_minutes", nanoUsdPerUnit: 6_000_000, source: "https://developers.openai.com/api/docs/models/whisper-1", reviewedAt: "2026-08-13" },
  // Gemini transcription is billed by Google per token, not per minute. Audio
  // tokenizes at ~32 tokens/second = 1,920 tokens/minute; at Gemini 2.5 Flash's
  // $1.00 per 1M audio-input tokens that is $0.00192/min. The diarized JSON
  // reply runs ~300 output tokens per minute of speech at $2.50 per 1M, another
  // $0.00075/min. Total $0.00267/min, stored as 2,670,000 nano-USD per minute.
  { provider: "google", model: "gemini-2.5-flash", unit: "audio_minutes", nanoUsdPerUnit: 2_670_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  // Veo is priced per second of output, audio included. Veo 3.1 tiers by
  // resolution, so those rows are keyed `model:resolution` with no bare row —
  // an unpriced tier fails closed, like Gemini images. Ids carry no `-preview`
  // suffix (see `googlePriceId`) and no `-001` build: the price row names the
  // family, and the route strips the trailing build number before lookup.
  { provider: "google", model: "veo-3.1-generate:720p", unit: "video_seconds", nanoUsdPerUnit: 400_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-generate:1080p", unit: "video_seconds", nanoUsdPerUnit: 400_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-generate:4k", unit: "video_seconds", nanoUsdPerUnit: 600_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-fast-generate:720p", unit: "video_seconds", nanoUsdPerUnit: 100_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-fast-generate:1080p", unit: "video_seconds", nanoUsdPerUnit: 120_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-fast-generate:4k", unit: "video_seconds", nanoUsdPerUnit: 300_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-lite-generate:720p", unit: "video_seconds", nanoUsdPerUnit: 50_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.1-lite-generate:1080p", unit: "video_seconds", nanoUsdPerUnit: 80_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  // Veo 3 and Veo 2 have left the public pricing page; these are the last
  // published flat rates (Veo 3 with audio $0.40/s, Veo 3 Fast $0.15/s, Veo 2
  // $0.35/s) and stay bare rows because neither family tiered by resolution.
  { provider: "google", model: "veo-3.0-generate", unit: "video_seconds", nanoUsdPerUnit: 400_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-3.0-fast-generate", unit: "video_seconds", nanoUsdPerUnit: 150_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
  { provider: "google", model: "veo-2.0-generate", unit: "video_seconds", nanoUsdPerUnit: 350_000_000, source: "https://ai.google.dev/gemini-api/docs/pricing", reviewedAt: "2026-09-13" },
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

/** Exact-match lookup, for callers that must not inherit a wildcard row's price (`gpt-image-1*` is not a price for `gpt-image-1-mini`). */
export function exactUnitPrice(provider: UnitPrice["provider"], model: string, unit: UnitPrice["unit"]) {
  return UNIT_PRICES.find((entry) => entry.provider === provider && entry.unit === unit && entry.model === model) ?? null;
}

export function unitCostNanoUsd(input: { provider: UnitPrice["provider"]; model: string; unit: UnitPrice["unit"]; units: number }) {
  const price = unitPrice(input.provider, input.model, input.unit);
  if (!price) throw new Error(`PRICE_NOT_FOUND:${input.provider}:${input.model}:${input.unit}`);
  if (!Number.isFinite(input.units) || input.units < 0) throw new Error("INVALID_BILLABLE_UNITS");
  return Math.ceil(Math.max(input.units, price.minimumUnits ?? 0) * price.nanoUsdPerUnit);
}

export function estimateReservationPoints(input: { provider: UnitPrice["provider"]; model: string; unit: UnitPrice["unit"]; units: number; floorPoints?: number }) {
  return pointsForNanoUsd(unitCostNanoUsd(input), input.floorPoints);
}

/** Cost of `units` at a rate resolved outside the table — the gateway's own published per-unit price. */
export function unitCostFromRate(nanoUsdPerUnit: number, units: number) {
  if (!Number.isFinite(nanoUsdPerUnit) || nanoUsdPerUnit < 0) throw new Error("INVALID_UNIT_RATE");
  if (!Number.isFinite(units) || units < 0) throw new Error("INVALID_BILLABLE_UNITS");
  return Math.ceil(units * nanoUsdPerUnit);
}

export function pointsForNanoUsd(nanoUsd: number, floorPoints?: number) {
  return Math.max(floorPoints ?? 1, Math.ceil(nanoUsd / NANO_USD_PER_POINT));
}
