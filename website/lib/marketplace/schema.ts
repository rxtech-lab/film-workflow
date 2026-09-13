import { z } from "zod";

/** Mirrors `marketplace_kind` in `lib/db/schema.ts`; the wire and the app use these raw strings. */
export const marketplaceKinds = [
  "footage",
  "remotion_prompt",
  "audio",
  "sound_effect",
  "font",
  "transition",
  "effect",
  "project_template",
] as const;
export type MarketplaceKind = (typeof marketplaceKinds)[number];

export const marketplaceKindLabels: Record<MarketplaceKind, string> = {
  footage: "Footage",
  remotion_prompt: "Remotion prompt",
  audio: "Music",
  sound_effect: "Sound effect",
  font: "Font",
  transition: "Transition",
  effect: "Effect",
  project_template: "Project template",
};

/**
 * What the app's sidebar shows for a kind before an admin edits it: the
 * plural label and the SF Symbol the app used to hardcode. These seed
 * `marketplace_kinds` and stand in for a row that somehow went missing.
 */
export const marketplaceKindDefaults: Record<MarketplaceKind, { label: string; icon: string; sortOrder: number }> = {
  footage: { label: "Footage", icon: "film", sortOrder: 0 },
  remotion_prompt: { label: "Remotion Prompts", icon: "text.quote", sortOrder: 1 },
  audio: { label: "Music", icon: "music.note", sortOrder: 2 },
  sound_effect: { label: "Sound Effects", icon: "waveform", sortOrder: 3 },
  font: { label: "Fonts", icon: "textformat", sortOrder: 4 },
  transition: { label: "Transitions", icon: "arrow.left.arrow.right.square", sortOrder: 5 },
  effect: { label: "Effects", icon: "wand.and.stars", sortOrder: 6 },
  project_template: { label: "Project Templates", icon: "rectangle.stack.badge.play", sortOrder: 7 },
};

export const DEFAULT_CATEGORY_ICON = "folder";

export const assetRoles = ["preview-image", "preview-video", "content"] as const;
export type AssetRole = (typeof assetRoles)[number];

const previewImageExtensions = ["jpg", "jpeg", "png", "webp"];
const previewVideoExtensions = ["mp4", "mov", "webm"];

/** What the content file of each kind may be. Enforced when an upload is authorized and again when it is finalized. */
export const contentExtensions: Record<MarketplaceKind, string[]> = {
  footage: ["mp4", "mov"],
  remotion_prompt: ["md", "txt"],
  audio: ["mp3", "wav", "m4a", "aac"],
  sound_effect: ["mp3", "wav", "m4a", "aac"],
  font: ["ttf", "otf"],
  transition: ["json"],
  effect: ["json"],
  project_template: ["json"],
};

export function allowedExtensions(kind: MarketplaceKind, role: AssetRole) {
  if (role === "preview-image") return previewImageExtensions;
  if (role === "preview-video") return previewVideoExtensions;
  return contentExtensions[kind];
}

export function fileExtension(filename: string) {
  const index = filename.lastIndexOf(".");
  return index < 0 ? "" : filename.slice(index + 1).toLowerCase();
}

export function isAllowedFilename(kind: MarketplaceKind, role: AssetRole, filename: string) {
  return allowedExtensions(kind, role).includes(fileExtension(filename));
}

export const previewMetadata = z.object({
  durationSeconds: z.number().nonnegative().optional(), width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(), mock: z.boolean().optional(),
});

export const itemMetadata = z.object({
  durationSeconds: z.number().nonnegative().optional(),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
  fontFamily: z.string().max(120).optional(),
  descriptor: z.object({ filterName: z.string().max(80), parameterCount: z.number().int().nonnegative() }).optional(),
  promptExcerpt: z.string().max(400).optional(),
  preview: previewMetadata.optional(),
  tags: z.array(z.string().min(1).max(40)).max(20).optional(),
});
export type ItemMetadata = z.infer<typeof itemMetadata>;

// MARK: - Categories

/** The wire form of a category: what the app filters by and what it groups the sidebar on. */
export const categorySlug = z.string().regex(/^[a-z0-9][a-z0-9-]{0,63}$/, "Slugs are lowercase letters, digits and dashes.");

