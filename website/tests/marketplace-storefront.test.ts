import { describe, expect, it } from "vitest";
import { durationLabel, itemFacts, parseStorefrontQuery, previewMediaKind, priceLabel, sizeLabel, storefrontHref } from "@/lib/marketplace/storefront";

describe("marketplace storefront", () => {
  it("reads the shelf out of the URL", () => {
    expect(parseStorefrontQuery({ kind: "audio", category: "lo-fi", q: " rain ", page: "3" })).toEqual({ kind: "audio", category: "lo-fi", q: "rain", page: 3 });
    expect(parseStorefrontQuery({})).toEqual({ kind: undefined, category: undefined, q: undefined, page: 1 });
    expect(parseStorefrontQuery({ kind: ["font", "audio"] }).kind).toBe("font");
  });

  it("drops what is malformed without losing the rest", () => {
    expect(parseStorefrontQuery({ kind: "audio", category: "lo-fi", page: "-2" })).toEqual({ kind: "audio", category: "lo-fi", q: undefined, page: 1 });
    // A category without a kind to scope it is meaningless.
    expect(parseStorefrontQuery({ kind: "nonsense", category: "lo-fi", page: "x" })).toEqual({ kind: undefined, category: undefined, q: undefined, page: 1 });
  });

  it("builds links that keep the category inside its kind", () => {
    expect(storefrontHref({})).toBe("/marketplace");
    expect(storefrontHref({ kind: "audio", category: "lo-fi", page: 2 })).toBe("/marketplace?kind=audio&category=lo-fi&page=2");
    expect(storefrontHref({ category: "lo-fi", q: "rain", page: 1 })).toBe("/marketplace?q=rain");
  });

  it("formats prices, lengths and sizes", () => {
    expect(priceLabel(0)).toBe("Free");
    expect(priceLabel(1200)).toBe("1,200 credits");
    expect(durationLabel(7)).toBe("0:07");
    expect(durationLabel(245)).toBe("4:05");
    expect(durationLabel(3725)).toBe("1:02:05");
    expect(durationLabel(0)).toBeUndefined();
    expect(sizeLabel(512)).toBe("512 B");
    expect(sizeLabel(12_345)).toBe("12 KB");
    expect(sizeLabel(4_200_000)).toBe("4.2 MB");
    expect(sizeLabel(null)).toBeUndefined();
  });

  it("plays audio previews as audio", () => {
    expect(previewMediaKind("audio", "https://cdn.example/a/preview.m4a")).toBe("audio");
    expect(previewMediaKind("audio", "https://cdn.example/a/preview.mp4?sig=1")).toBe("audio");
    expect(previewMediaKind("footage", "https://cdn.example/a/preview.mp4")).toBe("video");
    expect(previewMediaKind("footage", null)).toBeNull();
  });

  it("prints the facts a card needs", () => {
    expect(itemFacts("footage", { width: 3840, height: 2160, durationSeconds: 12 })).toEqual(["4K", "0:12"]);
    expect(itemFacts("font", { fontFamily: "Rx Serif" })).toEqual(["Rx Serif"]);
    expect(itemFacts("audio", {})).toEqual([]);
  });
});
