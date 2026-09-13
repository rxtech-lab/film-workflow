import { describe, expect, it } from "vitest";
import { categoryInput, descriptorSchema, isAllowedFilename, itemInput, listQuery, parseDescriptor, slugify } from "@/lib/marketplace/schema";

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
    expect(listQuery.parse({})).toEqual({ page: 1 });
    expect(listQuery.parse({ kind: "font", page: "3", q: " serif " })).toEqual({ kind: "font", page: 3, q: "serif" });
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
    expect(categoryInput.parse({ kind: "audio", name: " Lo-Fi Beats " })).toEqual({ kind: "audio", name: "Lo-Fi Beats", slug: "lo-fi-beats" });
    expect(categoryInput.parse({ kind: "audio", name: "Lo-Fi", slug: "chill" }).slug).toBe("chill");
    expect(categoryInput.safeParse({ kind: "audio", name: "Lo-Fi", slug: "Not A Slug" }).success).toBe(false);
    expect(categoryInput.safeParse({ kind: "audio", name: "!!!" }).success).toBe(false);
    expect(categoryInput.safeParse({ kind: "plugin", name: "x" }).success).toBe(false);
  });

  it("restricts content files by kind and previews by role", () => {
    expect(isAllowedFilename("font", "content", "Inter.TTF")).toBe(true);
    expect(isAllowedFilename("font", "content", "Inter.zip")).toBe(false);
    expect(isAllowedFilename("remotion_prompt", "content", "brief.md")).toBe(true);
    expect(isAllowedFilename("footage", "content", "clip.mov")).toBe(true);
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
