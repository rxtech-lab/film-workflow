import { describe, expect, it } from "vitest";
import { fieldsForKind, layoutForKind, marketplaceFormSchema } from "@/lib/marketplace/form-schema";
import { allowedExtensions, contentExtensions, marketplaceKinds } from "@/lib/marketplace/schema";

const schema = marketplaceFormSchema();
const details = schema.sections[0];

describe("marketplace form schema", () => {
  it("describes every kind, with the extensions each slot accepts", () => {
    expect(schema.layouts.map((layout) => layout.kind)).toEqual([...marketplaceKinds]);
    for (const kind of marketplaceKinds) {
      const layout = layoutForKind(schema, kind);
      expect(layout.content.extensions).toEqual(contentExtensions[kind]);
      expect(layout.previewImage.extensions).toEqual(allowedExtensions(kind, "preview-image"));
      expect(layout.previewVideo?.extensions).toEqual(allowedExtensions(kind, "preview-video"));
    }
  });

  it("says how each kind's content is produced", () => {
    expect(layoutForKind(schema, "project_template").content.editor).toBe("template");
    expect(layoutForKind(schema, "effect").content.editor).toBe("descriptor");
    expect(layoutForKind(schema, "transition").content.editor).toBe("descriptor");
    expect(layoutForKind(schema, "footage").content.editor).toBe("upload");
    // A Remotion composition is an uploaded archive, not structured content.
    expect(layoutForKind(schema, "remotion").content.editor).toBe("upload");
    expect(layoutForKind(schema, "remotion").content.extensions).toEqual(["zip"]);
    // Nothing is edited inline any more; the kind that was is gone.
    expect(schema.layouts.map((layout) => layout.content.editor)).not.toContain("text");
    // Only templates are previewed with mock images.
    expect(marketplaceFormSchema().layouts.filter((layout) => layout.mockPreview).map((layout) => layout.kind)).toEqual(["project_template"]);
  });

  it("offers the app the generators and film sources a kind can use", () => {
    expect(layoutForKind(schema, "footage").generators).toEqual(["video", "image"]);
    expect(layoutForKind(schema, "audio").generators).toEqual(["music", "image"]);
    expect(layoutForKind(schema, "font").generators).toEqual(["image"]);
    expect(layoutForKind(schema, "footage").filmAsset).toBe(true);
    expect(layoutForKind(schema, "font").filmAsset).toBe(false);
  });

  it("keeps kind-specific fields out of the other kinds", () => {
    expect(fieldsForKind(details, "font").map((field) => field.id)).toContain("metadata.fontFamily");
    expect(fieldsForKind(details, "audio").map((field) => field.id)).not.toContain("metadata.fontFamily");
    // Every field id the clients bind to is a path into `ItemInput`.
    expect(fieldsForKind(details, "audio").map((field) => field.id)).toEqual([
      "kind", "categoryId", "title", "description", "pricePoints", "metadata.tags",
    ]);
  });

  it("locks the kind once the item exists, because its files match it", () => {
    expect(details.fields.find((field) => field.id === "kind")?.lockedWhenSaved).toBe(true);
    expect(details.fields.find((field) => field.id === "kind")?.options?.map((option) => option.value)).toEqual([...marketplaceKinds]);
    expect(details.fields.find((field) => field.id === "categoryId")?.optionsSource).toBe("categories");
  });
});
