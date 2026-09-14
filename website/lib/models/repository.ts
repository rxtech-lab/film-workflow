import "server-only";

import { and, asc, eq } from "drizzle-orm";
import { db } from "@/lib/db";
import { catalogModels, type Capability, type CatalogModelRow } from "@/lib/db/schema";

/** Every curated row, enabled or not — the admin page needs to show and edit the disabled ones too. */
export async function listCatalogModels(): Promise<CatalogModelRow[]> {
  return db.select().from(catalogModels).orderBy(asc(catalogModels.sortOrder), asc(catalogModels.modelId));
}

/** What the catalog actually serves. */
export async function enabledCatalogModels(): Promise<CatalogModelRow[]> {
  return db.select().from(catalogModels)
    .where(eq(catalogModels.enabled, true))
    .orderBy(asc(catalogModels.sortOrder), asc(catalogModels.modelId));
}

export async function getCatalogModel(id: string) {
  return (await db.select().from(catalogModels).where(eq(catalogModels.id, id)).limit(1))[0];
}

export async function insertCatalogModel(input: { modelId: string; capability: Capability }) {
  const now = new Date();
  const inserted = (await db.insert(catalogModels).values({
    id: crypto.randomUUID(),
    modelId: input.modelId,
    capability: input.capability,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoNothing().returning())[0];
  if (!inserted) throw new Error("MODEL_ALREADY_CURATED");
  return inserted;
}

/**
 * Bulk add, for seeding and for the "add all discovered" button. Conflicts are
 * skipped rather than updated, so a re-run tops the list up without undoing the
 * renames, ordering and disables an admin has already made.
 */
export async function insertCatalogModels(rows: { modelId: string; capability: Capability }[]) {
  if (rows.length === 0) return [];
  const now = new Date();
  return db.insert(catalogModels).values(rows.map((row) => ({
    id: crypto.randomUUID(),
    modelId: row.modelId,
    capability: row.capability,
    createdAt: now,
    updatedAt: now,
  }))).onConflictDoNothing().returning();
}

export async function updateCatalogModel(patch: { id: string; displayNameOverride: string | null; sortOrder: number }) {
  const updated = (await db.update(catalogModels)
    .set({ displayNameOverride: patch.displayNameOverride, sortOrder: patch.sortOrder, updatedAt: new Date() })
    .where(eq(catalogModels.id, patch.id))
    .returning())[0];
  if (!updated) throw new Error("NOT_FOUND");
  return updated;
}

export async function setCatalogModelEnabled(id: string, enabled: boolean) {
  const updated = (await db.update(catalogModels)
    .set({ enabled, updatedAt: new Date() })
    .where(eq(catalogModels.id, id))
    .returning())[0];
  if (!updated) throw new Error("NOT_FOUND");
  return updated;
}

/**
 * Move the capability's default onto one row.
 *
 * Two statements through `db.batch`, not `db.transaction` — the Neon HTTP driver
 * throws on `transaction()`. Batched statements still run as one atomic unit, so
 * the partial unique index never sees two defaults for a capability mid-flight.
 */
export async function setDefaultCatalogModel(id: string) {
  const row = await getCatalogModel(id);
  if (!row) throw new Error("NOT_FOUND");
  const now = new Date();
  await db.batch([
    db.update(catalogModels)
      .set({ isDefault: false, updatedAt: now })
      .where(and(eq(catalogModels.capability, row.capability), eq(catalogModels.isDefault, true))),
    db.update(catalogModels).set({ isDefault: true, updatedAt: now }).where(eq(catalogModels.id, id)),
  ]);
  return row;
}

/** Clear one capability's list. Returns the rows removed, so the caller can report a count. */
export async function deleteCatalogModelsForCapability(capability: Capability) {
  return db.delete(catalogModels).where(eq(catalogModels.capability, capability)).returning();
}

export async function deleteCatalogModel(id: string) {
  const deleted = (await db.delete(catalogModels).where(eq(catalogModels.id, id)).returning())[0];
  if (!deleted) throw new Error("NOT_FOUND");
  return deleted;
}
