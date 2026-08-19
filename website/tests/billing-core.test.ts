import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

describe("RxFilm billing rules", () => {
  it("rounds every positive provider cost up and keeps no remainder", async () => {
    process.env.BILLING_MIN_CHARGE_POINTS = "1";
    const { pointsFromCost } = await import("@/lib/billing/repository");
    expect(pointsFromCost(0)).toBe(0);
    expect(pointsFromCost(1)).toBe(1);
    expect(pointsFromCost(1_000_000)).toBe(1);
    expect(pointsFromCost(1_000_001)).toBe(2);
  });

  it("prices exact and wildcard unit models and fails closed", async () => {
    const { unitPrice, unitCostNanoUsd } = await import("@/lib/billing/unit-pricing");
    expect(unitPrice("openai", "gpt-image-1:high", "images")?.nanoUsdPerUnit).toBe(167_000_000);
    expect(unitPrice("openai", "gpt-image-1-custom", "images")?.nanoUsdPerUnit).toBe(42_000_000);
    expect(() => unitCostNanoUsd({ provider: "google", model: "unknown", unit: "images", units: 1 })).toThrow(/PRICE_NOT_FOUND/);
  });

  it("keeps every direct-provider catalog model covered by the pricing table", async () => {
    const { DIRECT_MODEL_CATALOG } = await import("@/lib/ai/catalog");
    expect(DIRECT_MODEL_CATALOG.length).toBeGreaterThan(0);
    expect(DIRECT_MODEL_CATALOG.every((entry) => entry.provider !== "gateway" && entry.estimate)).toBe(true);
    // Image models are discovered live — from the gateway and from Google's
    // model list — so none may be hand-listed here.
    expect(DIRECT_MODEL_CATALOG.some((entry) => entry.capability === "image")).toBe(false);
  });

  it("offers a live Google image model only when the pricing table covers it exactly", async () => {
    const { googleImagePrice } = await import("@/lib/ai/catalog");
    // Flat-priced models ignore the resolution and fall through to a bare row.
    expect(googleImagePrice("imagen-4.0-ultra-generate-001")?.nanoUsdPerUnit).toBe(60_000_000);
    expect(googleImagePrice("gemini-2.5-flash-image", "2K")?.nanoUsdPerUnit).toBe(39_000_000);
    expect(googleImagePrice("imagen-9.0-unreleased")).toBeNull();
  });

  it("bills a Gemini image at the resolution the request asked for", async () => {
    const { googleImagePrice } = await import("@/lib/ai/catalog");
    expect(googleImagePrice("gemini-3.1-flash-image")?.nanoUsdPerUnit).toBe(67_000_000);
    expect(googleImagePrice("gemini-3.1-flash-image", "4K")?.nanoUsdPerUnit).toBe(151_000_000);
    expect(googleImagePrice("gemini-3-pro-image", "4K")?.nanoUsdPerUnit).toBe(240_000_000);
    // A preview id is the same model at the same rate as its GA promotion.
    expect(googleImagePrice("gemini-3.1-flash-image-preview", "2K")?.nanoUsdPerUnit).toBe(101_000_000);
    // A tiered model has no bare row, so an unpriced tier fails closed.
    expect(googleImagePrice("gemini-3.1-flash-image", "8K")).toBeNull();
  });

  it("classifies Google image models by their generation methods", async () => {
    const { googleImageMode } = await import("@/lib/ai/google-models");
    expect(googleImageMode({ id: "imagen-4.0-generate-001", supportedGenerationMethods: ["predict"] })).toBe("predict");
    expect(googleImageMode({ id: "gemini-3.1-flash-image-preview", supportedGenerationMethods: ["generateContent"] })).toBe("generateContent");
    // Veo is long-running video, and a plain chat model emits no image.
    expect(googleImageMode({ id: "veo-3.0-generate-001", supportedGenerationMethods: ["predictLongRunning"] })).toBeNull();
    expect(googleImageMode({ id: "gemini-3-pro-preview", supportedGenerationMethods: ["generateContent"] })).toBeNull();
  });

  it("rejects price rows older than 180 days", async () => {
    const { UNIT_PRICES } = await import("@/lib/billing/unit-pricing");
    const cutoff = new Date("2026-08-13T00:00:00Z").getTime() - 180 * 24 * 60 * 60 * 1000;
    expect(UNIT_PRICES.every((entry) => new Date(`${entry.reviewedAt}T00:00:00Z`).getTime() >= cutoff)).toBe(true);
  });
});
