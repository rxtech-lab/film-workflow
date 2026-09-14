import "server-only";

import { ZodError } from "zod";
import { discoveredCatalog } from "@/lib/ai/catalog";
import { isAdmin, type AppUser } from "@/lib/auth";
import { ForbiddenError } from "@/lib/auth/bearer";
import type { Capability } from "@/lib/db/schema";
import {
  deleteCatalogModel,
  deleteCatalogModelsForCapability,
  insertCatalogModel,
  insertCatalogModels,
  listCatalogModels,
  setCatalogModelEnabled,
  setDefaultCatalogModel,
  updateCatalogModel,
} from "./repository";
import { addAllInput, addModelInput, identifiedModel, removeAllInput, setEnabledInput, updateModelInput } from "./schema";

export type ActionResult<T extends object = object> = ({ ok: true } & T) | { ok: false; error: string };

function assertAdmin(user: AppUser) { if (!isAdmin(user)) throw new ForbiddenError(); }

function failure(cause: unknown): { ok: false; error: string } {
  if (cause instanceof ZodError) return { ok: false, error: cause.issues[0]?.message ?? "Invalid input." };
  const code = cause instanceof Error ? cause.message : "UNKNOWN";
  if (code === "MODEL_ALREADY_CURATED") return { ok: false, error: "That model is already on the list." };
  if (code === "MODEL_NOT_DISCOVERED") return { ok: false, error: "No provider offers that model for that capability right now." };
  if (code === "NOT_FOUND") return { ok: false, error: "That row no longer exists." };
  console.error("Model curation failed", { cause: code });
  return { ok: false, error: "Something went wrong saving that." };
}

/**
 * Adding a model discovery does not return would create a row that can never
 * resolve — invisible in the picker, and impossible to diagnose from the admin
 * page. Checking here means a stale browser tab fails loudly instead.
 */
async function requireDiscovered(modelId: string, capability: Capability) {
  const found = (await discoveredCatalog()).some((model) => model.id === modelId && model.capability === capability);
  if (!found) throw new Error("MODEL_NOT_DISCOVERED");
}

export async function addModel(user: AppUser, input: unknown): Promise<ActionResult<{ id: string }>> {
  assertAdmin(user);
  try {
    const parsed = addModelInput.parse(input);
    await requireDiscovered(parsed.modelId, parsed.capability);
    const row = await insertCatalogModel(parsed);
    return { ok: true, id: row.id };
  } catch (cause) { return failure(cause); }
}

/**
 * Offer everything a provider currently gives us, for one capability or all of
 * them. This is how an empty table gets filled after the migration, and how the
 * list is topped up when a provider ships something new.
 */
export async function addAllDiscovered(user: AppUser, input: unknown): Promise<ActionResult<{ added: number }>> {
  assertAdmin(user);
  try {
    const { capability } = addAllInput.parse(input);
    const discovered = await discoveredCatalog();
    const wanted = capability ? discovered.filter((model) => model.capability === capability) : discovered;
    const existing = new Set((await listCatalogModels()).map((row) => `${row.capability}:${row.modelId}`));
    const rows = wanted
      .filter((model) => !existing.has(`${model.capability}:${model.id}`))
      .map((model) => ({ modelId: model.id, capability: model.capability }));
    return { ok: true, added: (await insertCatalogModels(rows)).length };
  } catch (cause) { return failure(cause); }
}

export async function updateModel(user: AppUser, input: unknown): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const parsed = updateModelInput.parse(input);
    await updateCatalogModel(parsed);
    return { ok: true };
  } catch (cause) { return failure(cause); }
}

export async function setEnabled(user: AppUser, input: unknown): Promise<ActionResult> {
  assertAdmin(user);
  try {
    const parsed = setEnabledInput.parse(input);
    await setCatalogModelEnabled(parsed.id, parsed.enabled);
    return { ok: true };
  } catch (cause) { return failure(cause); }
}

export async function setDefault(user: AppUser, input: unknown): Promise<ActionResult> {
  assertAdmin(user);
  try {
    await setDefaultCatalogModel(identifiedModel.parse(input).id);
    return { ok: true };
  } catch (cause) { return failure(cause); }
}

/** Clear one capability's list. Scoped to a single capability so a misclick cannot empty the whole catalog. */
export async function removeAllForCapability(user: AppUser, input: unknown): Promise<ActionResult<{ removed: number }>> {
  assertAdmin(user);
  try {
    const { capability } = removeAllInput.parse(input);
    return { ok: true, removed: (await deleteCatalogModelsForCapability(capability)).length };
  } catch (cause) { return failure(cause); }
}

export async function removeModel(user: AppUser, input: unknown): Promise<ActionResult> {
  assertAdmin(user);
  try {
    await deleteCatalogModel(identifiedModel.parse(input).id);
    return { ok: true };
  } catch (cause) { return failure(cause); }
}
