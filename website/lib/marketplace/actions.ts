"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireAdminPageUser } from "@/lib/auth";
import {
  countPurchases,
  deleteItemRow,
  getCategory,
  insertCategory,
  insertItem,
  requireItem,
  setItemStatus,
  updateItem as updateItemRow,
  updateItemAssets,
} from "@/lib/marketplace/repository";
import {
  allowedExtensions,
  categoryInput,
  finalizeRequest,
  isAllowedFilename,
  itemInput,
  parseDescriptor,
  uploadRequest,
  type AssetRole,
  type ItemInput,
  type MarketplaceCategory,
} from "@/lib/marketplace/schema";
import {
  createPresignedUpload,
  deleteObject,
  getObjectBytes,
  isMarketplaceObject,
  marketplaceObjectKey,
  marketplaceUploadLimits,
  putObject,
} from "@/lib/storage/s3";

export type ActionResult<T extends object = object> = ({ ok: true } & T) | { ok: false; error: string };

const ADMIN_PATH = "/admin/marketplace";

function failure(cause: unknown): { ok: false; error: string } {
  const code = cause instanceof Error ? cause.message : "UNKNOWN";
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

function revalidate(id?: string) {
  revalidatePath(ADMIN_PATH);
  if (id) revalidatePath(`${ADMIN_PATH}/${id}`);
}

/** Categories are per kind, so a footage item cannot sit on a music shelf. */
async function requireCategoryForKind(input: ItemInput) {
  const category = await getCategory(input.categoryId);
  if (!category || category.kind !== input.kind) throw new Error("CATEGORY_MISMATCH");
}

export async function createCategory(input: unknown): Promise<ActionResult<{ category: MarketplaceCategory }>> {
  await requireAdminPageUser();
  const parsed = categoryInput.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid category." };
  try {
    const row = await insertCategory(parsed.data);
    revalidate();
    return { ok: true, category: { id: row.id, kind: row.kind, slug: row.slug, name: row.name } };
  } catch (cause) {
    return failure(cause);
  }
}

export async function createItem(input: ItemInput): Promise<ActionResult<{ id: string }>> {
  const user = await requireAdminPageUser();
  const parsed = itemInput.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid item." };
  try {
    await requireCategoryForKind(parsed.data);
    const item = await insertItem(parsed.data, user.id);
    revalidate(item.id);
    return { ok: true, id: item.id };
  } catch (cause) {
    return failure(cause);
  }
}

export async function updateItem(id: string, input: ItemInput): Promise<ActionResult> {
  await requireAdminPageUser();
  const parsed = itemInput.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid item." };
  try {
    const item = await requireItem(id);
    // Content already uploaded for one kind is not valid for another.
    const kindChanged = item.kind !== parsed.data.kind && item.contentKey !== null;
    if (kindChanged) return { ok: false, error: "Remove the content file before changing the kind." };
    await requireCategoryForKind(parsed.data);
    await updateItemRow(id, parsed.data);
    revalidate(id);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

export async function publishItem(id: string, published: boolean): Promise<ActionResult> {
  await requireAdminPageUser();
  try {
    const item = await requireItem(id);
    if (published && !item.contentKey) return { ok: false, error: "Upload the content file before publishing." };
    await setItemStatus(id, published ? "published" : "draft");
    revalidate(id);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

/** Form action for the list page's Publish/Unpublish buttons. */
export async function togglePublishAction(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const published = formData.get("published") === "true";
  await publishItem(id, published);
}

export async function deleteItem(id: string): Promise<ActionResult> {
  await requireAdminPageUser();
  try {
    const item = await requireItem(id);
    if ((await countPurchases(id)) > 0) throw new Error("ITEM_HAS_PURCHASES");
    for (const key of [item.previewImageKey, item.previewVideoKey, item.contentKey]) {
      if (key) await deleteObject(key).catch((cause) => console.error("Marketplace object delete failed", { key, cause: String(cause) }));
    }
    await deleteItemRow(id);
    revalidate(id);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

/** Form action for the list page's Delete button. */
export async function deleteItemAction(formData: FormData) {
  await deleteItem(String(formData.get("id") ?? ""));
}

/** Delete from the edit page, then leave it. */
export async function deleteItemAndReturn(id: string): Promise<ActionResult> {
  const result = await deleteItem(id);
  if (result.ok) redirect(ADMIN_PATH);
  return result;
}

/**
 * A presigned PUT the browser performs directly against R2. Nothing is
 * recorded until `finalizeUpload` confirms the object landed.
 */
export async function createUploadUrl(input: unknown): Promise<ActionResult<{ uploadURL: string; objectKey: string; headers: Record<string, string> }>> {
  await requireAdminPageUser();
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
    });
    return { ok: true, uploadURL: upload.uploadURL, objectKey: upload.objectKey, headers: upload.headers };
  } catch (cause) {
    return failure(cause);
  }
}

function allowedList(kind: ItemInput["kind"], role: AssetRole) {
  return allowedExtensions(kind, role).join(", ");
}

export async function finalizeUpload(input: unknown): Promise<ActionResult> {
  await requireAdminPageUser();
  const parsed = finalizeRequest.safeParse(input);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0]?.message ?? "Invalid upload." };
  const { itemId, role, objectKey, filename, contentType, sizeBytes } = parsed.data;
  try {
    const item = await requireItem(itemId);
    if (!isMarketplaceObject(itemId, objectKey) || !isAllowedFilename(item.kind, role, filename)) {
      return { ok: false, error: "That object does not belong to this item." };
    }
    let metadata = { ...item.metadata, ...(parsed.data.metadata ?? {}) };
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
    const previousKey = role === "preview-image" ? item.previewImageKey : role === "preview-video" ? item.previewVideoKey : item.contentKey;
    await updateItemAssets(itemId, {
      ...(role === "preview-image" ? { previewImageKey: objectKey } : {}),
      ...(role === "preview-video" ? { previewVideoKey: objectKey } : {}),
      ...(role === "content" ? { contentKey: objectKey, contentFilename: filename, contentSizeBytes: sizeBytes, contentType } : {}),
      metadata,
    });
    if (previousKey && previousKey !== objectKey) await deleteObject(previousKey).catch(() => null);
    revalidate(itemId);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

/** Effects and transitions are small JSON files; the admin edits them in place instead of uploading. */
export async function saveDescriptor(itemId: string, text: string): Promise<ActionResult> {
  await requireAdminPageUser();
  try {
    const item = await requireItem(itemId);
    if (item.kind !== "effect" && item.kind !== "transition") return { ok: false, error: "Only effects and transitions have descriptors." };
    const descriptor = parseDescriptor(text);
    if (descriptor.kind !== item.kind) return { ok: false, error: `This descriptor is a ${descriptor.kind}, but the item is a ${item.kind}.` };
    const body = Buffer.from(JSON.stringify(descriptor, null, 2), "utf8");
    const filename = `${descriptor.id}.json`;
    const key = marketplaceObjectKey(item.id, "content", filename);
    await putObject({ key, body, contentType: "application/json" });
    await updateItemAssets(itemId, {
      contentKey: key,
      contentFilename: filename,
      contentSizeBytes: body.length,
      contentType: "application/json",
      metadata: { ...item.metadata, descriptor: { filterName: descriptor.filter, parameterCount: descriptor.parameters.length } },
    });
    if (item.contentKey && item.contentKey !== key) await deleteObject(item.contentKey).catch(() => null);
    revalidate(itemId);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}

/** The current descriptor text, for the editor. */
export async function loadDescriptor(itemId: string): Promise<ActionResult<{ text: string }>> {
  await requireAdminPageUser();
  try {
    const item = await requireItem(itemId);
    if (!item.contentKey) return { ok: true, text: "" };
    const { bytes } = await getObjectBytes(item.contentKey, marketplaceUploadLimits.content);
    return { ok: true, text: bytes.toString("utf8") };
  } catch (cause) {
    return failure(cause);
  }
}

/** Removes a slot's object so the kind can change or a bad file can be replaced. */
export async function removeAsset(itemId: string, role: AssetRole): Promise<ActionResult> {
  await requireAdminPageUser();
  try {
    const item = await requireItem(itemId);
    const key = role === "preview-image" ? item.previewImageKey : role === "preview-video" ? item.previewVideoKey : item.contentKey;
    if (key) await deleteObject(key).catch(() => null);
    await updateItemAssets(itemId, {
      ...(role === "preview-image" ? { previewImageKey: null } : {}),
      ...(role === "preview-video" ? { previewVideoKey: null } : {}),
      ...(role === "content" ? { contentKey: null, contentFilename: null, contentSizeBytes: null, contentType: null } : {}),
    });
    if (item.status === "published" && role === "content") await setItemStatus(itemId, "draft");
    revalidate(itemId);
    return { ok: true };
  } catch (cause) {
    return failure(cause);
  }
}
