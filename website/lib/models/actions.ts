"use server";
import { revalidatePath } from "next/cache";
import { requireAdminPageUser } from "@/lib/auth";
import * as authoring from "./authoring";
export type { ActionResult } from "./authoring";

/** Curation changes what every model picker offers, so the public price table goes stale with the admin page. */
function refresh() {
  revalidatePath("/admin/models");
  revalidatePath("/models");
}

export async function addModel(input: unknown) {
  const result = await authoring.addModel(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function addAllDiscovered(input: unknown) {
  const result = await authoring.addAllDiscovered(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function updateModel(input: unknown) {
  const result = await authoring.updateModel(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function setEnabled(input: unknown) {
  const result = await authoring.setEnabled(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function setDefault(input: unknown) {
  const result = await authoring.setDefault(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function removeAllForCapability(input: unknown) {
  const result = await authoring.removeAllForCapability(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
export async function removeModel(input: unknown) {
  const result = await authoring.removeModel(await requireAdminPageUser(), input);
  if (result.ok) refresh();
  return result;
}
