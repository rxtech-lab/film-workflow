"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireAdminPageUser } from "@/lib/auth";
import * as authoring from "./authoring";
import type { ItemInput, AssetRole } from "./schema";
export type { ActionResult } from "./authoring";
function refresh(id?: string) {
  revalidatePath("/admin/marketplace");
  if (id) revalidatePath(`/admin/marketplace/${id}`);
}
/** Taxonomy edits change every item page's labels, so the whole section goes stale. */
function refreshTaxonomy() {
  revalidatePath("/admin/marketplace", "layout");
}
export async function createCategory(input: unknown) {
  const result = await authoring.createCategory(await requireAdminPageUser(), input);
  if (result.ok) refreshTaxonomy();
  return result;
}
export async function updateCategory(input: unknown) {
  const result = await authoring.updateCategory(await requireAdminPageUser(), input);
  if (result.ok) refreshTaxonomy();
  return result;
}
export async function deleteCategory(input: unknown) {
  const result = await authoring.deleteCategory(await requireAdminPageUser(), input);
  if (result.ok) refreshTaxonomy();
  return result;
}
export async function updateKind(input: unknown) {
  const result = await authoring.updateKind(await requireAdminPageUser(), input);
  if (result.ok) refreshTaxonomy();
  return result;
}
export async function createItem(input: ItemInput) {
  const result = await authoring.createItem(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function updateItem(id: string, input: ItemInput) {
  const result = await authoring.updateItem(await requireAdminPageUser(), id, input);
  if (result.ok) refresh(id);
  return result;
}
export async function publishItem(id: string, published: boolean) {
  const result = await authoring.publishItem(await requireAdminPageUser(), id, published);
  if (result.ok) refresh(id);
  return result;
}
export async function deleteItem(id: string) {
  const result = await authoring.deleteItem(await requireAdminPageUser(), id);
  if (result.ok) refresh(id);
  return result;
}
export async function createUploadUrl(input: unknown) {
  const result = await authoring.createUploadUrl(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function finalizeUpload(input: unknown) {
  const result = await authoring.finalizeUpload(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function saveDescriptor(itemId: string, text: string) {
  const result = await authoring.saveDescriptor(await requireAdminPageUser(), itemId, text);
  if (result.ok) refresh(itemId);
  return result;
}
export async function saveContent(itemId: string, text: string) {
  const result = await authoring.saveContent(await requireAdminPageUser(), itemId, text);
  if (result.ok) refresh(itemId);
  return result;
}
export async function loadDescriptor(itemId: string) {
  const result = await authoring.loadDescriptor(await requireAdminPageUser(), itemId);
  if (result.ok) refresh(itemId);
  return result;
}
export async function removeAsset(itemId: string, role: AssetRole) {
  const result = await authoring.removeAsset(await requireAdminPageUser(), itemId, role);
  if (result.ok) refresh(itemId);
  return result;
}
export async function togglePublishAction(formData: FormData) {
  await publishItem(String(formData.get("id") ?? ""), formData.get("published") === "true");
}
export async function deleteItemAndReturn(id: string) {
  const result = await deleteItem(id);
  if (result.ok) redirect("/admin/marketplace");
  return result;
}
