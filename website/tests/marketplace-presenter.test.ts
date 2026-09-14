import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const row = {
  id: "item-1", kind: "font" as const, categoryId: "cat-1", category: "serif", categoryName: "Serif", title: "Rx Serif", description: "A serif.", pricePoints: 120,
  previewImageKey: "marketplace/item-1/preview-image/a.png", previewVideoKey: null,
  contentKey: "marketplace/item-1/content/secret.ttf", contentFilename: "RxSerif.ttf", contentSizeBytes: 12_345, contentType: "font/ttf",
  metadata: { fontFamily: "Rx Serif" }, status: "published" as const, createdBy: "admin",
  translations: { "zh-Hans": { title: "Rx 衬线体", description: "一款衬线字体。" } },
  categoryTranslations: { "zh-Hans": { name: "衬线" } },
  createdAt: new Date("2026-01-01T00:00:00Z"), updatedAt: new Date("2026-01-02T00:00:00Z"), publishedAt: new Date("2026-01-03T00:00:00Z"),
};

describe("marketplace presenter", () => {
  beforeEach(() => {
    vi.resetModules();
    process.env.S3_BUCKET = "film-workflow";
    process.env.S3_PUBLIC_URL = "https://media.filmstudio.rxlab.app";
  });

  it("emits snake_case with public preview URLs and never the content key", async () => {
    const { toWireItem } = await import("@/lib/marketplace/presenter");
    const wire = await toWireItem(row, true);
    expect(wire).toMatchObject({
      id: "item-1", kind: "font", category: "serif", category_name: "Serif", price_points: 120, owned: true,
      preview_image_url: "https://media.filmstudio.rxlab.app/marketplace/item-1/preview-image/a.png",
      preview_video_url: null, content_filename: "RxSerif.ttf", content_size_bytes: 12_345,
      published_at: "2026-01-03T00:00:00.000Z",
    });
    expect(JSON.stringify(wire)).not.toContain("secret.ttf");
    expect(JSON.stringify(wire)).not.toContain("contentKey");
  });

  it("answers in the negotiated locale, and falls back per field to the text as written", async () => {
    const { toWireItem } = await import("@/lib/marketplace/presenter");
    expect(await toWireItem(row, false, "zh-Hans")).toMatchObject({
      title: "Rx 衬线体", description: "一款衬线字体。", category_name: "衬线",
    });
    // Nothing translated for this item: the English it was written in stands.
    const untranslated = { ...row, translations: {}, categoryTranslations: {} };
    expect(await toWireItem(untranslated, false, "zh-Hans")).toMatchObject({
      title: "Rx Serif", description: "A serif.", category_name: "Serif",
    });
    // A title translated but a description not: only the missing one falls back.
    const partial = { ...row, translations: { "zh-Hans": { title: "Rx 衬线体" } } };
    expect(await toWireItem(partial, false, "zh-Hans")).toMatchObject({ title: "Rx 衬线体", description: "A serif." });
  });

  it("leaves the admin API the text an editor typed, not a translation of it", async () => {
    const { toWireItem } = await import("@/lib/marketplace/presenter");
    expect(await toWireItem(row, false)).toMatchObject({ title: "Rx Serif", description: "A serif.", category_name: "Serif" });
  });
});
