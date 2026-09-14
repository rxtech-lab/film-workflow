"use client";

import { DeleteMarketplaceItem } from "./marketplace-delete-item";
import { IconField } from "./marketplace-icon-field";
import { MarketplaceLyricsEditor } from "./marketplace-lyrics-editor";
import { TemplateEditor, emptyTemplate } from "./project-template-editor";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, useTransition } from "react";
import {
  createCategory,
  createItem,
  createUploadUrl,
  finalizeUpload,
  publishItem,
  removeAsset,
  saveDescriptor,
  saveContent,
  updateItem,
} from "@/lib/marketplace/actions";
import {
  fieldsForKind,
  layoutForKind,
  marketplaceFormSchema,
  type FormField,
} from "@/lib/marketplace/form-schema";
import type { Locale } from "@/lib/i18n/locale";
import { TRANSLATABLE_LOCALES, type Translations } from "@/lib/i18n/translations";
import {
  allowedExtensions,
  marketplaceKindLabels,
  slugify,
  translatableFields,
  type AssetRole,
  type ItemInput,
  type ItemMetadata,
  type MarketplaceCategory,
  type MarketplaceKind,
} from "@/lib/marketplace/schema";

export type AdminItemView = {
  id: string;
  kind: MarketplaceKind;
  categoryId: string;
  title: string;
  description: string;
  pricePoints: number;
  metadata: ItemMetadata;
  /** Title and description in the other languages the app ships. */
  translations: Translations;
  status: "draft" | "published";
  previewImageUrl: string | null;
  previewVideoUrl: string | null;
  contentFilename: string | null;
  contentSizeBytes: number | null;
  updatedAt: string;
};

const field = "mt-1 w-full rounded-xl border border-line bg-elevated px-3 py-2 text-sm text-fg outline-none focus:border-accent";
const label = "block text-xs font-medium text-muted";
const primary = "rounded-full bg-accent px-4 py-2 text-sm font-medium text-black disabled:opacity-40";
const secondary = "rounded-full border border-line px-4 py-2 text-sm hover:bg-elevated disabled:opacity-40";

/** The one description of this form; the Mac app fetches the same thing over HTTP. */
const formSchema = marketplaceFormSchema();

const slotTitles: Record<AssetRole, string> = { "preview-image": "preview image", "preview-video": "preview video", content: "content file" };

const uploadOrder: AssetRole[] = ["content", "preview-image", "preview-video"];

const descriptorTemplate = (kind: MarketplaceKind) => kind === "transition"
  ? JSON.stringify({ format: 1, id: "mp.bars-swipe", kind: "transition", name: "Bars Swipe", summary: "Sliding bars reveal the next clip.", filter: "CIBarsSwipeTransition", progressKey: "inputTime", progressCurve: "linear", inputs: { from: "inputImage", to: "inputTargetImage" }, parameters: [{ id: "angle", title: "Angle", filterKey: "inputAngle", control: { type: "number", min: 0, max: 6.283, step: 0.01 }, default: 3.14 }, { id: "width", title: "Bar Width", filterKey: "inputWidth", control: { type: "number", min: 2, max: 300, step: 1 }, default: 30, scale: "shortSide" }] }, null, 2)
  : JSON.stringify({ format: 1, id: "mp.vignette", kind: "effect", name: "Vignette", summary: "Darken the corners of the picture.", filter: "CIVignette", parameters: [{ id: "intensity", title: "Intensity", filterKey: "inputIntensity", control: { type: "number", min: 0, max: 1, step: 0.01 }, default: 0.5 }, { id: "radius", title: "Radius", filterKey: "inputRadius", control: { type: "number", min: 0, max: 2, step: 0.01 }, default: 1 }] }, null, 2);

function errorMessage(cause: unknown, fallback: string) {
  return cause instanceof Error ? cause.message : fallback;
}