/** "Lo-Fi Beats" → "lo-fi-beats". Empty when the name has nothing slug-worthy in it. */
export function slugify(name: string) {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);
}

/**
 * An SF Symbol name, the shape Apple uses: words joined by dots, sometimes
 * with digits or a trailing `.fill`. The server cannot know which
 * symbols the running macOS has, so it only checks the shape and the app
 * falls back to a default when `Image(systemName:)` finds nothing.
 */
const symbolPattern = /^[A-Za-z0-9]+(\.[A-Za-z0-9]+)*$/;
const symbolMessage = "Use an SF Symbol name, e.g. “music.note”.";
export const symbolName = z.string().trim().max(80).regex(symbolPattern, symbolMessage);
/** An icon field an admin may leave blank, which means "keep the default". */
const optionalIcon = z.string().trim().max(80).refine((icon) => icon === "" || symbolPattern.test(icon), symbolMessage).optional();

export const categoryInput = z.object({
  kind: z.enum(marketplaceKinds),
  name: z.string().trim().min(1).max(64),
  /** Derived from `name` when omitted. */
  slug: categorySlug.optional(),
  /** SF Symbol for the sidebar row; blank falls back to `DEFAULT_CATEGORY_ICON`. */
  icon: optionalIcon,
}).transform((input) => ({ ...input, slug: input.slug ?? slugify(input.name), icon: input.icon || DEFAULT_CATEGORY_ICON }))
  .refine((input) => input.slug.length > 0, { message: "The name needs at least one letter or digit.", path: ["name"] });
export type CategoryInput = z.infer<typeof categoryInput>;

/** Renaming or re-iconing an existing category; the slug is what items filter on, so it stays put. */
export const categoryPatch = z.object({
  id: z.string().uuid(),
  name: z.string().trim().min(1).max(64),
  icon: optionalIcon.transform((icon) => icon || DEFAULT_CATEGORY_ICON),
});
export type CategoryPatch = z.infer<typeof categoryPatch>;

/** The label and icon one kind shows in the app sidebar. */
export const kindPatch = z.object({
  kind: z.enum(marketplaceKinds),
  label: z.string().trim().min(1).max(64),
  icon: optionalIcon.transform((icon) => icon || DEFAULT_CATEGORY_ICON),
  sortOrder: z.coerce.number().int().min(0).max(999).default(0),
});
export type KindPatch = z.infer<typeof kindPatch>;

/** A category as the admin form sees it. */
export type MarketplaceCategory = { id: string; kind: MarketplaceKind; slug: string; name: string; icon: string };

export const itemInput = z.object({
  draftId: z.string().uuid().optional(),
  kind: z.enum(marketplaceKinds),
  categoryId: z.string().uuid("Pick a category."),
  title: z.string().trim().min(1).max(160),
  description: z.string().trim().max(4000).default(""),
  pricePoints: z.number().int().min(0).max(1_000_000),
  metadata: itemMetadata.default({}),
});
export type ItemInput = z.infer<typeof itemInput>;

export const listQuery = z.object({
  catalog_version: z.coerce.number().int().min(1).max(2).default(1),
  kind: z.enum(marketplaceKinds).optional(),
  /** A category slug. */
  category: z.string().trim().min(1).max(64).optional(),
  q: z.string().trim().max(100).optional(),
  page: z.coerce.number().int().min(1).default(1),
});
export type ListQuery = z.infer<typeof listQuery>;

export const uploadRequest = z.object({
  itemId: z.string().uuid(),
  role: z.enum(assetRoles),
  filename: z.string().min(1).max(255),
  contentType: z.string().min(1).max(150),
  sizeBytes: z.number().int().positive(),
});
export type UploadRequest = z.infer<typeof uploadRequest>;

export const finalizeRequest = uploadRequest.extend({
  objectKey: z.string().min(1).max(600),
  metadata: itemMetadata.optional(),
});
export type FinalizeRequest = z.infer<typeof finalizeRequest>;

// MARK: - CIFilter descriptors

