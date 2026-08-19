import "server-only";

import { and, count, desc, eq, ne } from "drizzle-orm";
import type { AppUser } from "@/lib/auth";
import { billingConfig, NANO_USD_PER_POINT } from "@/lib/billing/config";
import {
  releaseReservation,
  reserveBalance,
  settleReservation,
  SubscriptionApiError,
} from "@/lib/billing/subscription";
import { db } from "@/lib/db";
import {
  usageEvents,
  type AiUsageSnapshot,
  type Capability,
  type UnitKind,
} from "@/lib/db/schema";

/**
 * Local metering records.
 *
 * Balances, holds and the credit ledger all live in rx-subscription. What stays
 * here is the per-operation provider cost — which model was called, what it
 * returned, what it cost in nano-USD — because rx-subscription tracks credits,
 * not the provider detail behind them.
 */

export type UsageFundingScope = "user" | "platform";

export const USAGE_EVENT_PAGE_SIZE = 10;

export function nanoUsdFromUsd(usd: number) {
  if (!Number.isFinite(usd) || usd < 0) throw new Error("INVALID_PROVIDER_COST");
  return Math.round(usd * 1_000_000_000);
}

/** Provider cost to credits, always rounded up, so no fraction is ever carried. */
export function pointsFromCost(costNanoUsd: number) {
  if (costNanoUsd <= 0) return 0;
  return Math.max(Math.ceil(costNanoUsd / NANO_USD_PER_POINT), billingConfig.minChargePoints);
}

export async function getUsageEventHistory(userId: string, requestedPage: number) {
  // Everything except pending placeholders: an operation awaiting reconciliation
  // still consumed provider capacity, so hiding it reads as "nothing happened".
  const visibleForUser = and(eq(usageEvents.userId, userId), ne(usageEvents.status, "pending"));
  const [{ total }] = await db.select({ total: count() }).from(usageEvents).where(visibleForUser);
  const pageCount = Math.max(1, Math.ceil(total / USAGE_EVENT_PAGE_SIZE));
  const currentPage = Math.min(Math.max(1, requestedPage), pageCount);
  const events = await db.select().from(usageEvents)
    .where(visibleForUser)
    .orderBy(desc(usageEvents.createdAt), desc(usageEvents.id))
    .limit(USAGE_EVENT_PAGE_SIZE)
    .offset((currentPage - 1) * USAGE_EVENT_PAGE_SIZE);
  return { events, total, currentPage, pageCount };
}

export type CreditReservation = {
  id: string;
  points: number;
  availablePoints: number;
  expiresAt: string | null;
};

/**
 * Hold credits for an operation about to run.
 *
 * `operationKey` is rx-subscription's idempotency key, so a retried request
 * re-attaches to the hold it already took instead of taking a second one. The
 * hold carries a TTL that rx-subscription expires on its own, which is why
 * nothing here has to reap abandoned reservations.
 *
 * Throws `InsufficientCreditsError` when the balance cannot cover the estimate.
 */
export async function reserveCredits(input: {
  user: AppUser;
  operationKey: string;
  feature: string;
  points: number;
  scopeId?: string | null;
}): Promise<CreditReservation | null> {
  if (!billingConfig.enabled) return null;
  if (!Number.isSafeInteger(input.points) || input.points <= 0) throw new Error("INVALID_CREDIT_RESERVATION");
  const reservation = await reserveBalance({
    user: input.user,
    amount: input.points,
    idempotencyKey: input.operationKey,
    description: input.feature,
    expiresInSeconds: billingConfig.reservationTtlSeconds,
    metadata: { feature: input.feature, scopeId: input.scopeId ?? null },
  });
  return {
    id: reservation.reservationId,
    points: reservation.amount,
    availablePoints: reservation.available,
    expiresAt: reservation.expiresAt,
  };
}

/**
 * Drop whatever is left of a hold once the operation is done, either way.
 *
 * The charges were already taken by `settleProviderUsage` as each provider call
 * reported its cost, so this only hands the unspent remainder back. A hold with
 * usage still awaiting reconciliation is deliberately left alone: releasing it
 * would strand that usage with nothing to bill against, so it is left to expire
 * instead, which keeps it settleable.
 */
