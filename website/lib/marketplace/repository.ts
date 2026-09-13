import "server-only";

import { and, count, desc, eq, ilike, inArray, or, type SQL } from "drizzle-orm";
import { db } from "@/lib/db";
import {
  marketplaceCategories,
  marketplaceItems,
  marketplacePurchases,
  type MarketplaceCategoryRow,
  type MarketplaceItemMetadata,
  type MarketplaceItemRow,
  type MarketplaceItemStatus,
  type MarketplacePurchaseRow,
} from "@/lib/db/schema";
import type { CategoryInput, ItemInput, ListQuery, MarketplaceKind } from "@/lib/marketplace/schema";

export const MARKETPLACE_PAGE_SIZE = 24;
export const ADMIN_PAGE_SIZE = 25;

export type { MarketplaceCategoryRow, MarketplaceItemRow, MarketplacePurchaseRow };

/**
 * An item row with its category joined in. `category` is the slug — the
 * string the wire has always carried — and `categoryName` is for display.
 */
export type MarketplaceItem = MarketplaceItemRow & { category: string; categoryName: string };

const itemWithCategory = { item: marketplaceItems, category: marketplaceCategories.slug, categoryName: marketplaceCategories.name };

function flatten(row: { item: MarketplaceItemRow; category: string; categoryName: string }): MarketplaceItem {
  return { ...row.item, category: row.category, categoryName: row.categoryName };
}

function itemsJoined() {
  return db.select(itemWithCategory).from(marketplaceItems)
    .innerJoin(marketplaceCategories, eq(marketplaceCategories.id, marketplaceItems.categoryId));
}

function page(total: number, requested: number, size: number) {
  const pageCount = Math.max(1, Math.ceil(total / size));
  const currentPage = Math.min(Math.max(1, requested), pageCount);
  return { pageCount, currentPage, offset: (currentPage - 1) * size };
}

function publishedFilter(query: ListQuery): SQL | undefined {
  const clauses: SQL[] = [eq(marketplaceItems.status, "published")];
  if (query.kind) clauses.push(eq(marketplaceItems.kind, query.kind));
  if (query.category) clauses.push(eq(marketplaceCategories.slug, query.category));
  if (query.q) {
    const pattern = `%${query.q.replace(/[%_]/g, (char) => `\\${char}`)}%`;
    const match = or(ilike(marketplaceItems.title, pattern), ilike(marketplaceItems.description, pattern));
    if (match) clauses.push(match);
  }
  return and(...clauses);
}

export async function listPublishedItems(query: ListQuery) {
  const where = publishedFilter(query);
  const [{ total }] = await db.select({ total: count() }).from(marketplaceItems)
    .innerJoin(marketplaceCategories, eq(marketplaceCategories.id, marketplaceItems.categoryId))
    .where(where);
  const { pageCount, currentPage, offset } = page(total, query.page, MARKETPLACE_PAGE_SIZE);
  const rows = await itemsJoined()
    .where(where)
    .orderBy(desc(marketplaceItems.publishedAt), desc(marketplaceItems.id))
    .limit(MARKETPLACE_PAGE_SIZE)
    .offset(offset);
  return { items: rows.map(flatten), total, currentPage, pageCount, pageSize: MARKETPLACE_PAGE_SIZE };
}

/** Categories that have at least one published item, with the count, for the app's sidebar. */
export async function listCategories(kind?: MarketplaceKind) {
  return db.select({
    id: marketplaceCategories.id,
    kind: marketplaceCategories.kind,
    slug: marketplaceCategories.slug,
    name: marketplaceCategories.name,
    count: count(marketplaceItems.id),
  })
    .from(marketplaceCategories)
    .innerJoin(marketplaceItems, and(eq(marketplaceItems.categoryId, marketplaceCategories.id), eq(marketplaceItems.status, "published")))
    .where(kind ? eq(marketplaceCategories.kind, kind) : undefined)
    .groupBy(marketplaceCategories.id)
    .orderBy(marketplaceCategories.kind, marketplaceCategories.name);
}

/** Every category, including empty ones, for the admin form's picker. */
export async function listAllCategories() {
  return db.select().from(marketplaceCategories).orderBy(marketplaceCategories.kind, marketplaceCategories.name);
}

export async function getCategory(id: string) {
  return (await db.select().from(marketplaceCategories).where(eq(marketplaceCategories.id, id)).limit(1))[0];
}