export function MarketplaceItemForm({ item, descriptorText, categories: initialCategories, initialError = "" }: {
  item: AdminItemView | null;
  descriptorText: string;
  categories: MarketplaceCategory[];
  initialError?: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState(initialError);
  const [notice, setNotice] = useState("");
  const [categories, setCategories] = useState(initialCategories);
  const [kind, setKind] = useState<MarketplaceKind>(item?.kind ?? "footage");
  const [categoryId, setCategoryId] = useState(item?.categoryId ?? initialCategories.find((candidate) => candidate.kind === "footage")?.id ?? "");
  const [title, setTitle] = useState(item?.title ?? "");
  const [description, setDescription] = useState(item?.description ?? "");
  const [pricePoints, setPricePoints] = useState(item?.pricePoints ?? 0);
  const [fontFamily, setFontFamily] = useState(item?.metadata.fontFamily ?? "");
  const [tags, setTags] = useState((item?.metadata.tags ?? []).join(", "));
  const [lyricTracks, setLyricTracks] = useState(item?.metadata.lyricTracks ?? []);
  const [previewStart, setPreviewStart] = useState(item?.metadata.preview?.startSeconds ?? 0);
  const [translations, setTranslations] = useState<Translations>(item?.translations ?? {});
  // A new item has no id to upload against yet, so its files wait here until the draft exists.
  const [staged, setStaged] = useState<Partial<Record<AssetRole, File>>>({});
  const [templateText, setTemplateText] = useState(item?.kind === "project_template" && descriptorText ? descriptorText : JSON.stringify(emptyTemplate));
  // Kinds whose content is plain text — today the Remotion prompt.
  const [mockPreview, setMockPreview] = useState(item?.metadata.preview?.mock ?? false);
  const [stagedDescriptor, setStagedDescriptor] = useState(descriptorText || descriptorTemplate(kind));
  const [descriptorEdited, setDescriptorEdited] = useState(Boolean(descriptorText));
  const layout = layoutForKind(formSchema, kind);
  const kindCategories = categories.filter((candidate) => candidate.kind === kind);

  function changeKind(next: MarketplaceKind) {
    setKind(next);
    const current = categories.find((candidate) => candidate.id === categoryId);
    if (!current || current.kind !== next) setCategoryId(categories.find((candidate) => candidate.kind === next)?.id ?? "");
    // A staged content file for one kind is not valid for another; previews carry over.
    setStaged((previous) => ({ ...previous, content: undefined }));
    if (!descriptorEdited) setStagedDescriptor(descriptorTemplate(next));
  }

  function input(): ItemInput {
    const metadata: ItemMetadata = { ...(item?.metadata ?? {}) };
    if (kind === "audio") metadata.lyricTracks = lyricTracks;
    if (kind === "font") metadata.fontFamily = fontFamily.trim() || undefined; else delete metadata.fontFamily;
    const parsedTags = tags.split(",").map((tag) => tag.trim()).filter(Boolean);
    metadata.tags = parsedTags.length > 0 ? parsedTags : undefined;
    return { kind, categoryId, title: title.trim(), description: description.trim(), pricePoints, metadata, translations };
  }

  /** Field id from the schema -> the state it edits. */
  const values: Record<string, string> = {
    kind,
    title,
    description,
    pricePoints: String(pricePoints),
    "metadata.tags": tags,
    "metadata.fontFamily": fontFamily,
    // One box per translatable field per language, matching the ids the form
    // schema hands both this form and the Mac app's.
    ...Object.fromEntries(TRANSLATABLE_LOCALES.flatMap((locale) =>
      translatableFields.item.map((name) => [`translations.${locale}.${name}`, translations[locale]?.[name] ?? ""]))),
  };

  function setValue(id: string, next: string) {
    if (id.startsWith("translations.")) {
      const [, locale, name] = id.split(".");
      setTranslations((previous) => ({ ...previous, [locale as Locale]: { ...previous[locale as Locale], [name]: next } }));
      return;
    }
    if (id === "kind") { changeKind(next as MarketplaceKind); return; }
    if (id === "title") { setTitle(next); return; }
    if (id === "description") { setDescription(next); return; }
    if (id === "pricePoints") { setPricePoints(Math.max(0, Math.floor(Number(next) || 0))); return; }
    if (id === "metadata.tags") { setTags(next); return; }
    if (id === "metadata.fontFamily") setFontFamily(next);
  }

  function run(work: () => Promise<{ ok: true } | { ok: false; error: string }>, success?: string) {
    setError("");
    setNotice("");
    startTransition(async () => {
      const result = await work();
      if (!result.ok) { setError(result.error); return; }
      if (success) setNotice(success);
      router.refresh();
    });
  }

  /** Create the draft, then push every staged file (and the descriptor) at it before opening the edit page. */
  function create() {
    setError("");
    setNotice("");
    startTransition(async () => {
      const result = await createItem(input());
      if (!result.ok) { setError(result.error); return; }
      const created = { id: result.id, kind };
      const failures: string[] = [];
      if (layout.content.editor === "template") {
        const saved = await saveContent(created.id, templateText);
        if (!saved.ok) failures.push(saved.error);
      }
      if (layout.content.editor === "descriptor") {
        setNotice("Saving descriptor…");
        const saved = await saveDescriptor(created.id, stagedDescriptor);
        if (!saved.ok) failures.push(saved.error);
      }
      for (const role of uploadOrder) {
        const file = staged[role];
        if (!file) continue;
        setNotice(`Uploading ${slotTitles[role]}…`);
        try {
          await uploadAsset(created, role, file, (fraction) => setNotice(`Uploading ${slotTitles[role]} ${Math.round(fraction * 100)}%`), mockPreview, previewStart);
        } catch (cause) {
          failures.push(`${slotTitles[role]}: ${errorMessage(cause, "the upload failed.")}`);
        }
      }
      const query = failures.length > 0 ? `?error=${encodeURIComponent(`Draft created, but ${failures.join(" ")}`)}` : "";
      router.push(`/admin/marketplace/${created.id}${query}`);
    });
  }

  function save() {
    if (!item) { create(); return; }
    run(() => updateItem(item.id, input()), "Saved.");
  }

  const canSave = !pending && Boolean(title.trim()) && Boolean(categoryId);
  const canPublish = item ? item.status === "published" || Boolean(item.contentFilename) : false;

  return (
    <div className="mt-8 grid gap-6">
      {formSchema.sections.map((section) => (
        <section key={section.id} className="rounded-2xl border border-line bg-surface p-6">
          <h2 className="text-lg font-semibold">{section.title}</h2>
          {section.help ? <p className="mt-1 text-sm text-muted">{section.help}</p> : null}
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            {fieldsForKind(section, kind).map((schemaField) => schemaField.id === "categoryId"
              ? <CategoryPicker key={schemaField.id} field={schemaField} kind={kind} categories={kindCategories} value={categoryId} onChange={setCategoryId} onCreated={(category) => { setCategories((previous) => [...previous, category]); setCategoryId(category.id); }} onError={setError} disabled={pending} />
              : <FormControl key={schemaField.id} field={schemaField} value={values[schemaField.id] ?? ""} onChange={(next) => setValue(schemaField.id, next)} disabled={pending || (Boolean(schemaField.lockedWhenSaved) && Boolean(item))} />)}
          </div>
        </section>
      ))}

      {kind === "audio" ? <MarketplaceLyricsEditor tracks={lyricTracks} onChange={setLyricTracks} disabled={pending}
        itemId={item?.id} previewUrl={item?.previewVideoUrl} previewStart={item?.metadata.preview?.startSeconds}
        stagedAudio={staged.content} /> : null}

      <section className="rounded-2xl border border-line bg-surface p-6">
        <h2 className="text-lg font-semibold">{marketplaceKindLabels[kind]} files</h2>
        <p className="mt-1 text-sm text-muted">{item ? "Uploads go straight to storage; each slot is recorded once the file has landed." : "Files are uploaded right after the draft is created."}</p>
        <div className="mt-4 grid gap-5">
          {layout.content.editor === "template" ? <TemplateEditor text={templateText} onChange={setTemplateText} /> : null}
          {layout.content.editor === "template" && item ? <button type="button" className={secondary} disabled={pending} onClick={() => run(() => saveContent(item.id, templateText), "Template saved.")}>Save template</button> : null}
          {layout.mockPreview ? <label className="text-sm"><input type="checkbox" checked={mockPreview} onChange={(event) => setMockPreview(event.target.checked)} /> This preview uses mock images, without original project footage.</label> : null}
          {layout.content.editor === "upload"
            ? <UploadSlot item={item} kind={kind} role="content" title={layout.content.title} hint={layout.content.hint} staged={staged.content ?? null} onStage={(file) => setStaged((previous) => ({ ...previous, content: file ?? undefined }))} current={item?.contentFilename ? <span className="text-sm">{item.contentFilename}{item.contentSizeBytes ? <span className="text-muted"> · {(item.contentSizeBytes / 1_048_576).toFixed(1)} MB</span> : null}</span> : null} onError={setError} disabled={pending} />
            : layout.content.editor === "descriptor" ? <DescriptorEditor item={item} text={stagedDescriptor} onChange={(text) => { setStagedDescriptor(text); setDescriptorEdited(true); }} onError={setError} disabled={pending} /> : null}
          <UploadSlot item={item} kind={kind} role="preview-image" title={layout.previewImage.title} hint={layout.previewImage.hint} staged={staged["preview-image"] ?? null} onStage={(file) => setStaged((previous) => ({ ...previous, "preview-image": file ?? undefined }))} current={item?.previewImageUrl ? <PreviewStill src={item.previewImageUrl} /> : null} onError={setError} disabled={pending} />
          {layout.previewVideo
            ? <UploadSlot item={item} kind={kind} role="preview-video" mockPreview={mockPreview} previewStart={previewStart} title={layout.previewVideo.title} hint={layout.previewVideo.hint} staged={staged["preview-video"] ?? null} onStage={(file) => setStaged((previous) => ({ ...previous, "preview-video": file ?? undefined }))} current={item?.previewVideoUrl ? (kind === "audio" ? <span className="text-sm">Audio preview uploaded</span> : kind === "sound_effect" ? <audio src={item.previewVideoUrl} controls /> : <video src={item.previewVideoUrl} className="h-24 rounded-lg" controls />) : null} onError={setError} disabled={pending} />
            : null}
          {kind === "audio" ? <label className="text-sm">Preview starts at (seconds into the full song)
            <input type="number" min={0} max={86400} step={0.1} value={previewStart} disabled={pending} className={field}
              onChange={(event) => setPreviewStart(Math.max(0, Number(event.target.value) || 0))} />
            <span className="text-xs text-muted">Set this before uploading an excerpt so its lyrics stay in sync.</span>
          </label> : null}
        </div>
      </section>

      <section className="rounded-2xl border border-line bg-surface p-6">
        <div className="flex flex-wrap items-center gap-3">
          <button type="button" className={primary} onClick={save} disabled={!canSave}>{item ? "Save" : "Create draft"}</button>
          {item ? <button type="button" className={secondary} disabled={pending || !canPublish} title={canPublish ? undefined : "Upload the content file first"} onClick={() => run(() => publishItem(item.id, item.status !== "published"), item.status === "published" ? "Unpublished." : "Published.")}>{item.status === "published" ? "Unpublish" : "Publish"}</button> : null}
          {item ? <DeleteMarketplaceItem id={item.id} title={item.title} className={`${secondary} text-red-400`} disabled={pending} returnToList onError={setError} /> : null}
          {notice ? <span className="text-sm text-muted">{notice}</span> : null}
        </div>
        {error ? <p className="mt-4 text-sm text-red-400" role="alert">{error}</p> : null}
      </section>
    </div>
  );
}

function CategoryPicker({ field: schemaField, kind, categories, value, onChange, onCreated, onError, disabled }: {
  schemaField?: never;
  field: FormField;
  kind: MarketplaceKind;
  categories: MarketplaceCategory[];
  value: string;
  onChange: (id: string) => void;
  onCreated: (category: MarketplaceCategory) => void;
  onError: (message: string) => void;
  disabled: boolean;
}) {
  const [creating, setCreating] = useState(false);

  return (
    <div>
      <label className={label}>{schemaField.title}
        <div className="mt-1 flex gap-2">
          <select className={`${field} mt-0`} value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled}>
            <option value="">{categories.length === 0 ? `No ${marketplaceKindLabels[kind].toLowerCase()} categories yet` : "Choose…"}</option>
            {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
          </select>
          <button type="button" className={secondary} onClick={() => setCreating(true)} disabled={disabled}>New</button>
        </div>
      </label>
      {creating ? <NewCategoryDialog kind={kind} onClose={() => setCreating(false)} onCreated={(category) => { onCreated(category); setCreating(false); }} onError={onError} /> : null}
    </div>
  );
}

/**
 * Modal for adding a category to the current kind. Mounted only while open so
 * the name field starts empty each time; closing via Escape or the backdrop
 * goes through the dialog's own `close` event.
 */
function NewCategoryDialog({ kind, onClose, onCreated, onError }: {
  kind: MarketplaceKind;
  onClose: () => void;
  onCreated: (category: MarketplaceCategory) => void;
  onError: (message: string) => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [name, setName] = useState("");
  const [icon, setIcon] = useState("");
  const [error, setError] = useState("");
  const [pending, startTransition] = useTransition();
  const slug = slugify(name);
  const kindLabel = marketplaceKindLabels[kind].toLowerCase();

  useEffect(() => {
    const dialog = dialogRef.current;
    if (dialog && !dialog.open) dialog.showModal();
  }, []);

  function add() {
    setError("");
    onError("");
    startTransition(async () => {
      const result = await createCategory({ kind, name, icon: icon.trim() || undefined });
      if (!result.ok) { setError(result.error); return; }
      onCreated(result.category);
    });
  }

  return (
    <dialog
      ref={dialogRef}
      className="m-auto w-[min(28rem,calc(100vw-2rem))] rounded-2xl border border-line bg-surface p-0 text-fg shadow-2xl backdrop:bg-black/60 backdrop:backdrop-blur-sm"
      onClose={onClose}
      onCancel={(event) => { if (pending) event.preventDefault(); }}
      onClick={(event) => { if (event.target === event.currentTarget && !pending) event.currentTarget.close(); }}
      aria-labelledby="new-category-title"
    >
      <form
        className="p-6"
        onSubmit={(event) => { event.preventDefault(); if (slug && !pending) add(); }}
      >
        <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">{marketplaceKindLabels[kind]}</p>
        <h2 id="new-category-title" className="mt-2 text-xl font-semibold">New category</h2>
        <p className="mt-1 text-sm text-muted">Categories are per kind, so this one only shows up for {kindLabel} items.</p>
        <label className={`${label} mt-5`}>Name
          <input
            className={field}
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder={`e.g. ${kind === "font" ? "Serif" : kind === "audio" ? "Ambient" : "Nature"}`}
            maxLength={64}
            disabled={pending}
            autoFocus
          />
        </label>
        <p className="mt-2 min-h-4 text-xs text-muted">{slug ? <>Slug: <span className="font-mono">{slug}</span></> : name ? "The name needs at least one letter or digit." : null}</p>
        <IconField value={icon} onChange={setIcon} disabled={pending} />
        {error ? <p className="mt-3 text-sm text-red-400" role="alert">{error}</p> : null}
        <div className="mt-6 flex justify-end gap-2">
          <button type="button" className={secondary} onClick={() => dialogRef.current?.close()} disabled={pending}>Cancel</button>
          <button type="submit" className={primary} disabled={pending || !slug}>{pending ? "Adding…" : "Add category"}</button>
        </div>
      </form>
    </dialog>
  );
}

/**
 * One schema field. The schema says what it is called, what it accepts and
 * which kinds it belongs to; this only decides which control draws it.
 */
function FormControl({ field: schemaField, value, onChange, disabled }: {
  field: FormField;
  value: string;
  onChange: (value: string) => void;
  disabled: boolean;
}) {
  const wide = schemaField.type === "multiline" || schemaField.type === "text";
  const help = schemaField.help ? <span className="mt-1 block text-xs font-normal text-muted">{schemaField.help}</span> : null;
  const control = schemaField.type === "multiline"
    ? <textarea className={`${field} min-h-28`} value={value} onChange={(event) => onChange(event.target.value)} maxLength={schemaField.maxLength} disabled={disabled} />
    : schemaField.type === "select"
      ? <select className={field} value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled}>{(schemaField.options ?? []).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select>
      : schemaField.type === "number"
        ? <input className={field} type="number" min={schemaField.min} max={schemaField.max} step={1} value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled} />
        : <input className={field} value={value} onChange={(event) => onChange(event.target.value)} placeholder={schemaField.placeholder} maxLength={schemaField.maxLength} disabled={disabled} />;
  return <label className={`${label}${wide ? " sm:col-span-2" : ""}`}>{schemaField.title}{control}{help}</label>;
}

/** Admin previews come from R2 with no image loader configured, so this stays a plain img. */
function PreviewStill({ src }: { src: string }) {
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={src} alt="" className="h-24 rounded-lg object-cover" />;
}

function readVideoMetadata(file: File): Promise<Partial<ItemMetadata>> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata";
    video.onloadedmetadata = () => { resolve({ durationSeconds: Math.round(video.duration * 1000) / 1000, width: video.videoWidth || undefined, height: video.videoHeight || undefined }); URL.revokeObjectURL(url); };
    video.onerror = () => { resolve({}); URL.revokeObjectURL(url); };
    video.src = url;
  });
}