export async function closeReservation(input: {
  reservationId: string;
  userId: string;
  success: boolean;
}) {
  if (!billingConfig.enabled) return null;
  const unreconciled = (await db.select({ id: usageEvents.id }).from(usageEvents).where(and(
    eq(usageEvents.reservationId, input.reservationId),
    ne(usageEvents.status, "settled"),
  )).limit(1))[0];
  if (unreconciled) return null;
  return releaseReservation({
    reservationId: input.reservationId,
    idempotencyKey: `close:${input.reservationId}`,
    reason: input.success ? "operation_complete" : "operation_failed",
  });
}

type UsageInput = {
  userId?: string | null;
  reservationId?: string | null;
  feature: string;
  capability?: Capability;
  unitKind?: UnitKind | null;
  unitCount?: number | null;
  provider: string;
  model?: string | null;
  externalId?: string | null;
  usage?: AiUsageSnapshot | null;
  providerCredits?: number | null;
  costNanoUsd: number;
  idempotencyKey: string;
};

/**
 * Write the usage row, updating the pending placeholder if one was staged.
 *
 * Always runs after the credits are settled, so a crash in between leaves a
 * charge without a record rather than a record without a charge — and the retry
 * replays the settle idempotently before writing the row.
 */
async function recordUsage(
  input: UsageInput & { fundingScope: UsageFundingScope; chargedPoints: number; status: "settled" | "needs_review" },
) {
  const now = new Date();
  const settledAt = input.status === "settled" ? now : null;
  const existing = (await db.select().from(usageEvents).where(eq(usageEvents.idempotencyKey, input.idempotencyKey)).limit(1))[0];
  if (existing) {
    return (await db.update(usageEvents).set({
      provider: input.provider,
      capability: input.capability ?? existing.capability,
      unitKind: input.unitKind ?? existing.unitKind,
      unitCount: input.unitCount ?? existing.unitCount,
      model: input.model ?? existing.model,
      externalId: input.externalId ?? existing.externalId,
      usage: input.usage ?? existing.usage,
      providerCredits: input.providerCredits ?? existing.providerCredits,
      costNanoUsd: input.costNanoUsd,
      chargedPoints: input.chargedPoints,
      status: input.status,
      settledAt,
    }).where(eq(usageEvents.id, existing.id)).returning())[0] ?? existing;
  }
  return (await db.insert(usageEvents).values({
    id: crypto.randomUUID(),
    userId: input.fundingScope === "user" ? input.userId ?? null : null,
    reservationId: input.fundingScope === "user" ? input.reservationId ?? null : null,
    fundingScope: input.fundingScope,
    provider: input.provider,
    feature: input.feature,
    capability: input.capability ?? "chat",
    unitKind: input.unitKind ?? null,
    unitCount: input.unitCount ?? null,
    model: input.model ?? null,
    externalId: input.externalId ?? null,
    usage: input.usage ?? null,
    providerCredits: input.providerCredits ?? null,
    costNanoUsd: input.costNanoUsd,
    chargedPoints: input.chargedPoints,
    status: input.status,
    idempotencyKey: input.idempotencyKey,
    createdAt: now,
    settledAt,
  }).onConflictDoNothing().returning())[0] ?? null;
}

/**
 * Charge a provider call against its hold and record what it cost.
 *
 * Usage with no user or no hold behind it — anonymous routes, billing switched
 * off — is recorded at platform scope and charged to nobody.
 */
