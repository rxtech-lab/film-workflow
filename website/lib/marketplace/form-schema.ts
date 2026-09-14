import { DEFAULT_LOCALE, type Locale } from "@/lib/i18n/locale";
import { t, translatedFieldTitle, type MessageKey } from "@/lib/i18n/messages";
import { localeNames, TRANSLATABLE_LOCALES } from "@/lib/i18n/translations";
import { kindName } from "./i18n";
import {
  allowedExtensions,
  contentExtensions,
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
 *
 * Every string in it is built for one locale: the Mac app is sent the form in
 * the language its `Accept-Language` asked for, and the admin website, whose
 * surrounding chrome is English, takes the default.
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
export type ContentEditor = "upload" | "descriptor" | "template";

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

function kindOptions(locale: Locale): FormOption[] {
  return marketplaceKinds.map((kind) => ({ value: kind, label: kindName(locale, kind) }));
}

function detailFields(locale: Locale): FormField[] {
  return [
    { id: "kind", title: t(locale, "form.field.kind"), type: "select", required: true, options: kindOptions(locale), lockedWhenSaved: true },
    { id: "categoryId", title: t(locale, "form.field.category"), type: "select", required: true, optionsSource: "categories" },
    { id: "title", title: t(locale, "form.field.title"), type: "text", required: true, maxLength: 160 },
    { id: "description", title: t(locale, "form.field.description"), type: "multiline", maxLength: 4000, help: t(locale, "form.field.description.help") },
    { id: "pricePoints", title: t(locale, "form.field.price"), type: "number", min: 0, max: 1_000_000, help: t(locale, "form.field.price.help") },
    { id: "metadata.tags", title: t(locale, "form.field.tags"), type: "tags", help: t(locale, "form.field.tags.help") },
    {
      id: "metadata.fontFamily",
      title: t(locale, "form.field.fontFamily"),
      type: "text",
      kinds: ["font"],
      maxLength: 120,
      placeholder: t(locale, "form.field.fontFamily.placeholder"),
    },
  ];
}

/**
 * The same title and description again, once per language the app ships
 * besides the one the base columns hold. The id is the path into the item's
 * `translations`, so a client that has never heard of a language simply drops
 * the field — which is what the Mac app does with any id it does not know.
 */
function translationFields(locale: Locale): FormField[] {
  return TRANSLATABLE_LOCALES.flatMap((target): FormField[] => [
    { id: `translations.${target}.title`, title: translatedFieldTitle(locale, "form.field.title", localeNames[target]), type: "text", maxLength: 160 },
    { id: `translations.${target}.description`, title: translatedFieldTitle(locale, "form.field.description", localeNames[target]), type: "multiline", maxLength: 4000 },
  ]);
}

const contentEditors: Record<MarketplaceKind, ContentEditor> = {
  project_template: "template",
  footage: "upload",
  remotion: "upload",
  audio: "upload",
  sound_effect: "upload",
  font: "upload",
  transition: "descriptor",
  effect: "descriptor",
};

const generators: Record<MarketplaceKind, KindLayout["generators"]> = {
  project_template: ["image"],
  footage: ["video", "image"],
  remotion: ["image"],
  audio: ["music", "image"],
  sound_effect: ["image"],
  font: ["image"],
  transition: ["image"],
  effect: ["image"],
};

const filmAssetKinds: MarketplaceKind[] = ["footage", "audio", "sound_effect"];

function layout(kind: MarketplaceKind, locale: Locale): KindLayout {
  return {
    kind,
    label: kindName(locale, kind),
    content: {
      role: "content",
      title: t(locale, `form.content.${kind}.title` as MessageKey),
      hint: t(locale, `form.content.${kind}.hint` as MessageKey),
      editor: contentEditors[kind],
      extensions: contentExtensions[kind],
    },
    previewImage: {
      role: "preview-image",
      title: t(locale, "form.previewImage.title"),
      hint: t(locale, `form.previewImage.${kind}.hint` as MessageKey),
      extensions: allowedExtensions(kind, "preview-image"),
    },
    previewVideo: {
      role: "preview-video",
      title: t(locale, kind === "audio" || kind === "sound_effect" ? "form.previewAudio.title" : "form.previewVideo.title"),
      hint: t(locale, kind === "audio" || kind === "sound_effect" ? "form.previewAudio.hint" : kind === "project_template" ? "form.previewVideo.hint.template" : "form.previewVideo.hint.default"),
      extensions: allowedExtensions(kind, "preview-video"),
    },
    generators: generators[kind],
    filmAsset: filmAssetKinds.includes(kind),
    mockPreview: kind === "project_template",
  };
}

export function marketplaceFormSchema(locale: Locale = DEFAULT_LOCALE): MarketplaceFormSchema {
  return {
    version: 1,
    sections: [
      { id: "details", title: t(locale, "form.section.details"), fields: detailFields(locale) },
      { id: "translations", title: t(locale, "form.section.translations"), help: t(locale, "form.section.translations.help"), fields: translationFields(locale) },
    ],
    layouts: marketplaceKinds.map((kind) => layout(kind, locale)),
  };
}

/** The fields of `section`, minus the ones another kind owns. */
export function fieldsForKind(section: FormSection, kind: MarketplaceKind) {
  return section.fields.filter((field) => !field.kinds || field.kinds.includes(kind));
}

export function layoutForKind(schema: MarketplaceFormSchema, kind: MarketplaceKind, locale: Locale = DEFAULT_LOCALE) {
  return schema.layouts.find((candidate) => candidate.kind === kind) ?? layout(kind, locale);
}