function readImageMetadata(file: File): Promise<Partial<ItemMetadata>> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => { resolve({ width: image.naturalWidth || undefined, height: image.naturalHeight || undefined }); URL.revokeObjectURL(url); };
    image.onerror = () => { resolve({}); URL.revokeObjectURL(url); };
    image.src = url;
  });
}

function readAudioDuration(file: File): Promise<Partial<ItemMetadata>> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const audio = document.createElement("audio");
    audio.preload = "metadata";
    audio.onloadedmetadata = () => { resolve({ durationSeconds: Math.round(audio.duration * 1000) / 1000 }); URL.revokeObjectURL(url); };
    audio.onerror = () => { resolve({}); URL.revokeObjectURL(url); };
    audio.src = url;
  });
}

function putWithProgress(url: string, headers: Record<string, string>, file: File, onProgress: (fraction: number) => void = () => {}, mockPreview = false) {
  return new Promise<void>((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open("PUT", url);
    for (const [name, value] of Object.entries(headers)) {
      if (name.toLowerCase() !== "content-length") request.setRequestHeader(name, value);
    }
    request.upload.onprogress = (event) => { if (event.lengthComputable) onProgress(event.loaded / event.total); };
    request.onload = () => (request.status >= 200 && request.status < 300 ? resolve() : reject(new Error(`Storage rejected the upload (${request.status}).`)));
    request.onerror = () => reject(new Error("The upload could not reach storage."));
    request.send(file);
  });
}

