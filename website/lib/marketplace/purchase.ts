import "server-only";

import type { AppUser } from "@/lib/auth";
import { billingConfig } from "@/lib/billing/config";
import { InsufficientCreditsError } from "@/lib/billing/errors";
import { releaseReservation, reserveBalance, settleReservation } from "@/lib/billing/subscription";
import { findPurchase, insertPurchase, requireItem } from "@/lib/marketplace/repository";

export function purchaseIdempotencyKey(userId: string, itemId: string) {
  return `marketplace:${userId}:${itemId}`;
}

/**
 * Grant `user` the item, charging its price through rx-subscription.
 *
 * The full price is held and then settled in one go. Both calls are idempotent
 * on the purchase key, and `(user, item)` is unique locally, so a retried
 * request after a crash re-attaches to the hold it already took and lands on
 * the row it already wrote rather than charging twice.
 */
export async function purchaseItem(user: AppUser, itemId: string) {
  const item = await requireItem(itemId);
  if (item.status !== "published") throw new Error("NOT_FOUND");

  const existing = await findPurchase(user.id, item.id);
  if (existing) return { item, purchase: existing, alreadyOwned: true };

  const key = purchaseIdempotencyKey(user.id, item.id);
  if (item.pricePoints <= 0 || !billingConfig.enabled) {
    const purchase = await insertPurchase({ userId: user.id, itemId: item.id, pointsCharged: 0, reservationId: null, idempotencyKey: key });
    return { item, purchase, alreadyOwned: false };
  }

  const reservation = await reserveBalance({
    user,
    amount: item.pricePoints,
    idempotencyKey: key,
    description: `Marketplace: ${item.title}`,
    expiresInSeconds: billingConfig.reservationTtlSeconds,
    metadata: { itemId: item.id, kind: item.kind },
  });
  const settlement = await settleReservation({
    reservationId: reservation.reservationId,
    amount: item.pricePoints,
    idempotencyKey: `${key}:settle`,
    description: `Marketplace: ${item.title}`,
    metadata: { itemId: item.id, kind: item.kind },
  });
  if (settlement.operationShortfallAmount > 0) {
    // The hold was taken against a balance that shrank before it settled. Give
    // back what did settle rather than granting a partly paid item.
    await releaseReservation({ reservationId: reservation.reservationId, idempotencyKey: `${key}:release`, reason: "marketplace_shortfall" }).catch(() => null);
    throw new InsufficientCreditsError(settlement.balanceAfter, item.pricePoints);
  }
  const purchase = await insertPurchase({
    userId: user.id,
    itemId: item.id,
    pointsCharged: settlement.operationSettledAmount,
    reservationId: reservation.reservationId,
    idempotencyKey: key,
  });
  return { item, purchase, alreadyOwned: false };
}
