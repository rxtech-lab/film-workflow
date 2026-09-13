import "server-only";
import { isAdmin, type AppUser } from "@/lib/auth";
import { ForbiddenError } from "@/lib/auth/bearer";
import { ZodError } from "zod";
import { parseTemplate, templateSummary } from "./template";
import { validateAssetHeader } from "./upload-validation";
import {
  countPurchases,
  getItem,
  deleteItemRow,
  getCategory,
  insertCategory,
  insertItem,
  updateCategory as updateCategoryRow,
  upsertKind,
  requireItem,
  setItemStatus,
  updateItem as updateItemRow,
  updateItemAssets,
} from "@/lib/marketplace/repository";
import {
  allowedExtensions,
  categoryInput,
  categoryPatch,
  kindPatch,
  finalizeRequest,
  isAllowedFilename,
  itemInput,
  parseDescriptor,
  uploadRequest,
  type AssetRole,
  type ItemInput,
  type MarketplaceCategory,
  type MarketplaceKind,
} from "@/lib/marketplace/schema";
import {
  createPresignedUpload,
  deleteObject,
  getObjectBytes,
  isMarketplaceObject,
  marketplaceObjectKey,
  marketplaceUploadLimits,
  putObject,
  inspectObject,
} from "@/lib/storage/s3";

export type ActionResult<T extends object = object> = ({ ok: true } & T) | { ok: false; error: string };

function assertAdmin(user: AppUser) { if (!isAdmin(user)) throw new ForbiddenError(); }
function failure(cause: unknown): { ok: false; error: string } {
  if (cause instanceof ZodError || cause instanceof SyntaxError) return { ok: false, error: cause.message };
  const code = cause instanceof Error ? cause.message : "UNKNOWN";
  if (code.startsWith("TEMPLATE_INVALID:") || code.startsWith("UPLOAD_INVALID:")) return { ok: false, error: code.split(":").slice(1).join(":") };
  if (code.startsWith("DESCRIPTOR_INVALID:")) return { ok: false, error: `Descriptor rejected: ${code.slice("DESCRIPTOR_INVALID:".length)}` };
  if (code === "INVALID_UPLOAD_SIZE") return { ok: false, error: "That file is too large for its slot." };
  if (code === "ITEM_HAS_PURCHASES") return { ok: false, error: "Someone has bought this item; unpublish it instead of deleting it." };
  if (code === "CATEGORY_EXISTS") return { ok: false, error: "A category with that slug already exists for this kind." };
  if (code === "CATEGORY_MISMATCH") return { ok: false, error: "Pick a category that belongs to this kind." };
  if (code === "NOT_FOUND") return { ok: false, error: "This item no longer exists." };
  if (code.startsWith("STORAGE_NOT_CONFIGURED:")) return { ok: false, error: "Object storage is not configured." };
  console.error("Marketplace admin action failed", { code });
  return { ok: false, error: "The change could not be saved." };
}

async function requireCategoryForKind(input: ItemInput) {
  const category = await getCategory(input.categoryId);
  if (!category || category.kind !== input.kind) throw new Error("CATEGORY_MISMATCH");
}

export async function createCategory(user: AppUser, input: unknown): Promise<ActionResult<{ category: MarketplaceCategory }>> {
  assertAdmin(user);
  const parsed = categoryInput.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid category." };
  try {
    const row = await insertCategory(parsed.data);
    return { ok: true, category: { id: row.id, kind: row.kind, slug: row.slug, name: row.name, icon: row.icon } };
  } catch (cause) {
    return failure(cause);
  }
}

/** Renames a category or gives it a different sidebar symbol. */
export async function updateCategory(user: AppUser, input: unknown): Promise<ActionResult<{ category: MarketplaceCategory }>> {
  assertAdmin(user);
  const parsed = categoryPatch.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid category." };
  try {
    const row = await updateCategoryRow(parsed.data);
    return { ok: true, category: { id: row.id, kind: row.kind, slug: row.slug, name: row.name, icon: row.icon } };
  } catch (cause) {
    return failure(cause);
  }
}