/** Presigned PUT straight to storage, then record the slot with whatever the browser could read from the file. */
async function uploadAsset(item: { id: string; kind: MarketplaceKind }, role: AssetRole, file: File, onProgress: (fraction: number) => void = () => {}, mockPreview = false, previewStart = 0) {
  const contentType = file.type || "application/octet-stream";
  const authorized = await createUploadUrl({ itemId: item.id, role, filename: file.name, contentType, sizeBytes: file.size });
  if (!authorized.ok) throw new Error(authorized.error);
  await putWithProgress(authorized.uploadURL, authorized.headers, file, onProgress);
  // Footage content is a clip or a still; a Remotion archive is a zip the
  // browser can read nothing out of, so its facts come from the app instead.
  const isStill = /\.(png|jpe?g|webp)$/i.test(file.name);
  const metadata = (role === "preview-video" && /\.(mp3|wav|m4a|aac)$/i.test(file.name)) ? await readAudioDuration(file)
    : role === "preview-video" || (role === "content" && item.kind === "footage" && !isStill)
    ? await readVideoMetadata(file)
    : role === "content" && item.kind === "footage" ? await readImageMetadata(file)
    : role === "content" && (item.kind === "audio" || item.kind === "sound_effect") ? await readAudioDuration(file) : {};
  const finalized = await finalizeUpload({ itemId: item.id, role, filename: file.name, contentType, sizeBytes: file.size, objectKey: authorized.objectKey, metadata: role === "preview-video" ? { ...metadata, preview: { mock: mockPreview, startSeconds: previewStart } } : metadata });
  if (!finalized.ok) throw new Error(finalized.error);
}