const numberControl = z.object({
  type: z.literal("number"),
  min: z.number(),
  max: z.number(),
  step: z.number().positive(),
}).refine((control) => control.min < control.max, { message: "min must be below max" });

const choiceControl = z.object({
  type: z.literal("choice"),
  options: z.array(z.string().min(1).max(40)).min(1).max(16),
  /** Label → filter value, for filters that want a number where the user picks a word. */
  map: z.record(z.string(), z.number()).optional(),
});

const colorControl = z.object({ type: z.literal("color") });

export const descriptorParameter = z.object({
  id: z.string().regex(/^[a-z][a-z0-9-]{0,39}$/, "lowercase id"),
  title: z.string().min(1).max(60),
  filterKey: z.string().regex(/^input[A-Za-z0-9]+$/, "Core Image input key"),
  control: z.discriminatedUnion("type", [numberControl, choiceControl, colorControl]),
  default: z.union([z.number(), z.string()]),
  /** Multiply a relative number by a picture dimension, so preview and export match. */
  scale: z.enum(["none", "shortSide", "width", "height"]).optional(),
});

/**
 * The content file of an effect or transition item: a built-in Core Image
 * filter plus how the inspector's controls map onto its input keys. The app
 * validates the filter name against Core Image when it installs the file;
 * the server only checks the shape.
 */
export const descriptorSchema = z.object({
  format: z.literal(1),
  id: z.string().regex(/^[a-z0-9][a-z0-9.-]{2,80}$/, "descriptor id"),
  kind: z.enum(["effect", "transition"]),
  name: z.string().min(1).max(80),
  summary: z.string().max(400).default(""),
  filter: z.string().regex(/^CI[A-Za-z0-9]+$/, "Core Image filter name"),
  progressKey: z.string().regex(/^input[A-Za-z0-9]+$/).optional(),
  progressCurve: z.enum(["linear", "easeInOut"]).optional(),
  inputs: z.object({
    from: z.string().regex(/^input[A-Za-z0-9]+$/),
    to: z.string().regex(/^input[A-Za-z0-9]+$/),
  }).optional(),
  parameters: z.array(descriptorParameter).max(12).default([]),
  constants: z.record(z.string().regex(/^input[A-Za-z0-9]+$/), z.string().max(80)).optional(),
  /** Effects only: sample edge pixels outward so blurs do not fade at the border. */
  clampEdges: z.boolean().optional(),
}).superRefine((descriptor, context) => {
  if (descriptor.kind === "transition" && !descriptor.progressKey) {
    context.addIssue({ code: "custom", path: ["progressKey"], message: "Transitions need a progressKey." });
  }
  if (descriptor.kind === "effect" && descriptor.inputs) {
    context.addIssue({ code: "custom", path: ["inputs"], message: "Effects take a single input picture." });
  }
  const ids = new Set<string>();
  for (const [index, parameter] of descriptor.parameters.entries()) {
    if (ids.has(parameter.id)) context.addIssue({ code: "custom", path: ["parameters", index, "id"], message: "Duplicate parameter id." });
    ids.add(parameter.id);
    const isNumber = typeof parameter.default === "number";
    if (parameter.control.type === "number" && !isNumber) context.addIssue({ code: "custom", path: ["parameters", index, "default"], message: "Number controls need a numeric default." });
    if (parameter.control.type !== "number" && isNumber) context.addIssue({ code: "custom", path: ["parameters", index, "default"], message: "Choice and color controls need a string default." });
    if (parameter.control.type === "choice" && !isNumber && !parameter.control.options.includes(parameter.default as string)) {
      context.addIssue({ code: "custom", path: ["parameters", index, "default"], message: "Default must be one of the options." });
    }
  }
});
export type Descriptor = z.infer<typeof descriptorSchema>;

export function parseDescriptor(text: string) {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new Error("DESCRIPTOR_INVALID:not JSON"); }
  const result = descriptorSchema.safeParse(parsed);
  if (!result.success) {
    const issue = result.error.issues[0];
    throw new Error(`DESCRIPTOR_INVALID:${issue?.path.join(".") || "root"} ${issue?.message ?? ""}`.trim());
  }
  return result.data;
}
