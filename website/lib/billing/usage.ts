import "server-only";

import { gateway } from "@ai-sdk/gateway";
import type { EmbeddingModelUsage, LanguageModelUsage, ProviderMetadata } from "ai";
import { billingConfig } from "@/lib/billing/config";
import { estimatedCostNanoUsd } from "@/lib/billing/pricing";
import { createPendingUsage, markUsageNeedsReview, nanoUsdFromUsd, settleProviderUsage } from "@/lib/billing/repository";
import { unitCostFromRate, unitCostNanoUsd, type UnitPrice } from "@/lib/billing/unit-pricing";
import type { AiUsageSnapshot, Capability, UnitKind } from "@/lib/db/schema";

export type MeteringContext = {
  userId?: string | null;
  reservationId?: string | null;
  feature: string;
  capability: Capability;
  operationId: string;
};

export function gatewayProviderOptions(context: Pick<MeteringContext, "userId" | "feature">) {
  return {
    gateway: {
      ...(context.userId ? { user: context.userId } : {}),
      tags: ["rxfilm-studio", context.feature],
    },
  };
}

export function normalizeLanguageUsage(usage: LanguageModelUsage): AiUsageSnapshot {
  return {
    inputTokens: usage.inputTokens,
    inputTokenDetails: {
      noCacheTokens: usage.inputTokenDetails.noCacheTokens,
      cacheReadTokens: usage.inputTokenDetails.cacheReadTokens,
      cacheWriteTokens: usage.inputTokenDetails.cacheWriteTokens,
    },
    outputTokens: usage.outputTokens,
    outputTokenDetails: {
      textTokens: usage.outputTokenDetails.textTokens,
      reasoningTokens: usage.outputTokenDetails.reasoningTokens,
    },
    totalTokens: usage.totalTokens,
  };
}

export function normalizeEmbeddingUsage(usage: EmbeddingModelUsage): AiUsageSnapshot {
  return { inputTokens: usage.tokens, totalTokens: usage.tokens };
}

function findGenerationId(value: unknown, depth = 0): string | null {
  if (depth > 5 || value === null || value === undefined) return null;
  if (typeof value === "string") return /^gen_[a-z0-9]+$/i.test(value) ? value : null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findGenerationId(item, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      if (/generation.?id/i.test(key) && typeof item === "string") return item;
      const found = findGenerationId(item, depth + 1);
      if (found) return found;
    }
  }
  return null;
}

export function gatewayGenerationId(responseId: string | null | undefined, providerMetadata?: ProviderMetadata) {
  return findGenerationId(providerMetadata) ?? (responseId?.startsWith("gen_") ? responseId : null);
}

const GENERATION_LOOKUP_ATTEMPTS = 4;
const GENERATION_LOOKUP_BACKOFF_MS = 750;

/**
 * The gateway indexes a generation slightly after the completion response is
 * flushed, so an immediate lookup 404s and would park the reservation for the
 * reconcile cron. Retry briefly before giving up.
 */
async function generationInfo(id: string) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await gateway.getGenerationInfo({ id });
    } catch (cause) {
      if (attempt >= GENERATION_LOOKUP_ATTEMPTS) throw cause;
      await new Promise((resolve) => setTimeout(resolve, GENERATION_LOOKUP_BACKOFF_MS * attempt));
    }
  }
}

export async function recordAiUsage(input: {
  context: MeteringContext;
  model: string;
  responseId?: string | null;
  providerMetadata?: ProviderMetadata;
  usage: AiUsageSnapshot;
  eventId?: string;
}) {
  const generationId = gatewayGenerationId(input.responseId, input.providerMetadata);
  const idempotencyKey = `ai:${generationId ?? input.eventId ?? `${input.context.operationId}:${crypto.randomUUID()}`}`;
  if (!generationId) {
    // No generation id means getGenerationInfo cannot price this call, so fall back
    // to the gateway model catalog rather than recording the generation as free.
    const estimated = await estimatedCostNanoUsd(input.model, input.usage);
    return settleProviderUsage({
      userId: input.context.userId,
      reservationId: input.context.reservationId,
      feature: input.context.feature,
      capability: input.context.capability,
      provider: "vercel-ai-gateway",
      model: input.model,
      usage: input.usage,
      costNanoUsd: estimated ?? 0,
      idempotencyKey,
      needsReview: estimated === null,
    });
  }
  try {
    const generation = await generationInfo(generationId);
    return settleProviderUsage({
      userId: input.context.userId,
      reservationId: input.context.reservationId,
      feature: input.context.feature,
      capability: input.context.capability,
      provider: generation.providerName || "vercel-ai-gateway",
      model: generation.model || input.model,
      externalId: generationId,
      usage: input.usage,
      costNanoUsd: nanoUsdFromUsd(generation.totalCost),
      idempotencyKey,
    });
  } catch (cause) {
    if (!billingConfig.enabled || !input.context.userId || !input.context.reservationId) {
      return settleProviderUsage({
        feature: input.context.feature,
        capability: input.context.capability,
        provider: "vercel-ai-gateway",
        model: input.model,
        externalId: generationId,
        usage: input.usage,
        costNanoUsd: 0,
        idempotencyKey,
        needsReview: true,
      });
    }
    await createPendingUsage({
      userId: input.context.userId,
      reservationId: input.context.reservationId,
      feature: input.context.feature,
      capability: input.context.capability,
      provider: "vercel-ai-gateway",
      model: input.model,
      externalId: generationId,
      usage: input.usage,
      idempotencyKey,
    });
    await markUsageNeedsReview(idempotencyKey);
    console.error("AI usage requires reconciliation", {
      generationId,
      cause: cause instanceof Error ? cause.message : "UNKNOWN_ERROR",
    });
    return null;
  }
}

export async function recordUnitUsage(input: {
  context: MeteringContext;
  provider: UnitPrice["provider"] | "vercel-ai-gateway";
  pricingProvider?: UnitPrice["provider"];
  model: string;
  capability: Capability;
  unit: Exclude<UnitKind, "tokens">;
  units: number;
  /** Rate published by the gateway for this model. Overrides the hand-maintained `UNIT_PRICES` table. */
  nanoUsdPerUnit?: number;
  externalId?: string | null;
  eventId?: string;
}) {
  return settleProviderUsage({
    userId: input.context.userId,
    reservationId: input.context.reservationId,
    feature: input.context.feature,
    capability: input.capability,
    provider: input.provider,
    model: input.model,
    unitKind: input.unit,
    unitCount: Math.ceil(input.units),
    externalId: input.externalId,
    costNanoUsd: input.nanoUsdPerUnit !== undefined
      ? unitCostFromRate(input.nanoUsdPerUnit, input.units)
      : unitCostNanoUsd({
        provider: input.pricingProvider ?? (input.provider as UnitPrice["provider"]),
        model: input.model,
        unit: input.unit,
        units: input.units,
      }),
    idempotencyKey: `unit:${input.context.operationId}:${input.eventId ?? input.capability}`,
  });
}