/**
 * One file slot. With a saved item the file uploads as soon as it is picked;
 * without one it is staged and the form uploads it after creating the draft.
 */
function UploadSlot({ item, kind, role, title, hint, staged, onStage, current, onError, disabled, mockPreview = false, previewStart = 0 }: {
  previewStart?: number;
  mockPreview?: boolean;
  item: AdminItemView | null;
  kind: MarketplaceKind;
  role: AssetRole;
  title: string;
  hint: string;
  staged: File | null;
  onStage: (file: File | null) => void;
  current: React.ReactNode;
  onError: (message: string) => void;
  disabled: boolean;
}) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [progress, setProgress] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [failedFile, setFailedFile] = useState<File | null>(null);
  const [pending, startTransition] = useTransition();
  const accept = allowedExtensions(kind, role).map((extension) => `.${extension}`).join(",");
  const busy = disabled || progress !== null || pending;

  async function upload(saved: AdminItemView, file: File) {
    onError("");
    setUploadError(null);
    setFailedFile(null);
    setProgress(0);
    try {
      await uploadAsset(saved, role, file, setProgress, mockPreview, previewStart);
      startTransition(() => router.refresh());
    } catch (cause) {
      const message = errorMessage(cause, "The upload failed.");
      setUploadError(message);
      setFailedFile(file);
      onError(`${title}: ${message}`);
    } finally {
      setProgress(null);
    }
  }

  function pick(file: File | undefined) {
    if (inputRef.current) inputRef.current.value = "";
    if (!file) return;
    if (item) void upload(item, file); else onStage(file);
  }

  const shown = item ? current : staged ? <span className="text-sm">{staged.name}<span className="text-muted"> · {(staged.size / 1_048_576).toFixed(1)} MB · uploads on create</span></span> : null;

  return (
    <div className="grid gap-2 sm:grid-cols-[160px_1fr] sm:items-start">
      <div><span className="text-sm font-medium">{title}</span><p className="text-xs text-muted">{hint}</p></div>
      <div className="flex flex-wrap items-center gap-3">
        {shown ?? <span className="text-sm text-muted">Nothing {item ? "uploaded" : "chosen"}</span>}
        <input ref={inputRef} type="file" accept={accept} className="hidden" onChange={(event) => pick(event.target.files?.[0])} />
        <button type="button" className={secondary} disabled={busy} onClick={() => inputRef.current?.click()}>{progress !== null ? `Uploading ${Math.round(progress * 100)}%` : shown ? "Replace" : "Choose file"}</button>
        {item && current ? <button type="button" className="text-sm text-muted hover:text-red-400" disabled={busy} onClick={() => startTransition(async () => { const result = await removeAsset(item.id, role); if (!result.ok) onError(result.error); router.refresh(); })}>Remove</button> : null}
        {!item && staged ? <button type="button" className="text-sm text-muted hover:text-red-400" disabled={busy} onClick={() => onStage(null)}>Clear</button> : null}
        {uploadError ? <div className="w-full space-y-2" role="alert">
          <p className="text-sm text-red-400">{failedFile?.name}: {uploadError}</p>
          {item && failedFile ? <button type="button" className={secondary} disabled={busy} onClick={() => void upload(item, failedFile)}>Retry upload</button> : null}
        </div> : null}
      </div>
    </div>
  );
}

