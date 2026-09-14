import { describe, expect, it } from "vitest";
import { CATALOG_VERSION, categoryInput, categoryPatch, descriptorSchema, isAllowedFilename, itemInput, kindAllowed, kindPatch, kindsForCatalogVersion, listQuery, marketplaceKinds, mediaTypeForContent, parseDescriptor, resolutionLabel, slugify } from "@/lib/marketplace/schema";

const categoryId = "6f1c0d6e-3b2a-4c8e-9d1f-2a3b4c5d6e7f";

const transition = {
  format: 1, id: "mp.bars-swipe", kind: "transition", name: "Bars Swipe", summary: "Sliding bars.",
  filter: "CIBarsSwipeTransition", progressKey: "inputTime", inputs: { from: "inputImage", to: "inputTargetImage" },
  parameters: [
    { id: "angle", title: "Angle", filterKey: "inputAngle", control: { type: "number", min: 0, max: 6.283, step: 0.01 }, default: 3.14 },
    { id: "direction", title: "Direction", filterKey: "inputAngle", control: { type: "choice", options: ["Left", "Right"], map: { Left: 0, Right: 3.14 } }, default: "Right" },
  ],
};

describe("marketplace schema", () => {
  it("parses list queries with defaults and bounds", () => {
    expect(listQuery.parse({})).toEqual({ catalog_version: 1, page: 1 });
    expect(listQuery.parse({ kind: "font", page: "3", q: " serif " })).toEqual({ catalog_version: 1, kind: "font", page: 3, q: "serif" });
    expect(listQuery.safeParse({ kind: "plugin" }).success).toBe(false);
    expect(listQuery.safeParse({ page: "0" }).success).toBe(false);
  });

  it("requires a title, a category id and a non-negative price", () => {
    expect(itemInput.safeParse({ kind: "audio", categoryId, title: "Rain", pricePoints: 0 }).success).toBe(true);
    expect(itemInput.safeParse({ kind: "audio", categoryId: "", title: "Rain", pricePoints: 0 }).success).toBe(false);
    expect(itemInput.safeParse({ kind: "audio", categoryId: "lo-fi", title: "Rain", pricePoints: 0 }).success).toBe(false);
    expect(itemInput.safeParse({ kind: "audio", categoryId, title: "Rain", pricePoints: -1 }).success).toBe(false);
  });

  it("derives a category slug from the name unless one is given", () => {
    expect(slugify("  Lo-Fi Beats! ")).toBe("lo-fi-beats");
    expect(slugify("日本語")).toBe("");
    expect(categoryInput.parse({ kind: "audio", name: " Lo-Fi Beats " })).toEqual({ kind: "audio", name: "Lo-Fi Beats", slug: "lo-fi-beats", icon: "folder", translations: {} });
    expect(categoryInput.parse({ kind: "audio", name: "Lo-Fi", slug: "chill" }).slug).toBe("chill");
    expect(categoryInput.safeParse({ kind: "audio", name: "Lo-Fi", slug: "Not A Slug" }).success).toBe(false);
    expect(categoryInput.safeParse({ kind: "audio", name: "!!!" }).success).toBe(false);
    expect(categoryInput.safeParse({ kind: "plugin", name: "x" }).success).toBe(false);
  });

  it("takes an SF Symbol for a category and falls back to the folder", () => {
    expect(categoryInput.parse({ kind: "audio", name: "Lo-Fi", icon: "music.note" }).icon).toBe("music.note");
    expect(categoryInput.parse({ kind: "audio", name: "Lo-Fi", icon: "" }).icon).toBe("folder");
    expect(categoryInput.safeParse({ kind: "audio", name: "Lo-Fi", icon: "music note" }).success).toBe(false);
    expect(categoryInput.safeParse({ kind: "audio", name: "Lo-Fi", icon: "music/note" }).success).toBe(false);
    expect(categoryPatch.parse({ id: categoryId, name: " Lo-Fi ", icon: "waveform" })).toEqual({ id: categoryId, name: "Lo-Fi", icon: "waveform", translations: {} });
    expect(categoryPatch.parse({ id: categoryId, name: "Lo-Fi" }).icon).toBe("folder");
  });

  it("takes a label, symbol and sidebar order for a kind", () => {
    expect(kindPatch.parse({ kind: "font", label: " Typefaces ", icon: "textformat", sortOrder: "3" }))
      .toEqual({ kind: "font", label: "Typefaces", icon: "textformat", sortOrder: 3, translations: {} });
    expect(kindPatch.parse({ kind: "font", label: "Typefaces" }).sortOrder).toBe(0);
    expect(kindPatch.safeParse({ kind: "font", label: "" }).success).toBe(false);
    expect(kindPatch.safeParse({ kind: "plugin", label: "Plugins" }).success).toBe(false);
    expect(kindPatch.safeParse({ kind: "font", label: "Typefaces", sortOrder: -1 }).success).toBe(false);
    // The label in the other languages the app ships, blanks and unknown
    // locales dropped rather than stored.
    expect(kindPatch.parse({ kind: "font", label: "Typefaces", translations: { "zh-Hans": { label: " 字体 " }, fr: { label: "Polices" } } }).translations)
      .toEqual({ "zh-Hans": { label: "字体" } });
    expect(categoryInput.parse({ kind: "audio", name: "Lo-Fi", translations: { "zh-Hans": { name: "" } } }).translations).toEqual({});
  });

  it("restricts content files by kind and previews by role", () => {
    expect(isAllowedFilename("font", "content", "Inter.TTF")).toBe(true);
    expect(isAllowedFilename("font", "content", "Inter.zip")).toBe(false);
    expect(isAllowedFilename("remotion", "content", "composition.zip")).toBe(true);
    expect(isAllowedFilename("remotion", "content", "brief.md")).toBe(false);
    expect(isAllowedFilename("footage", "content", "clip.mov")).toBe(true);
    // Footage carries stills as well as clips; the file picks the shelf.
    expect(isAllowedFilename("footage", "content", "frame.png")).toBe(true);
    expect(isAllowedFilename("footage", "content", "frame.webp")).toBe(true);
    expect(isAllowedFilename("footage", "preview-image", "poster.webp")).toBe(true);
    expect(isAllowedFilename("footage", "preview-image", "poster.mp4")).toBe(false);
    expect(isAllowedFilename("transition", "content", "swipe.json")).toBe(true);
  });

  it("accepts the reference transition descriptor", () => {
    const parsed = descriptorSchema.parse(transition);
    expect(parsed.parameters).toHaveLength(2);
    expect(parsed.progressCurve).toBeUndefined();
  });

  it("rejects a transition without a progress key and an effect with two inputs", () => {
    const { progressKey: _omitted, ...withoutProgress } = transition;
    void _omitted;
    expect(descriptorSchema.safeParse(withoutProgress).success).toBe(false);
    expect(descriptorSchema.safeParse({ ...transition, kind: "effect", filter: "CIVignette", inputs: transition.inputs }).success).toBe(false);
  });

  it("rejects malformed filter names, duplicate ids and mismatched defaults", () => {
    expect(descriptorSchema.safeParse({ ...transition, filter: "rm -rf" }).success).toBe(false);
    expect(descriptorSchema.safeParse({ ...transition, parameters: [transition.parameters[0], transition.parameters[0]] }).success).toBe(false);
    expect(descriptorSchema.safeParse({ ...transition, parameters: [{ ...transition.parameters[0], default: "big" }] }).success).toBe(false);
    expect(descriptorSchema.safeParse({ ...transition, parameters: [{ ...transition.parameters[1], default: "Up" }] }).success).toBe(false);
  });

  it("names the failing path when parsing text", () => {
    expect(() => parseDescriptor("{")).toThrow(/DESCRIPTOR_INVALID:not JSON/);
    expect(() => parseDescriptor(JSON.stringify({ ...transition, filter: "x" }))).toThrow(/DESCRIPTOR_INVALID:filter/);
    expect(parseDescriptor(JSON.stringify(transition)).id).toBe("mp.bars-swipe");
  });
});

