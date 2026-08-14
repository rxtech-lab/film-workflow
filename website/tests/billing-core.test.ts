import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

describe("RxFilm billing rules", () => {
  it("rounds every positive provider cost up and keeps no remainder", async () => {
    process.env.BILLING_MIN_CHARGE_POINTS = "1";
    const { pointsFromCost } = await import("@/lib/billing/repository");
    expect(pointsFromCost(0)).toEqual({ points: 0, remainderNanoUsd: 0 });
    expect(pointsFromCost(1)).toEqual({ points: 1, remainderNanoUsd: 0 });
    expect(pointsFromCost(1_000_000)).toEqual({ points: 1, remainderNanoUsd: 0 });
    expect(pointsFromCost(1_000_001)).toEqual({ points: 2, remainderNanoUsd: 0 });
  });

  it("prices exact and wildcard unit models and fails closed", async () => {
    const { unitPrice, unitCostNanoUsd } = await import("@/lib/billing/unit-pricing");
    expect(unitPrice("openai", "gpt-image-1:high", "images")?.nanoUsdPerUnit).toBe(167_000_000);
    expect(unitPrice("openai", "gpt-image-1-custom", "images")?.nanoUsdPerUnit).toBe(42_000_000);
    expect(() => unitCostNanoUsd({ provider: "google", model: "unknown", unit: "images", units: 1 })).toThrow(/PRICE_NOT_FOUND/);
  });

  it("keeps every direct-provider catalog model covered by the pricing table", async () => {
    const { DIRECT_MODEL_CATALOG, GATEWAY_FALLBACK_CATALOG } = await import("@/lib/ai/catalog");
    expect(DIRECT_MODEL_CATALOG.length).toBeGreaterThan(0);
    expect(DIRECT_MODEL_CATALOG.every((entry) => entry.provider !== "gateway" && entry.estimate)).toBe(true);
    expect(GATEWAY_FALLBACK_CATALOG).toContainEqual(expect.objectContaining({
      id: "openai/gpt-image-1",
      provider: "gateway",
      capability: "image",
      estimate: expect.objectContaining({ unit: "images" }),
    }));
  });

  it("rejects price rows older than 180 days", async () => {
    const { UNIT_PRICES } = await import("@/lib/billing/unit-pricing");
    const cutoff = new Date("2026-08-13T00:00:00Z").getTime() - 180 * 24 * 60 * 60 * 1000;
    expect(UNIT_PRICES.every((entry) => new Date(`${entry.reviewedAt}T00:00:00Z`).getTime() >= cutoff)).toBe(true);
  });
});
