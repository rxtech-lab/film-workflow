import "server-only";

import type { AppUser } from "@/lib/auth";
import { billingConfig } from "@/lib/billing/config";
import { BALANCE_UNIT, getCatalog, getEntitlements, type TopupProduct } from "@/lib/billing/subscription";

export type CreditPack = {
  /** rx-subscription's topup key, which is what checkout takes as `packId`. */
  id: string;
  points: number;
  amountCents: number;
  currency: string;
  name: string;
  eligible: boolean;
};

function pack(topup: TopupProduct): CreditPack {
  return {
    id: topup.key,
    points: topup.amount,
    amountCents: topup.priceAmountCents,
    currency: topup.currency,
    name: topup.name,
    // A catalog fetched without a user carries no verdict; treat that as
    // purchasable and let checkout be the one to refuse.
    eligible: topup.eligible !== false,
  };
}

/**
 * The account's credit position.
 *
 * Balances live in rx-subscription, so this is a read across the wire rather
 * than a local table. `reserved` covers holds taken for in-flight generations.
 */
export async function getBillingSummary(user: AppUser) {
  const [entitlements, catalog] = await Promise.all([getEntitlements(user), getCatalog(user)]);
  const balance = entitlements.balances.find((candidate) => candidate.unit === BALANCE_UNIT)
    ?? { amount: 0, available: 0 };
  return {
    enabled: billingConfig.enabled,
    balancePoints: balance.amount,
    availablePoints: balance.available,
    reservedPoints: balance.amount - balance.available,
    roles: entitlements.roles,
    packs: catalog.topups.map(pack),
  };
}

/** The purchasable packs alone, for a page that does not need the balance. */
export async function getCreditPacks(user?: AppUser) {
  const catalog = await getCatalog(user);
  return catalog.topups.map(pack);
}
