import "server-only";
import { isAdmin, type AppUser } from "@/lib/auth";
import { ForbiddenError } from "@/lib/auth/bearer";
import { requestLocale } from "@/lib/i18n/request";
import { t, type MessageKey } from "@/lib/i18n/messages";
import { ZodError } from "zod";
import { kindName } from "./i18n";
import { parseTemplate, templateSummary } from "./template";
import { validateAssetHeader } from "./upload-validation";
import {
  countPurchases,
  getItem,
  deleteItemRow,
  deleteCategory as deleteCategoryRow,
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
  categoryDelete,
  kindPatch,
  finalizeRequest,
  isAllowedFilename,
  itemInput,
  mediaTypeForContent,
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

/**
 * A refusal in the language the caller asked for. Both forms — the website's
 * and the one the Mac app draws — show `error` as written, so it is the one
 * string in an action result that has to be translated.
 *
 * The exception is a validation message zod produced ("Pick a category."):
 * those live in `schema.ts` in the source language and are passed through as
 * they are, because they name the field that failed.
 */
async function reject(key: MessageKey, params?: Record<string, string | number>): Promise<{ ok: false; error: string }> {
  return { ok: false, error: t(await requestLocale(), key, params) };
}

/** The message behind a thrown code, in the caller's language. */
async function failure(cause: unknown): Promise<{ ok: false; error: string }> {
  if (cause instanceof ZodError || cause instanceof SyntaxError) return { ok: false, error: cause.message };
  const code = cause instanceof Error ? cause.message : "UNKNOWN";
  // Carries its own reason from the parser, which is not a fixed string.
  if (code.startsWith("TEMPLATE_INVALID:") || code.startsWith("UPLOAD_INVALID:")) return { ok: false, error: code.split(":").slice(1).join(":") };
  if (code.startsWith("DESCRIPTOR_INVALID:")) return reject("authoring.descriptorRejected", { reason: code.slice("DESCRIPTOR_INVALID:".length) });
  if (code === "INVALID_UPLOAD_SIZE") return reject("authoring.uploadTooLarge");
  if (code === "ITEM_HAS_PURCHASES") return reject("authoring.itemHasPurchases");
  if (code === "CATEGORY_EXISTS") return reject("authoring.categoryExists");
  if (code === "CATEGORY_NOT_FOUND") return reject("authoring.categoryMissing");
  if (code === "CATEGORY_HAS_ITEMS") return reject("authoring.categoryHasItems");
  if (code === "CATEGORY_MISMATCH") return reject("authoring.categoryMismatch");
  if (code === "NOT_FOUND") return reject("authoring.itemMissing");
  if (code.startsWith("STORAGE_NOT_CONFIGURED:")) return reject("authoring.storageUnconfigured");
  console.error("Marketplace admin action failed", { code });
  return reject("authoring.invalid");
}

async function requireCategoryForKind(input: ItemInput) {
  const category = await getCategory(input.categoryId);
  if (!category || category.kind !== input.kind) throw new Error("CATEGORY_MISMATCH");
}

export async function createCategory(user: AppUser, input: unknown): Promise<ActionResult<{ category: MarketplaceCategory }>> {
  assertAdmin(user);
  const parsed = categoryInput.safeParse(input);
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidCategory");
  try {
    const row = await insertCategory(parsed.data);
    return { ok: true, category: { id: row.id, kind: row.kind, slug: row.slug, name: row.name, icon: row.icon, translations: row.translations } };
  } catch (cause) {
    return failure(cause);
  }
}

/** Renames a category or gives it a different sidebar symbol. */
export async function updateCategory(user: AppUser, input: unknown): Promise<ActionResult<{ category: MarketplaceCategory }>> {
  assertAdmin(user);
  const parsed = categoryPatch.safeParse(input);
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidCategory");
  try {
    const row = await updateCategoryRow(parsed.data);
    return { ok: true, category: { id: row.id, kind: row.kind, slug: row.slug, name: row.name, icon: row.icon, translations: row.translations } };
  } catch (cause) {
    return failure(cause);
  }
}

export async function deleteCategory(user: AppUser, input: unknown): Promise<ActionResult> {
  assertAdmin(user);
  const parsed = categoryDelete.safeParse(input);
  if (!parsed.success) return reject("authoring.invalidCategory");
  try {
    await deleteCategoryRow(parsed.data.id);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

/** Sets the label, symbol and sidebar order the app shows for one kind. */
export async function updateKind(user: AppUser, input: unknown): Promise<ActionResult<{ kind: MarketplaceKind }>> {
  assertAdmin(user);
  const parsed = kindPatch.safeParse(input);
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidKind");
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
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidItem");
  try {
    await requireCategoryForKind(parsed.data);
    if (parsed.data.draftId) {
      const existing = await getItem(parsed.data.draftId);
      if (existing) {
        if (existing.createdBy !== user.id) throw new ForbiddenError();
        return { ok: true, id: existing.id };
      }
    }
    const item = await insertItem({ ...parsed.data, metadata: { tags: parsed.data.metadata.tags, fontFamily: parsed.data.metadata.fontFamily,
      ...(parsed.data.kind === "audio" ? { lyricTracks: parsed.data.metadata.lyricTracks } : {}) } }, user.id);
    return { ok: true, id: item.id };
  } catch (cause) {
    return failure(cause);
  }
}

export async function updateItem(user: AppUser, id: string, input: ItemInput): Promise<ActionResult> {
  assertAdmin(user);
  const parsed = itemInput.safeParse(input);
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidItem");
  try {
    const item = await requireItem(id);
    // Content already uploaded for one kind is not valid for another.
    const kindChanged = item.kind !== parsed.data.kind && item.contentKey !== null;
    if (kindChanged) return reject("authoring.kindLocked");
    await requireCategoryForKind(parsed.data);
    await updateItemRow(id, { ...parsed.data, metadata: { ...item.metadata, tags: parsed.data.metadata.tags, fontFamily: parsed.data.metadata.fontFamily,
      ...(parsed.data.kind === "audio" && parsed.data.metadata.lyricTracks !== undefined ? { lyricTracks: parsed.data.metadata.lyricTracks } : {}) } });
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

export async function publishItem(user: AppUser, id: string, published: boolean): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const item = await requireItem(id);
    if (published && !item.contentKey) return reject("authoring.contentRequired");
    if (published && item.kind === "remotion" && !item.previewImageKey) return reject("authoring.remotionPreviewRequired");
    if (published && item.kind === "footage" && !item.metadata.mediaType) return reject("authoring.mediaTypeMissing");
    if (published && item.kind === "project_template") {
      if (!item.previewImageKey || !item.previewVideoKey || !item.metadata.preview?.mock) {
        return reject("authoring.templateAssetsRequired");
      }
      const { bytes } = await getObjectBytes(item.contentKey!, marketplaceUploadLimits.content);
      const template = parseTemplate(bytes.toString("utf8"), true);
      const sources = new Map<string, string>();
      const effects = new Set(["rx.brightness-contrast", "rx.saturation", "rx.gaussian-blur"]);
      const transitions = new Set(["rx.cross-dissolve", "rx.fade-color", "rx.directional-wipe"]);
      for (const reference of template.marketplaceItems) {
        const dependency = await getItem(reference.itemId);
        if (!dependency || dependency.id === id || dependency.kind === "project_template" || dependency.status !== "published" || !dependency.contentKey) {
          return reject("authoring.dependencyUnavailable", { id: reference.itemId });
        }
        sources.set(reference.itemId, dependency.kind);
        if (dependency.kind === "effect" || dependency.kind === "transition") {
          const { bytes } = await getObjectBytes(dependency.contentKey, marketplaceUploadLimits.content);
          const descriptor = parseDescriptor(bytes.toString("utf8"));
          (dependency.kind === "effect" ? effects : transitions).add(descriptor.id);
        }
      }
      for (const shot of template.shots) {
        if (shot.marketplaceItemId && !["footage", "audio", "sound_effect", "remotion"].includes(sources.get(shot.marketplaceItemId) ?? "")) return reject("authoring.shotSourceRequired", { shot: shot.title });
        if (shot.effects.some((effect) => !effects.has(effect.modifierId)) || (shot.transition && !transitions.has(shot.transition.modifierId))) return reject("authoring.shotModifierUnlisted", { shot: shot.title });
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
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidUpload");
  try {
    const item = await requireItem(parsed.data.itemId);
    if (!isAllowedFilename(item.kind, parsed.data.role, parsed.data.filename)) {
      return reject("authoring.extensionNotAllowed", { slot: parsed.data.role.replace("-", " "), extensions: allowedList(item.kind, parsed.data.role) });
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
  if (!parsed.success) return parsed.error.issues[0]?.message ? { ok: false, error: parsed.error.issues[0].message } : reject("authoring.invalidUpload");
  const { itemId, role, objectKey, filename, contentType, sizeBytes } = parsed.data;
  try {
    const item = await requireItem(itemId);
    if (!isMarketplaceObject(itemId, objectKey) || !objectKey.startsWith(`marketplace/${itemId}/${role}/`) || !isAllowedFilename(item.kind, role, filename)) {
      return reject("authoring.objectNotThisItem");
    }
    const uploaded = await inspectObject(objectKey);
    if (uploaded.metadata.author !== user.id || uploaded.metadata.role !== role) {
      const missingMetadata = !uploaded.metadata.author || !uploaded.metadata.role;
      console.warn("Marketplace upload finalization rejected", {
        itemId, role, reason: missingMetadata ? "missing_authorization_metadata" : "authorization_mismatch",
        authorMatches: uploaded.metadata.author === user.id, roleMatches: uploaded.metadata.role === role,
      });
      return reject(missingMetadata ? "authoring.uploadMetadataMissing" : "authoring.uploadNotAuthorized");
    }
    validateAssetHeader({ ...parsed.data, kind: item.kind }, uploaded, marketplaceUploadLimits[role]);
    const supplied = parsed.data.metadata ?? {};
    const media = { durationSeconds: supplied.durationSeconds, width: supplied.width, height: supplied.height };
    let metadata = role === "preview-video"
      ? { ...item.metadata, preview: { ...media, mock: supplied.preview?.mock ?? false, startSeconds: supplied.preview?.startSeconds ?? 0 } }
      : role === "content" ? { ...item.metadata, ...media } : { ...item.metadata };
    if (role === "content" && item.kind === "project_template") {
      const { bytes } = await getObjectBytes(objectKey, marketplaceUploadLimits.content);
      const template = parseTemplate(bytes.toString("utf8"));
      metadata = { ...metadata, template: templateSummary(template), promptExcerpt: template.prompt.slice(0, 400), preview: { ...metadata.preview, mock: false } };
    }
    if (role === "content" && (item.kind === "effect" || item.kind === "transition")) {
      const { bytes } = await getObjectBytes(objectKey, marketplaceUploadLimits.content);
      const descriptor = parseDescriptor(bytes.toString("utf8"));
      if (descriptor.kind !== item.kind) return reject("authoring.descriptorKindMismatch", { descriptor: kindName(await requestLocale(), descriptor.kind), kind: kindName(await requestLocale(), item.kind) });
      metadata = { ...metadata, descriptor: { filterName: descriptor.filter, parameterCount: descriptor.parameters.length } };
    }
    // The file decides which shelf footage sits on, never the client.
    if (role === "content") {
      metadata = { ...metadata, mediaType: item.kind === "footage" ? mediaTypeForContent(filename) : undefined };
    }
    // A Remotion archive is a zip: nothing here can read its prompt out, so the
    // app sends the excerpt alongside the upload the way fonts send a family.
    if (role === "content" && item.kind === "remotion") {
      metadata = { ...metadata, promptExcerpt: supplied.promptExcerpt?.trim().slice(0, 400) };
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
  if (item.kind !== "effect" && item.kind !== "transition") return reject("authoring.descriptorOnlyKinds");
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
      // Facts read off the old file cannot outlive it, or a replacement lands
      // on the shelf the previous upload chose.
      ...(role === "content"
        ? { metadata: { ...item.metadata, mediaType: undefined, width: undefined, height: undefined, durationSeconds: undefined } }
        : {}),
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
    if (!["project_template", "effect", "transition"].includes(item.kind)) return reject("authoring.contentNotText");
    if (item.kind === "project_template") text = JSON.stringify(parseTemplate(text));
    if (item.kind === "effect" || item.kind === "transition") {
      const descriptor = parseDescriptor(text);
      if (descriptor.kind !== item.kind) return reject("authoring.descriptorKindMismatch", { descriptor: kindName(await requestLocale(), descriptor.kind), kind: kindName(await requestLocale(), item.kind) });
      text = JSON.stringify(descriptor);
    }
    if (!text.trim()) return reject("authoring.contentEmpty");
    const filename = "definition.json";
    const contentType = "application/json";
    const body = Buffer.from(text, "utf8");
    if (body.length > marketplaceUploadLimits.content) return reject("authoring.contentTooLarge");
    if (item.contentKey) {
      const existing = await getObjectBytes(item.contentKey, marketplaceUploadLimits.content);
      if (existing.bytes.equals(body)) return { ok: true };
    }
    const objectKey = marketplaceObjectKey(itemId, "content", filename);
    await putObject({ key: objectKey, body, contentType, metadata: { author: user.id, role: "content" } });
    return finalizeUpload(user, { itemId, role: "content", objectKey, filename, contentType, sizeBytes: body.length });
  } catch (cause) { return failure(cause); }
}