export async function settleProviderUsage(input: UsageInput & { needsReview?: boolean }) {
  if (!billingConfig.enabled || !input.userId || !input.reservationId) {
    return recordUsage({
      ...input,
      fundingScope: "platform",
      chargedPoints: 0,
      status: input.needsReview ? "needs_review" : "settled",
    });
  }
  const reservationId = input.reservationId;
  const alreadySettled = (await db.select().from(usageEvents).where(and(
    eq(usageEvents.idempotencyKey, input.idempotencyKey),
    eq(usageEvents.status, "settled"),
  )).limit(1))[0];
  if (alreadySettled) return alreadySettled;

  // A cost the gateway could not price yet is parked for the reconcile pass,
  // which settles it once the generation shows up.
  if (input.needsReview) {
    return recordUsage({ ...input, fundingScope: "user", chargedPoints: 0, status: "needs_review" });
  }

  const points = pointsFromCost(input.costNanoUsd);
  try {
    const settlement = await settleReservation({
      reservationId,
      amount: points,
      idempotencyKey: input.idempotencyKey,
      description: input.feature,
      metadata: {
        capability: input.capability ?? "chat",
        model: input.model ?? null,
        externalId: input.externalId ?? null,
      },
    });
    if (settlement.operationShortfallAmount > 0) {
      console.error("Provider usage exceeded the available balance", {
        reservationId,
        feature: input.feature,
        shortfallPoints: settlement.operationShortfallAmount,
      });
    }
    return recordUsage({
      ...input,
      fundingScope: "user",
      chargedPoints: settlement.operationSettledAmount,
      status: "settled",
    });
  } catch (cause) {
    // The hold was already closed, so this call outlived the operation it
    // belonged to. Park it for review rather than dropping the usage.
    if (cause instanceof SubscriptionApiError && cause.code === "reservation_not_open") {
      return recordUsage({ ...input, fundingScope: "user", chargedPoints: 0, status: "needs_review" });
    }
    throw cause;
  }
}

/** Stage a usage row before its cost is known, so a lost generation stays traceable. */
export async function createPendingUsage(input: {
  userId: string;
  reservationId: string;
  feature: string;
  capability?: Capability;
  provider: string;
  model?: string | null;
  externalId?: string | null;
  usage?: AiUsageSnapshot | null;
  idempotencyKey: string;
}) {
  const now = new Date();
  return (await db.insert(usageEvents).values({
    id: crypto.randomUUID(), userId: input.userId, reservationId: input.reservationId,
    fundingScope: "user", provider: input.provider, feature: input.feature,
    capability: input.capability ?? "chat", unitKind: null, unitCount: null,
    model: input.model ?? null, externalId: input.externalId ?? null,
    usage: input.usage ?? null, providerCredits: null, costNanoUsd: 0,
    chargedPoints: 0, status: "pending", idempotencyKey: input.idempotencyKey,
    createdAt: now, settledAt: null,
  }).onConflictDoNothing().returning())[0] ?? null;
}

export async function markUsageNeedsReview(idempotencyKey: string) {
  const event = (await db.select().from(usageEvents).where(eq(usageEvents.idempotencyKey, idempotencyKey)).limit(1))[0];
  if (!event || event.status !== "pending") return event ?? null;
  await db.update(usageEvents).set({ status: "needs_review" }).where(eq(usageEvents.id, event.id));
  return { ...event, status: "needs_review" as const };
}

/**
 * Settle a usage event the reconcile pass has finally priced.
 *
 * The hold has usually expired by the time this runs, which rx-subscription
 * still settles — against unreserved balance instead of the lapsed hold.
 */
export async function reconcileReviewedUsage(input: {
  eventId: string;
  provider: string;
  model: string;
  costNanoUsd: number;
}) {
  const event = (await db.select().from(usageEvents).where(eq(usageEvents.id, input.eventId)).limit(1))[0];
  if (!event || event.status === "settled") return event ?? null;

  let chargedPoints = 0;
  if (billingConfig.enabled && event.userId && event.reservationId) {
    const points = pointsFromCost(input.costNanoUsd);
    try {
      const settlement = await settleReservation({
        reservationId: event.reservationId,
        amount: points,
        idempotencyKey: event.idempotencyKey,
        description: event.feature,
        metadata: { capability: event.capability, model: input.model, externalId: event.externalId },
      });
      chargedPoints = settlement.operationSettledAmount;
    } catch (cause) {
      // Nothing left to bill against. Settle the record anyway so the pass stops
      // rescanning it every run, and make the write-off loud.
      if (!(cause instanceof SubscriptionApiError && cause.code === "reservation_not_open")) throw cause;
      console.error("Reconciled usage could not be charged", {
        eventId: event.id,
        reservationId: event.reservationId,
        points,
      });
    }
  }

  return (await db.update(usageEvents).set({
    provider: input.provider,
    model: input.model,
    costNanoUsd: input.costNanoUsd,
    chargedPoints,
    status: "settled",
    settledAt: new Date(),
  }).where(eq(usageEvents.id, event.id)).returning())[0] ?? event;
}
