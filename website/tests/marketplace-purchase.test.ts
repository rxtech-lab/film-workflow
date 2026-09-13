import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

type Item = { id: string; status: string; pricePoints: number; title: string; kind: string };

function setup(item: Item, options: { existing?: boolean; shortfall?: number; billing?: boolean } = {}) {
  const purchases: Array<Record<string, unknown>> = [];
  const billing = { reserve: vi.fn(), settle: vi.fn(), release: vi.fn() };
  vi.doMock("@/lib/marketplace/repository", () => ({
    requireItem: async () => item,
    findPurchase: async () => (options.existing ? { id: "p-existing", itemId: item.id, pointsCharged: item.pricePoints } : undefined),
    insertPurchase: async (row: Record<string, unknown>) => { purchases.push(row); return { id: "p-new", ...row }; },
  }));
  vi.doMock("@/lib/billing/config", () => ({ billingConfig: { enabled: options.billing ?? true, reservationTtlSeconds: 60 } }));
  vi.doMock("@/lib/billing/subscription", () => ({
    reserveBalance: billing.reserve.mockResolvedValue({ reservationId: "res-1", amount: item.pricePoints, available: 500, expiresAt: null, duplicate: false }),
    settleReservation: billing.settle.mockResolvedValue({ operationSettledAmount: item.pricePoints - (options.shortfall ?? 0), operationShortfallAmount: options.shortfall ?? 0, remainingReserved: 0, balanceAfter: 380, status: "closed", duplicate: false }),
    releaseReservation: billing.release.mockResolvedValue({ released: true }),
  }));
  return { purchases, billing };
}

const user = { id: "user-a", name: "A", email: "a@example.com", roles: ["user"] };
const paid: Item = { id: "item-1", status: "published", pricePoints: 120, title: "Bars Swipe", kind: "transition" };

describe("purchaseItem", () => {
  beforeEach(() => vi.resetModules());
  afterEach(() => vi.doUnmock("@/lib/marketplace/repository"));

  it("records a free item without touching billing", async () => {
    const { purchases, billing } = setup({ ...paid, pricePoints: 0 });
    const { purchaseItem } = await import("@/lib/marketplace/purchase");
    const result = await purchaseItem(user, paid.id);
    expect(result.alreadyOwned).toBe(false);
    expect(purchases[0]).toMatchObject({ userId: "user-a", itemId: "item-1", pointsCharged: 0, idempotencyKey: "marketplace:user-a:item-1" });
    expect(billing.reserve).not.toHaveBeenCalled();
  });

  it("holds and settles the full price for a paid item", async () => {
    const { purchases, billing } = setup(paid);
    const { purchaseItem } = await import("@/lib/marketplace/purchase");
    const result = await purchaseItem(user, paid.id);
    expect(billing.reserve).toHaveBeenCalledWith(expect.objectContaining({ amount: 120, idempotencyKey: "marketplace:user-a:item-1" }));
    expect(billing.settle).toHaveBeenCalledWith(expect.objectContaining({ reservationId: "res-1", amount: 120, idempotencyKey: "marketplace:user-a:item-1:settle" }));
    expect(purchases[0]).toMatchObject({ pointsCharged: 120, reservationId: "res-1" });
    expect(result.alreadyOwned).toBe(false);
  });

  it("returns the existing purchase without billing again", async () => {
    const { purchases, billing } = setup(paid, { existing: true });
    const { purchaseItem } = await import("@/lib/marketplace/purchase");
    const result = await purchaseItem(user, paid.id);
    expect(result.alreadyOwned).toBe(true);
    expect(result.purchase.id).toBe("p-existing");
    expect(purchases).toHaveLength(0);
    expect(billing.reserve).not.toHaveBeenCalled();
  });

  it("refuses a partly covered settlement and hands the hold back", async () => {
    const { purchases, billing } = setup(paid, { shortfall: 20 });
    const { purchaseItem } = await import("@/lib/marketplace/purchase");
    const { InsufficientCreditsError } = await import("@/lib/billing/errors");
    await expect(purchaseItem(user, paid.id)).rejects.toBeInstanceOf(InsufficientCreditsError);
    expect(billing.release).toHaveBeenCalled();
    expect(purchases).toHaveLength(0);
  });

  it("does not sell drafts", async () => {
    setup({ ...paid, status: "draft" });
    const { purchaseItem } = await import("@/lib/marketplace/purchase");
    await expect(purchaseItem(user, paid.id)).rejects.toThrow("NOT_FOUND");
  });
});
