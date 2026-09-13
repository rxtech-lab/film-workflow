import {
  allowedExtensions,
  contentExtensions,
  marketplaceKindLabels,
  marketplaceKinds,
  type AssetRole,
  type MarketplaceKind,
} from "./schema";

/**
 * The authoring form, described once and rendered twice: the admin pages
 * import it directly, the Mac app fetches it from
 * `GET /api/v1/admin/marketplace/form-schema`. Adding a field here puts it on
 * both without shipping an app update, so the two forms cannot drift.
 *
 * Only the shape of the form lives here. Validation stays in `schema.ts`,
 * which the server applies to whatever either client sends.
 */

export type FormFieldType = "text" | "multiline" | "number" | "tags" | "select" | "toggle";

export type FormOption = { value: string; label: string };

export type FormField = {
  /** Dotted path into `ItemInput`, e.g. `metadata.fontFamily`. */
  id: string;
  title: string;
  type: FormFieldType;
  required?: boolean;
  help?: string;
  placeholder?: string;
  maxLength?: number;
  min?: number;
  max?: number;
  /** Fixed choices for a `select`. */
  options?: FormOption[];
  /** Choices the client loads itself, because they change without a deploy. */
  optionsSource?: "categories";
  /** Shown only for these kinds; absent means every kind. */
  kinds?: MarketplaceKind[];
  /** Cannot be changed once the item exists — the files already match it. */
  lockedWhenSaved?: boolean;
};

export type FormSection = { id: string; title: string; help?: string; fields: FormField[] };

/** How the content file is produced: uploaded, or edited in the form. */
export type ContentEditor = "upload" | "descriptor" | "template" | "text";

export type FileSlot = { role: AssetRole; title: string; hint: string; extensions: string[] };

/** What one kind needs beyond the shared fields. */
export type KindLayout = {
  kind: MarketplaceKind;
  label: string;
  content: FileSlot & { editor: ContentEditor };
  previewImage: FileSlot;
  previewVideo: FileSlot | null;
  /** Generators the app offers for this kind, in the order it shows them. */
  generators: ("video" | "music" | "image")[];
  /** The app can take this kind's content straight from the open film. */
  filmAsset: boolean;
  /** Previews must be made with mock images rather than the original footage. */
  mockPreview: boolean;
};

export type MarketplaceFormSchema = {
  version: 1;
  sections: FormSection[];
  layouts: KindLayout[];
};

const kindOptions: FormOption[] = marketplaceKinds.map((kind) => ({ value: kind, label: marketplaceKindLabels[kind] }));

const detailFields: FormField[] = [
  { id: "kind", title: "Item type", type: "select", required: true, options: kindOptions, lockedWhenSaved: true },
  { id: "categoryId", title: "Category", type: "select", required: true, optionsSource: "categories" },
  { id: "title", title: "Title", type: "text", required: true, maxLength: 160 },
  { id: "description", title: "Description", type: "multiline", maxLength: 4000, help: "One or two lines for the card and the detail sheet." },
  { id: "pricePoints", title: "Price", type: "number", min: 0, max: 1_000_000, help: "Credits · 0 is free." },
  { id: "metadata.tags", title: "Tags", type: "tags", help: "Separated by commas." },
  {
    id: "metadata.fontFamily",
    title: "Font family",
    type: "text",
    kinds: ["font"],
    maxLength: 120,
    placeholder: "Exactly as the font reports it, e.g. Inter",
  },
];

const contentSlots: Record<MarketplaceKind, { title: string; hint: string; editor: ContentEditor }> = {
  project_template: { title: "Template", editor: "template", hint: "The shot plan, prompts and references the app fills in when someone starts a film from this." },
  footage: { title: "Footage file", editor: "upload", hint: "MP4 or MOV. Duration and dimensions are read from the file." },
  remotion_prompt: { title: "Prompt", editor: "text", hint: "Markdown or plain text. The first lines become the card excerpt." },
  audio: { title: "Music file", editor: "upload", hint: "MP3, WAV, M4A or AAC. Duration is read from the file." },
  sound_effect: { title: "Sound file", editor: "upload", hint: "MP3, WAV, M4A or AAC. Duration is read from the file." },
  font: { title: "Font file", editor: "upload", hint: "TTF or OTF." },
  transition: { title: "Transition definition", editor: "descriptor", hint: "A Core Image filter and the controls the inspector shows for it." },
  effect: { title: "Effect definition", editor: "descriptor", hint: "A Core Image filter and the controls the inspector shows for it." },
};

const previewImageHints: Record<MarketplaceKind, string> = {
  project_template: "Cover art for this template.",
  footage: "The still on the card. Aim for a frame from the clip.",
  remotion_prompt: "A render of what the prompt produces.",
  audio: "Cover art for the card.",
  sound_effect: "Cover art for the card.",
  font: "A specimen: the alphabet or a sample line set in the font.",
  transition: "A frame mid-transition.",
  effect: "A frame with the effect applied.",
};

const generators: Record<MarketplaceKind, KindLayout["generators"]> = {
  project_template: ["image"],
  footage: ["video", "image"],
  remotion_prompt: ["image"],
  audio: ["music", "image"],
  sound_effect: ["image"],
  font: ["image"],
  transition: ["image"],
  effect: ["image"],
};

const filmAssetKinds: MarketplaceKind[] = ["footage", "audio", "sound_effect"];

function layout(kind: MarketplaceKind): KindLayout {
  const content = contentSlots[kind];
  return {
    kind,
    label: marketplaceKindLabels[kind],
    content: { role: "content", title: content.title, hint: content.hint, editor: content.editor, extensions: contentExtensions[kind] },
    previewImage: { role: "preview-image", title: "Preview image", hint: previewImageHints[kind], extensions: allowedExtensions(kind, "preview-image") },
    previewVideo: {
      role: "preview-video",
      title: "Preview video",
      hint: kind === "project_template"
        ? "Required for publication. A short video made using mock images."
        : "Optional. A short demonstration, up to 15 seconds, with sound.",
      extensions: allowedExtensions(kind, "preview-video"),
    },
    generators: generators[kind],
    filmAsset: filmAssetKinds.includes(kind),
    mockPreview: kind === "project_template",
  };
}

export function marketplaceFormSchema(): MarketplaceFormSchema {
  return {
    version: 1,
    sections: [
      { id: "details", title: "Details", fields: detailFields },
    ],
    layouts: marketplaceKinds.map(layout),
  };
}

/** The fields of `section`, minus the ones another kind owns. */
export function fieldsForKind(section: FormSection, kind: MarketplaceKind) {
  return section.fields.filter((field) => !field.kinds || field.kinds.includes(kind));
}

export function layoutForKind(schema: MarketplaceFormSchema, kind: MarketplaceKind) {
  return schema.layouts.find((candidate) => candidate.kind === kind) ?? layout(kind);
}