describe("footage media types", () => {
  it("reads the media type off the content filename, and only for files it knows", () => {
    expect(mediaTypeForContent("harbor.mp4")).toBe("video");
    expect(mediaTypeForContent("harbor.MOV")).toBe("video");
    expect(mediaTypeForContent("frame.png")).toBe("image");
    expect(mediaTypeForContent("frame.jpeg")).toBe("image");
    expect(mediaTypeForContent("frame.webp")).toBe("image");
    expect(mediaTypeForContent("composition.zip")).toBeUndefined();
    expect(mediaTypeForContent("noextension")).toBeUndefined();
  });

  it("filters the catalog by media type, and rejects one footage cannot be", () => {
    expect(listQuery.safeParse({ media_type: "image" }).success).toBe(true);
    expect(listQuery.safeParse({ media_type: "video" }).success).toBe(true);
    expect(listQuery.safeParse({ media_type: "audio" }).success).toBe(false);
  });

  it("accepts a media type on item metadata", () => {
    const parsed = itemInput.safeParse({
      kind: "footage", categoryId, title: "Harbor", pricePoints: 0, metadata: { mediaType: "image" },
    });
    expect(parsed.success).toBe(true);
  });
});

describe("resolution buckets", () => {
  it("buckets by the long-side convention people expect", () => {
    expect(resolutionLabel({ width: 3840, height: 2160 })).toBe("4K");
    expect(resolutionLabel({ width: 2560, height: 1440 })).toBe("1440p");
    expect(resolutionLabel({ width: 1920, height: 1080 })).toBe("1080p");
    expect(resolutionLabel({ width: 1280, height: 720 })).toBe("720p");
    expect(resolutionLabel({ width: 640, height: 480 })).toBe("SD");
  });

  it("measures the short side, so a portrait clip reads like its landscape twin", () => {
    expect(resolutionLabel({ width: 1080, height: 1920 })).toBe("1080p");
    expect(resolutionLabel({ width: 2160, height: 3840 })).toBe("4K");
  });

  it("has nothing to say without dimensions", () => {
    expect(resolutionLabel({})).toBeUndefined();
    expect(resolutionLabel({ width: 0, height: 0 })).toBeUndefined();
  });
});

describe("catalog versions", () => {
  it("withholds a kind from a client that could not decode it", () => {
    expect(kindsForCatalogVersion(1)).not.toContain("project_template");
    expect(kindsForCatalogVersion(1)).not.toContain("remotion");
    expect(kindsForCatalogVersion(2)).toContain("project_template");
    // The whole point of the bump: a v2 client's page must not carry one.
    expect(kindsForCatalogVersion(2)).not.toContain("remotion");
    expect(kindsForCatalogVersion(3)).toEqual([...marketplaceKinds]);
  });

  it("lets every kind through at the current version", () => {
    for (const kind of marketplaceKinds) expect(kindAllowed(kind, CATALOG_VERSION)).toBe(true);
  });

  it("accepts the current catalog version on the wire", () => {
    expect(listQuery.safeParse({ catalog_version: String(CATALOG_VERSION) }).success).toBe(true);
    expect(listQuery.safeParse({ catalog_version: String(CATALOG_VERSION + 1) }).success).toBe(false);
    expect(listQuery.parse({}).catalog_version).toBe(1);
  });
});
