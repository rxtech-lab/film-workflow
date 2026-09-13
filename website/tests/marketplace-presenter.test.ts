import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const row = {
  id: "item-1", kind: "font" as const, categoryId: "cat-1", category: "serif", categoryName: "Serif", title: "Rx Serif", description: "A serif.", pricePoints: 120,
  previewImageKey: "marketplace/item-1/preview-image/a.png", previewVideoKey: null,
  contentKey: "marketplace/item-1/content/secret.ttf", contentFilename: "RxSerif.ttf", contentSizeBytes: 12_345, contentType: "font/ttf",
  metadata: { fontFamily: "Rx Serif" }, status: "published" as const, createdBy: "admin",
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
});