export async function insertCategory(input: CategoryInput) {
  const now = new Date();
  const inserted = (await db.insert(marketplaceCategories).values({
    id: crypto.randomUUID(),
    kind: input.kind,
    slug: input.slug,
    name: input.name,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoNothing().returning())[0];
  if (!inserted) throw new Error("CATEGORY_EXISTS");
  return inserted;
}

export async function getItem(id: string) {
  const row = (await itemsJoined().where(eq(marketplaceItems.id, id)).limit(1))[0];
  return row ? flatten(row) : undefined;
}

export async function requireItem(id: string) {
  const item = await getItem(id);
  if (!item) throw new Error("NOT_FOUND");
  return item;
}

export async function listAllItemsForAdmin(requestedPage: number) {
  const [{ total }] = await db.select({ total: count() }).from(marketplaceItems);
  const { pageCount, currentPage, offset } = page(total, requestedPage, ADMIN_PAGE_SIZE);
  const rows = await itemsJoined()
    .orderBy(desc(marketplaceItems.updatedAt), desc(marketplaceItems.id))
    .limit(ADMIN_PAGE_SIZE)
    .offset(offset);
  return { items: rows.map(flatten), total, currentPage, pageCount };
}

export async function insertItem(input: ItemInput, createdBy: string) {
  const now = new Date();
  return (await db.insert(marketplaceItems).values({
    id: crypto.randomUUID(),
    kind: input.kind,
    categoryId: input.categoryId,
    title: input.title,
    description: input.description,
    pricePoints: input.pricePoints,
    metadata: input.metadata,
    status: "draft",
    createdBy,
    createdAt: now,
    updatedAt: now,
    publishedAt: null,
  }).returning())[0];
}

export async function updateItem(id: string, patch: Partial<ItemInput>) {
  return (await db.update(marketplaceItems)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(marketplaceItems.id, id))
    .returning())[0];
}

export type AssetColumns = Pick<MarketplaceItemRow, "previewImageKey" | "previewVideoKey" | "contentKey" | "contentFilename" | "contentSizeBytes" | "contentType">;

export async function updateItemAssets(id: string, patch: Partial<AssetColumns> & { metadata?: MarketplaceItemMetadata }) {
  return (await db.update(marketplaceItems)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(marketplaceItems.id, id))
    .returning())[0];
}

export async function setItemStatus(id: string, status: MarketplaceItemStatus) {
  const now = new Date();
  return (await db.update(marketplaceItems)
    .set({ status, updatedAt: now, ...(status === "published" ? { publishedAt: now } : {}) })
    .where(eq(marketplaceItems.id, id))
    .returning())[0];
}

export async function deleteItemRow(id: string) {
  await db.delete(marketplaceItems).where(eq(marketplaceItems.id, id));
}

export async function countPurchases(itemId: string) {
  const [{ total }] = await db.select({ total: count() }).from(marketplacePurchases).where(eq(marketplacePurchases.itemId, itemId));
  return total;
}

export async function findPurchase(userId: string, itemId: string) {
  return (await db.select().from(marketplacePurchases)
    .where(and(eq(marketplacePurchases.userId, userId), eq(marketplacePurchases.itemId, itemId)))
    .limit(1))[0];
}

export async function insertPurchase(row: {
  userId: string;
  itemId: string;
  pointsCharged: number;
  reservationId: string | null;
  idempotencyKey: string;
}) {
  const inserted = (await db.insert(marketplacePurchases).values({
    id: crypto.randomUUID(),
    ...row,
    createdAt: new Date(),
  }).onConflictDoNothing().returning())[0];
  // A concurrent purchase of the same item won the race; its row is the entitlement either way.
  return inserted ?? (await findPurchase(row.userId, row.itemId))!;
}

export async function listPurchases(userId: string) {
  const rows = await db.select({ purchase: marketplacePurchases, ...itemWithCategory })
    .from(marketplacePurchases)
    .innerJoin(marketplaceItems, eq(marketplaceItems.id, marketplacePurchases.itemId))
    .innerJoin(marketplaceCategories, eq(marketplaceCategories.id, marketplaceItems.categoryId))
    .where(eq(marketplacePurchases.userId, userId))
    .orderBy(desc(marketplacePurchases.createdAt));
  return rows.map(({ purchase, ...item }) => ({ purchase, item: flatten(item) }));
}

export async function ownedItemIds(userId: string, itemIds: string[]) {
  if (itemIds.length === 0) return new Set<string>();
  const rows = await db.select({ itemId: marketplacePurchases.itemId }).from(marketplacePurchases)
    .where(and(eq(marketplacePurchases.userId, userId), inArray(marketplacePurchases.itemId, itemIds)));
  return new Set(rows.map((row) => row.itemId));
}
