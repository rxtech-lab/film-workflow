import "server-only";

import { gatewayModels, tokenPricing, type TokenPricing } from "@/lib/ai/gateway-models";
import { NANO_USD_PER_USD } from "@/lib/billing/config";
import type { AiUsageSnapshot } from "@/lib/db/schema";

async function modelPrices() {
  const models = await gatewayModels();
  const prices = new Map<string, TokenPricing>();
  for (const model of models) {
    const price = tokenPricing(model);
    if (price) prices.set(model.id, price);
  }
  return prices;
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
  let prices: Map<string, TokenPricing>;
  try {
    prices = await modelPrices();
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
