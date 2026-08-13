import "server-only";

import { gateway } from "@ai-sdk/gateway";
import { NANO_USD_PER_USD } from "@/lib/billing/config";
import type { AiUsageSnapshot } from "@/lib/db/schema";

const CATALOG_TTL_MS = 15 * 60 * 1000;

type ModelPricing = {
  input: number;
  output: number;
  cachedInputTokens: number | null;
  cacheCreationInputTokens: number | null;
};

let catalog: { loadedAt: number; prices: Map<string, ModelPricing> } | null = null;
let inFlight: Promise<Map<string, ModelPricing>> | null = null;

function usdPerToken(value: string | undefined) {
  if (value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

async function loadCatalog() {
  const { models } = await gateway.getAvailableModels();
  const prices = new Map<string, ModelPricing>();
  for (const model of models) {
    const input = usdPerToken(model.pricing?.input);
    const output = usdPerToken(model.pricing?.output);
    if (input === null || output === null) continue;
    prices.set(model.id, {
      input,
      output,
      cachedInputTokens: usdPerToken(model.pricing?.cachedInputTokens ?? undefined),
      cacheCreationInputTokens: usdPerToken(model.pricing?.cacheCreationInputTokens ?? undefined),
    });
  }
  return prices;
}

async function modelPrices(now: number) {
  if (catalog && now - catalog.loadedAt < CATALOG_TTL_MS) return catalog.prices;
  inFlight ??= loadCatalog()
    .then((prices) => {
      catalog = { loadedAt: Date.now(), prices };
      return prices;
    })
    .finally(() => { inFlight = null; });
  return inFlight;
}

/**
 * Cost of a generation derived from the gateway model catalog.
 *
 * The gateway only exposes an authoritative per-generation cost through
 * `getGenerationInfo`, which needs a generation id that the SDK does not surface
 * on successful responses. Pricing the tokens we already have keeps metering
 * accurate instead of recording every generation as free.
 *
 * Returns null when the model is absent from the catalog or the catalog is
 * unreachable, so callers can fall back to manual review.
 */
export async function estimatedCostNanoUsd(model: string, usage: AiUsageSnapshot): Promise<number | null> {
  let prices: Map<string, ModelPricing>;
  try {
    prices = await modelPrices(Date.now());
  } catch {
    return null;
  }
  const price = prices.get(model);
  if (!price) return null;

  const cacheReadTokens = usage.inputTokenDetails?.cacheReadTokens ?? 0;
  const cacheWriteTokens = usage.inputTokenDetails?.cacheWriteTokens ?? 0;
  // noCacheTokens is authoritative when present; otherwise back it out of the total.
  const noCacheTokens = usage.inputTokenDetails?.noCacheTokens
    ?? Math.max(0, (usage.inputTokens ?? 0) - cacheReadTokens - cacheWriteTokens);

  const usd = noCacheTokens * price.input
    + cacheReadTokens * (price.cachedInputTokens ?? price.input)
    + cacheWriteTokens * (price.cacheCreationInputTokens ?? price.input)
    + (usage.outputTokens ?? 0) * price.output;

  return Number.isFinite(usd) && usd >= 0 ? Math.round(usd * NANO_USD_PER_USD) : null;
}