/**
 * Effects and transitions are small JSON files edited in place. With a saved
 * item the button writes straight to storage; without one the text is saved
 * as part of creating the draft.
 */
function DescriptorEditor({ item, text, onChange, onError, disabled }: {
  item: AdminItemView | null;
  text: string;
  onChange: (text: string) => void;
  onError: (message: string) => void;
  disabled: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [saved, setSaved] = useState(false);
  let parseError = "";
  try { JSON.parse(text); } catch (cause) { parseError = errorMessage(cause, "Invalid JSON"); }
  return (
    <div className="grid gap-2">
      <div className="flex items-center justify-between"><span className="text-sm font-medium">Descriptor</span>{item?.contentFilename ? <small className="text-xs text-muted">{item.contentFilename}</small> : null}</div>
      <p className="text-xs text-muted">A built-in Core Image filter and how the inspector&apos;s controls map onto its inputs. Validated when saved.</p>
      <textarea className={`${field} min-h-72 font-mono text-xs`} value={text} onChange={(event) => { onChange(event.target.value); setSaved(false); }} spellCheck={false} disabled={disabled || pending} />
      <div className="flex items-center gap-3">
        {item ? <button type="button" className={primary} disabled={disabled || pending || Boolean(parseError)} onClick={() => { onError(""); startTransition(async () => { const result = await saveDescriptor(item.id, text); if (!result.ok) { onError(result.error); return; } setSaved(true); router.refresh(); }); }}>Save descriptor</button> : null}
        {parseError ? <span className="text-xs text-red-400">{parseError}</span> : saved ? <span className="text-xs text-muted">Saved.</span> : !item ? <span className="text-xs text-muted">Saved with the draft.</span> : null}
      </div>
    </div>
  );
}
