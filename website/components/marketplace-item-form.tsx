"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, useTransition } from "react";
import {
  createCategory,
  createItem,
  createUploadUrl,
  deleteItemAndReturn,
  finalizeUpload,
  publishItem,
  removeAsset,
  saveDescriptor,
  updateItem,
} from "@/lib/marketplace/actions";
import {
  allowedExtensions,
  marketplaceKindLabels,
  marketplaceKinds,
  slugify,
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

/**
 * What each kind needs from the admin. `content: null` means the content file
 * is a CIFilter descriptor edited in place rather than uploaded; preview
 * video only makes sense for kinds that look like something.
 */
type KindLayout = {
  content: { title: string; hint: string } | null;
  previewImageHint: string;
  previewVideo: boolean;
};

const kindLayouts: Record<MarketplaceKind, KindLayout> = {
  footage: {
    content: { title: "Footage file", hint: "MP4 or MOV. Duration and dimensions are read from the file." },
    previewImageHint: "The still on the card. Aim for a frame from the clip.",
    previewVideo: true,
  },
  remotion_prompt: {
    content: { title: "Prompt file", hint: "Markdown or plain text. The first lines become the card excerpt." },
    previewImageHint: "A render of what the prompt produces.",
    previewVideo: true,
  },
  audio: {
    content: { title: "Music file", hint: "MP3, WAV, M4A or AAC. Duration is read from the file." },
    previewImageHint: "Cover art for the card.",
    previewVideo: false,
  },
  sound_effect: {
    content: { title: "Sound file", hint: "MP3, WAV, M4A or AAC. Duration is read from the file." },
    previewImageHint: "Cover art for the card.",
    previewVideo: false,
  },
  font: {
    content: { title: "Font file", hint: "TTF or OTF." },
    previewImageHint: "A specimen: the alphabet or a sample line set in the font.",
    previewVideo: false,
  },
  transition: {
    content: null,
    previewImageHint: "A frame mid-transition.",
    previewVideo: true,
  },
  effect: {
    content: null,
    previewImageHint: "A frame with the effect applied.",
    previewVideo: true,
  },
};

const slotTitles: Record<AssetRole, string> = { "preview-image": "preview image", "preview-video": "preview video", content: "content file" };

const uploadOrder: AssetRole[] = ["content", "preview-image", "preview-video"];

const descriptorTemplate = (kind: MarketplaceKind) => kind === "transition"
  ? JSON.stringify({ format: 1, id: "mp.bars-swipe", kind: "transition", name: "Bars Swipe", summary: "Sliding bars reveal the next clip.", filter: "CIBarsSwipeTransition", progressKey: "inputTime", progressCurve: "linear", inputs: { from: "inputImage", to: "inputTargetImage" }, parameters: [{ id: "angle", title: "Angle", filterKey: "inputAngle", control: { type: "number", min: 0, max: 6.283, step: 0.01 }, default: 3.14 }, { id: "width", title: "Bar Width", filterKey: "inputWidth", control: { type: "number", min: 2, max: 300, step: 1 }, default: 30, scale: "shortSide" }] }, null, 2)
  : JSON.stringify({ format: 1, id: "mp.vignette", kind: "effect", name: "Vignette", summary: "Darken the corners of the picture.", filter: "CIVignette", parameters: [{ id: "intensity", title: "Intensity", filterKey: "inputIntensity", control: { type: "number", min: 0, max: 1, step: 0.01 }, default: 0.5 }, { id: "radius", title: "Radius", filterKey: "inputRadius", control: { type: "number", min: 0, max: 2, step: 0.01 }, default: 1 }] }, null, 2);

function isDescriptorKind(kind: MarketplaceKind) {
  return kindLayouts[kind].content === null;
}

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
  // A new item has no id to upload against yet, so its files wait here until the draft exists.
  const [staged, setStaged] = useState<Partial<Record<AssetRole, File>>>({});
  const [stagedDescriptor, setStagedDescriptor] = useState(descriptorText || descriptorTemplate(kind));
  const [descriptorEdited, setDescriptorEdited] = useState(Boolean(descriptorText));
  const layout = kindLayouts[kind];
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
    if (kind === "font") metadata.fontFamily = fontFamily.trim() || undefined; else delete metadata.fontFamily;
    const parsedTags = tags.split(",").map((tag) => tag.trim()).filter(Boolean);
    metadata.tags = parsedTags.length > 0 ? parsedTags : undefined;
    return { kind, categoryId, title: title.trim(), description: description.trim(), pricePoints, metadata };
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
      if (isDescriptorKind(kind)) {
        setNotice("Saving descriptor…");
        const saved = await saveDescriptor(created.id, stagedDescriptor);
        if (!saved.ok) failures.push(saved.error);
      }
      for (const role of uploadOrder) {
        const file = staged[role];
        if (!file) continue;
        setNotice(`Uploading ${slotTitles[role]}…`);
        try {
          await uploadAsset(created, role, file, (fraction) => setNotice(`Uploading ${slotTitles[role]} ${Math.round(fraction * 100)}%`));
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
      <section className="rounded-2xl border border-line bg-surface p-6">
        <h2 className="text-lg font-semibold">Details</h2>
        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <label className={label}>Kind<select className={field} value={kind} onChange={(event) => changeKind(event.target.value as MarketplaceKind)} disabled={pending}>{marketplaceKinds.map((candidate) => <option key={candidate} value={candidate}>{marketplaceKindLabels[candidate]}</option>)}</select></label>
          <CategoryPicker kind={kind} categories={kindCategories} value={categoryId} onChange={setCategoryId} onCreated={(category) => { setCategories((previous) => [...previous, category]); setCategoryId(category.id); }} onError={setError} disabled={pending} />
          <label className={`${label} sm:col-span-2`}>Title<input className={field} value={title} onChange={(event) => setTitle(event.target.value)} maxLength={160} disabled={pending} /></label>
          <label className={`${label} sm:col-span-2`}>Description<textarea className={`${field} min-h-28`} value={description} onChange={(event) => setDescription(event.target.value)} maxLength={4000} disabled={pending} /></label>
          <label className={label}>Price (credits, 0 = free)<input className={field} type="number" min={0} max={1_000_000} step={1} value={pricePoints} onChange={(event) => setPricePoints(Math.max(0, Math.floor(Number(event.target.value) || 0)))} disabled={pending} /></label>
          <label className={label}>Tags (comma separated)<input className={field} value={tags} onChange={(event) => setTags(event.target.value)} disabled={pending} /></label>
          {kind === "font" ? <label className={`${label} sm:col-span-2`}>Font family name<input className={field} value={fontFamily} onChange={(event) => setFontFamily(event.target.value)} placeholder="Exactly as the font reports it, e.g. Inter" disabled={pending} /></label> : null}
        </div>
      </section>

      <section className="rounded-2xl border border-line bg-surface p-6">
        <h2 className="text-lg font-semibold">{marketplaceKindLabels[kind]} files</h2>
        <p className="mt-1 text-sm text-muted">{item ? "Uploads go straight to storage; each slot is recorded once the file has landed." : "Files are uploaded right after the draft is created."}</p>
        <div className="mt-4 grid gap-5">
          {layout.content
            ? <UploadSlot item={item} kind={kind} role="content" title={layout.content.title} hint={layout.content.hint} staged={staged.content ?? null} onStage={(file) => setStaged((previous) => ({ ...previous, content: file ?? undefined }))} current={item?.contentFilename ? <span className="text-sm">{item.contentFilename}{item.contentSizeBytes ? <span className="text-muted"> · {(item.contentSizeBytes / 1_048_576).toFixed(1)} MB</span> : null}</span> : null} onError={setError} disabled={pending} />
            : <DescriptorEditor item={item} text={stagedDescriptor} onChange={(text) => { setStagedDescriptor(text); setDescriptorEdited(true); }} onError={setError} disabled={pending} />}
          <UploadSlot item={item} kind={kind} role="preview-image" title="Preview image" hint={layout.previewImageHint} staged={staged["preview-image"] ?? null} onStage={(file) => setStaged((previous) => ({ ...previous, "preview-image": file ?? undefined }))} current={item?.previewImageUrl ? <PreviewStill src={item.previewImageUrl} /> : null} onError={setError} disabled={pending} />
          {layout.previewVideo
            ? <UploadSlot item={item} kind={kind} role="preview-video" title="Preview video" hint="Optional. A short clip the app plays on the detail page." staged={staged["preview-video"] ?? null} onStage={(file) => setStaged((previous) => ({ ...previous, "preview-video": file ?? undefined }))} current={item?.previewVideoUrl ? <video src={item.previewVideoUrl} className="h-24 rounded-lg" muted controls /> : null} onError={setError} disabled={pending} />
            : null}
        </div>
      </section>

      <section className="rounded-2xl border border-line bg-surface p-6">
        <div className="flex flex-wrap items-center gap-3">
          <button type="button" className={primary} onClick={save} disabled={!canSave}>{item ? "Save" : "Create draft"}</button>
          {item ? <button type="button" className={secondary} disabled={pending || !canPublish} title={canPublish ? undefined : "Upload the content file first"} onClick={() => run(() => publishItem(item.id, item.status !== "published"), item.status === "published" ? "Unpublished." : "Published.")}>{item.status === "published" ? "Unpublish" : "Publish"}</button> : null}
          {item ? <button type="button" className={`${secondary} text-red-400`} disabled={pending} onClick={() => { if (window.confirm("Delete this item and its files?")) run(() => deleteItemAndReturn(item.id)); }}>Delete</button> : null}
          {notice ? <span className="text-sm text-muted">{notice}</span> : null}
        </div>
        {error ? <p className="mt-4 text-sm text-red-400" role="alert">{error}</p> : null}
      </section>
    </div>
  );
}

function CategoryPicker({ kind, categories, value, onChange, onCreated, onError, disabled }: {
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
      <label className={label}>Category
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
      const result = await createCategory({ kind, name });
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
        {error ? <p className="mt-3 text-sm text-red-400" role="alert">{error}</p> : null}
        <div className="mt-6 flex justify-end gap-2">
          <button type="button" className={secondary} onClick={() => dialogRef.current?.close()} disabled={pending}>Cancel</button>
          <button type="submit" className={primary} disabled={pending || !slug}>{pending ? "Adding…" : "Add category"}</button>
        </div>
      </form>
    </dialog>
  );
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

function putWithProgress(url: string, headers: Record<string, string>, file: File, onProgress: (fraction: number) => void) {
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
async function uploadAsset(item: { id: string; kind: MarketplaceKind }, role: AssetRole, file: File, onProgress: (fraction: number) => void) {
  const contentType = file.type || "application/octet-stream";
  const authorized = await createUploadUrl({ itemId: item.id, role, filename: file.name, contentType, sizeBytes: file.size });
  if (!authorized.ok) throw new Error(authorized.error);
  await putWithProgress(authorized.uploadURL, authorized.headers, file, onProgress);
  const metadata = role === "preview-video" || (role === "content" && item.kind === "footage")
    ? await readVideoMetadata(file)
    : role === "content" && (item.kind === "audio" || item.kind === "sound_effect") ? await readAudioDuration(file) : {};
  const finalized = await finalizeUpload({ itemId: item.id, role, filename: file.name, contentType, sizeBytes: file.size, objectKey: authorized.objectKey, metadata });
  if (!finalized.ok) throw new Error(finalized.error);
}

/**
 * One file slot. With a saved item the file uploads as soon as it is picked;
 * without one it is staged and the form uploads it after creating the draft.
 */
function UploadSlot({ item, kind, role, title, hint, staged, onStage, current, onError, disabled }: {
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
  const [pending, startTransition] = useTransition();
  const accept = allowedExtensions(kind, role).map((extension) => `.${extension}`).join(",");
  const busy = disabled || progress !== null || pending;

  async function upload(saved: AdminItemView, file: File) {
    onError("");
    setProgress(0);
    try {
      await uploadAsset(saved, role, file, setProgress);
      startTransition(() => router.refresh());
    } catch (cause) {
      onError(errorMessage(cause, "The upload failed."));
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