/** Sets the label, symbol and sidebar order the app shows for one kind. */
export async function updateKind(user: AppUser, input: unknown): Promise<ActionResult<{ kind: MarketplaceKind }>> {
  assertAdmin(user);
  const parsed = kindPatch.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid kind." };
  try {
    const row = await upsertKind(parsed.data);
    return { ok: true, kind: row.kind };
  } catch (cause) {
    return failure(cause);
  }
}

export async function createItem(user: AppUser, input: ItemInput): Promise<ActionResult<{ id: string }>> {
  assertAdmin(user);
  const parsed = itemInput.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid item." };
  try {
    await requireCategoryForKind(parsed.data);
    if (parsed.data.draftId) {
      const existing = await getItem(parsed.data.draftId);
      if (existing) {
        if (existing.createdBy !== user.id) throw new ForbiddenError();
        return { ok: true, id: existing.id };
      }
    }
    const item = await insertItem({ ...parsed.data, metadata: { tags: parsed.data.metadata.tags, fontFamily: parsed.data.metadata.fontFamily } }, user.id);
    return { ok: true, id: item.id };
  } catch (cause) {
    return failure(cause);
  }
}

export async function updateItem(user: AppUser, id: string, input: ItemInput): Promise<ActionResult> {
  assertAdmin(user);
  const parsed = itemInput.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid item." };
  try {
    const item = await requireItem(id);
    // Content already uploaded for one kind is not valid for another.
    const kindChanged = item.kind !== parsed.data.kind && item.contentKey !== null;
    if (kindChanged) return { ok: false, error: "Remove the content file before changing the kind." };
    await requireCategoryForKind(parsed.data);
    await updateItemRow(id, { ...parsed.data, metadata: { ...item.metadata, tags: parsed.data.metadata.tags, fontFamily: parsed.data.metadata.fontFamily } });
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

export async function publishItem(user: AppUser, id: string, published: boolean): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const item = await requireItem(id);
    if (published && !item.contentKey) return { ok: false, error: "Upload the content file before publishing." };
    if (published && item.kind === "project_template") {
      if (!item.previewImageKey || !item.previewVideoKey || !item.metadata.preview?.mock) {
        return { ok: false, error: "Templates need a cover and a preview made with mock images." };
      }
      const { bytes } = await getObjectBytes(item.contentKey!, marketplaceUploadLimits.content);
      const template = parseTemplate(bytes.toString("utf8"), true);
      const sources = new Map<string, string>();
      const effects = new Set(["rx.brightness-contrast", "rx.saturation", "rx.gaussian-blur"]);
      const transitions = new Set(["rx.cross-dissolve", "rx.fade-color", "rx.directional-wipe"]);
      for (const reference of template.marketplaceItems) {
        const dependency = await getItem(reference.itemId);
        if (!dependency || dependency.id === id || dependency.kind === "project_template" || dependency.status !== "published" || !dependency.contentKey) {
          return { ok: false, error: `Marketplace dependency ${reference.itemId} is unavailable. Choose a published asset.` };
        }
        sources.set(reference.itemId, dependency.kind);
        if (dependency.kind === "effect" || dependency.kind === "transition") {
          const { bytes } = await getObjectBytes(dependency.contentKey, marketplaceUploadLimits.content);
          const descriptor = parseDescriptor(bytes.toString("utf8"));
          (dependency.kind === "effect" ? effects : transitions).add(descriptor.id);
        }
      }
      for (const shot of template.shots) {
        if (shot.marketplaceItemId && !["footage", "audio", "sound_effect", "remotion_prompt"].includes(sources.get(shot.marketplaceItemId) ?? "")) return { ok: false, error: `${shot.title} needs a media or Remotion source.` };
        if (shot.effects.some((effect) => !effects.has(effect.modifierId)) || (shot.transition && !transitions.has(shot.transition.modifierId))) return { ok: false, error: `${shot.title} uses an unlisted effect or transition. Add its marketplace dependency or choose a built-in modifier.` };
      }
    }
    await setItemStatus(id, published ? "published" : "draft");
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

export async function deleteItem(user: AppUser, id: string): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const item = await requireItem(id);
    if ((await countPurchases(id)) > 0) throw new Error("ITEM_HAS_PURCHASES");
    for (const key of [item.previewImageKey, item.previewVideoKey, item.contentKey]) {
      if (key) await deleteObject(key).catch((cause) => console.error("Marketplace object delete failed", { key, cause: String(cause) }));
    }
    await deleteItemRow(id);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

export async function createUploadUrl(user: AppUser, input: unknown): Promise<ActionResult<{ uploadURL: string; objectKey: string; headers: Record<string, string> }>> {
  assertAdmin(user);
  const parsed = uploadRequest.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid upload." };
  try {
    const item = await requireItem(parsed.data.itemId);
    if (!isAllowedFilename(item.kind, parsed.data.role, parsed.data.filename)) {
      return { ok: false, error: `A ${parsed.data.role.replace("-", " ")} for this kind must be one of: ${allowedList(item.kind, parsed.data.role)}.` };
    }
    const upload = await createPresignedUpload({
      key: marketplaceObjectKey(item.id, parsed.data.role, parsed.data.filename),
      contentType: parsed.data.contentType,
      sizeBytes: parsed.data.sizeBytes,
      maxBytes: marketplaceUploadLimits[parsed.data.role],
      metadata: { author: user.id, role: parsed.data.role },
    });
    return { ok: true, uploadURL: upload.uploadURL, objectKey: upload.objectKey, headers: upload.headers };
  } catch (cause) {
    return failure(cause);
  }
}

export async function finalizeUpload(user: AppUser, input: unknown): Promise<ActionResult> {
  assertAdmin(user);
  const parsed = finalizeRequest.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid upload." };
  const { itemId, role, objectKey, filename, contentType, sizeBytes } = parsed.data;
  try {
    const item = await requireItem(itemId);
    if (!isMarketplaceObject(itemId, objectKey) || !objectKey.startsWith(`marketplace/${itemId}/${role}/`) || !isAllowedFilename(item.kind, role, filename)) {
      return { ok: false, error: "That object does not belong to this item." };
    }
    const uploaded = await inspectObject(objectKey);
    if (uploaded.metadata.author !== user.id || uploaded.metadata.role !== role) {
      const missingMetadata = !uploaded.metadata.author || !uploaded.metadata.role;
      console.warn("Marketplace upload finalization rejected", {
        itemId, role, reason: missingMetadata ? "missing_authorization_metadata" : "authorization_mismatch",
        authorMatches: uploaded.metadata.author === user.id, roleMatches: uploaded.metadata.role === role,
      });
      return { ok: false, error: missingMetadata
        ? "Storage did not retain this upload's authorization metadata. Retry the file upload."
        : "This upload was not authorized for your account and this slot. Retry the file upload from the current account." };
    }
    validateAssetHeader({ ...parsed.data, kind: item.kind }, uploaded, marketplaceUploadLimits[role]);
    const supplied = parsed.data.metadata ?? {};
    const media = { durationSeconds: supplied.durationSeconds, width: supplied.width, height: supplied.height };
    let metadata = role === "preview-video"
      ? { ...item.metadata, preview: { ...media, mock: supplied.preview?.mock ?? false } }
      : role === "content" ? { ...item.metadata, ...media } : { ...item.metadata };
    if (role === "content" && item.kind === "project_template") {
      const { bytes } = await getObjectBytes(objectKey, marketplaceUploadLimits.content);
      const template = parseTemplate(bytes.toString("utf8"));
      metadata = { ...metadata, template: templateSummary(template), promptExcerpt: template.prompt.slice(0, 400), preview: { ...metadata.preview, mock: false } };
    }
    if (role === "content" && (item.kind === "effect" || item.kind === "transition")) {
      const { bytes } = await getObjectBytes(objectKey, marketplaceUploadLimits.content);
      const descriptor = parseDescriptor(bytes.toString("utf8"));
      if (descriptor.kind !== item.kind) return { ok: false, error: `This descriptor is a ${descriptor.kind}, but the item is a ${item.kind}.` };
      metadata = { ...metadata, descriptor: { filterName: descriptor.filter, parameterCount: descriptor.parameters.length } };
    }
    if (role === "content" && item.kind === "remotion_prompt") {
      const { bytes } = await getObjectBytes(objectKey, marketplaceUploadLimits.content);
      metadata = { ...metadata, promptExcerpt: bytes.toString("utf8").trim().slice(0, 400) };
    }
    if (role === "content" && item.kind === "font") metadata = { ...metadata, fontFamily: supplied.fontFamily };
    const previousKey = role === "preview-image" ? item.previewImageKey : role === "preview-video" ? item.previewVideoKey : item.contentKey;
    await updateItemAssets(itemId, {
      ...(role === "preview-image" ? { previewImageKey: objectKey } : {}),
      ...(role === "preview-video" ? { previewVideoKey: objectKey } : {}),
      ...(role === "content" ? { contentKey: objectKey, contentFilename: filename, contentSizeBytes: sizeBytes, contentType } : {}),
      metadata,
    });
    if (item.kind === "project_template" && (role === "content" || (role === "preview-video" && !metadata.preview?.mock))) await setItemStatus(itemId, "draft");
    if (previousKey && previousKey !== objectKey) await deleteObject(previousKey).catch(() => null);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

export async function saveDescriptor(user: AppUser, itemId: string, text: string): Promise<ActionResult> {
  assertAdmin(user);
  const item = await requireItem(itemId);
  if (item.kind !== "effect" && item.kind !== "transition") return { ok: false, error: "Only effects and transitions have descriptors." };
  return saveContent(user, itemId, text);
}

export async function loadDescriptor(user: AppUser, itemId: string): Promise<ActionResult<{ text: string }>> {
  assertAdmin(user);
  try {
    const item = await requireItem(itemId);
    if (!item.contentKey) return { ok: true, text: "" };
    const { bytes } = await getObjectBytes(item.contentKey, marketplaceUploadLimits.content);
    return { ok: true, text: bytes.toString("utf8") };
  } catch (cause) {
    return failure(cause);
  }
}

export async function removeAsset(user: AppUser, itemId: string, role: AssetRole): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const item = await requireItem(itemId);
    const key = role === "preview-image" ? item.previewImageKey : role === "preview-video" ? item.previewVideoKey : item.contentKey;
    if (key) await deleteObject(key).catch(() => null);
    await updateItemAssets(itemId, {
      ...(role === "preview-image" ? { previewImageKey: null } : {}),
      ...(role === "preview-video" ? { previewVideoKey: null } : {}),
      ...(role === "content" ? { contentKey: null, contentFilename: null, contentSizeBytes: null, contentType: null } : {}),
    });
    if (item.status === "published" && (role === "content" || item.kind === "project_template")) await setItemStatus(itemId, "draft");
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

function allowedList(kind: ItemInput["kind"], role: AssetRole) {
  return allowedExtensions(kind, role).join(", ");
}

/** JSON definitions and prompts use the same validation/finalization path as file uploads. */
export async function saveContent(user: AppUser, itemId: string, text: string): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const item = await requireItem(itemId);
    if (!["project_template", "effect", "transition", "remotion_prompt"].includes(item.kind)) return { ok: false, error: "This item needs a media or font file." };
    if (item.kind === "project_template") text = JSON.stringify(parseTemplate(text));
    if (item.kind === "effect" || item.kind === "transition") {
      const descriptor = parseDescriptor(text);
      if (descriptor.kind !== item.kind) return { ok: false, error: "Descriptor kind does not match the item." };
      text = JSON.stringify(descriptor);
    }
    if (!text.trim()) return { ok: false, error: "Content cannot be empty." };
    const filename = item.kind === "remotion_prompt" ? "prompt.md" : "definition.json";
    const contentType = item.kind === "remotion_prompt" ? "text/markdown" : "application/json";
    const body = Buffer.from(text, "utf8");
    if (body.length > marketplaceUploadLimits.content) return { ok: false, error: "Content is too large." };
    if (item.contentKey) {
      const existing = await getObjectBytes(item.contentKey, marketplaceUploadLimits.content);
      if (existing.bytes.equals(body)) return { ok: true };
    }
    const objectKey = marketplaceObjectKey(itemId, "content", filename);
    await putObject({ key: objectKey, body, contentType, metadata: { author: user.id, role: "content" } });
    return finalizeUpload(user, { itemId, role: "content", objectKey, filename, contentType, sizeBytes: body.length });
  } catch (cause) { return failure(cause); }
}
