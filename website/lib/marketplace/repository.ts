import "server-only";

import { and, count, desc, eq, ilike, inArray, or, sql, type SQL } from "drizzle-orm";
import { db } from "@/lib/db";
import {
  marketplaceCategories,
  marketplaceItems,
  marketplaceKinds,
  marketplacePurchases,
  type MarketplaceCategoryRow,
  type MarketplaceKindRow,
  type MarketplaceItemMetadata,
  type MarketplaceItemRow,
  type MarketplaceItemStatus,
  type MarketplacePurchaseRow,
  type MarketplaceTranslations,
} from "@/lib/db/schema";
import { DEFAULT_LOCALE, type Locale } from "@/lib/i18n/locale";
import { kindDefaultTranslations, mediaTypeDefaultTranslations } from "@/lib/marketplace/i18n";
import {
  CATALOG_VERSION,
  kindAllowed,
  kindsForCatalogVersion,
  kindsWithMediaType,
  marketplaceKindDefaults,
  marketplaceKinds as marketplaceKindValues,
  mediaTypeDefaults,
  mediaTypes,
  type CategoryInput,
  type CategoryPatch,
  type ItemInput,
  type KindPatch,
  type ListQuery,
  type MarketplaceKind,
  type MediaType,
} from "@/lib/marketplace/schema";

export const MARKETPLACE_PAGE_SIZE = 24;
export const ADMIN_PAGE_SIZE = 25;

export type { MarketplaceCategoryRow, MarketplaceItemRow, MarketplaceKindRow, MarketplacePurchaseRow };

/**
 * An item row with its category joined in. `category` is the slug — the
 * string the wire has always carried — and `categoryName` is for display,
 * with `categoryTranslations` carrying that name in the other locales.
 */
export type MarketplaceItem = MarketplaceItemRow & { category: string; categoryName: string; categoryTranslations: MarketplaceTranslations };

const itemWithCategory = {
  item: marketplaceItems,
  category: marketplaceCategories.slug,
  categoryName: marketplaceCategories.name,
  categoryTranslations: marketplaceCategories.translations,
};

/** Footage's sub-dimension, read out of the metadata jsonb. */
const mediaTypeColumn = sql<string>`${marketplaceItems.metadata} ->> 'mediaType'`;

/** Kinds an older client cannot decode are withheld rather than failing its page. */
function visibleKinds(catalogVersion: number): SQL | undefined {
  const visible = kindsForCatalogVersion(catalogVersion);
  return visible.length === marketplaceKindValues.length ? undefined : inArray(marketplaceItems.kind, visible);
}

function flatten(row: { item: MarketplaceItemRow; category: string; categoryName: string; categoryTranslations: MarketplaceTranslations }): MarketplaceItem {
  return { ...row.item, category: row.category, categoryName: row.categoryName, categoryTranslations: row.categoryTranslations };
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

function publishedFilter(query: ListQuery, locale: Locale): SQL | undefined {
  const clauses: SQL[] = [eq(marketplaceItems.status, "published")];
  const gated = visibleKinds(query.catalog_version);
  if (gated) clauses.push(gated);
  if (query.kind) clauses.push(eq(marketplaceItems.kind, query.kind));
  if (query.media_type) clauses.push(sql`${mediaTypeColumn} = ${query.media_type}`);
  if (query.category) clauses.push(eq(marketplaceCategories.slug, query.category));
  if (query.q) {
    const pattern = `%${query.q.replace(/[%_]/g, (char) => `\\${char}`)}%`;
    // Someone browsing in Chinese types Chinese: the translated text has to be
    // searchable too, or the shelf they can read is one they cannot find.
    const translated = locale === DEFAULT_LOCALE ? [] : [
      sql`jsonb_extract_path_text(${marketplaceItems.translations}, ${locale}, 'title') ILIKE ${pattern}`,
      sql`jsonb_extract_path_text(${marketplaceItems.translations}, ${locale}, 'description') ILIKE ${pattern}`,
    ];
    const match = or(ilike(marketplaceItems.title, pattern), ilike(marketplaceItems.description, pattern), ...translated);
    if (match) clauses.push(match);
  }
  return and(...clauses);
}

export async function listPublishedItems(query: ListQuery, locale: Locale = DEFAULT_LOCALE) {
  const where = publishedFilter(query, locale);
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
export async function listCategories(kind?: MarketplaceKind, catalogVersion = CATALOG_VERSION, mediaType?: MediaType) {
  return db.select({
    id: marketplaceCategories.id,
    kind: marketplaceCategories.kind,
    slug: marketplaceCategories.slug,
    name: marketplaceCategories.name,
    icon: marketplaceCategories.icon,
    translations: marketplaceCategories.translations,
    count: count(marketplaceItems.id),
  })
    .from(marketplaceCategories)
    .innerJoin(marketplaceItems, and(eq(marketplaceItems.categoryId, marketplaceCategories.id), eq(marketplaceItems.status, "published")))
    .where(and(
      kind ? eq(marketplaceCategories.kind, kind) : undefined,
      kindsForCatalogVersion(catalogVersion).length === marketplaceKindValues.length
        ? undefined
        : inArray(marketplaceCategories.kind, kindsForCatalogVersion(catalogVersion)),
      mediaType ? sql`${mediaTypeColumn} = ${mediaType}` : undefined,
    ))
    .groupBy(marketplaceCategories.id)
    .orderBy(marketplaceCategories.kind, marketplaceCategories.name);
}

/**
 * Published-item counts per media type, for the Footage sub-level of the app's
 * sidebar. Empty when the client is too old to be shown footage at all.
 */
export async function listMediaTypes(catalogVersion = CATALOG_VERSION) {
  const kinds = kindsWithMediaType.filter((kind) => kindAllowed(kind, catalogVersion));
  if (kinds.length === 0) return [];
  const rows = await db.select({ kind: marketplaceItems.kind, mediaType: mediaTypeColumn, count: count(marketplaceItems.id) })
    .from(marketplaceItems)
    .where(and(eq(marketplaceItems.status, "published"), inArray(marketplaceItems.kind, kinds)))
    .groupBy(marketplaceItems.kind, mediaTypeColumn);
  const byKey = new Map(rows.map((row) => [`${row.kind}/${row.mediaType}`, row.count]));
  return kinds.flatMap((kind) => mediaTypes.map((mediaType) => ({
    kind,
    mediaType,
    ...mediaTypeDefaults[mediaType],
    // These shelves have no table of their own; their names are built in.
    translations: mediaTypeDefaultTranslations(mediaType),
    count: byKey.get(`${kind}/${mediaType}`) ?? 0,
  }))).sort((a, b) => a.sortOrder - b.sortOrder);
}

/** Every category, including empty ones, for the admin form's picker. */
export async function listAllCategories() {
  return db.select().from(marketplaceCategories).orderBy(marketplaceCategories.kind, marketplaceCategories.name);
}

/** Include drafts in the total: any item prevents its category from being deleted. */
export async function listCategoriesForAdmin() {
  return db.select({
    id: marketplaceCategories.id,
    kind: marketplaceCategories.kind,
    slug: marketplaceCategories.slug,
    name: marketplaceCategories.name,
    icon: marketplaceCategories.icon,
    translations: marketplaceCategories.translations,
    count: sql<number>`count(${marketplaceItems.id}) filter (where ${marketplaceItems.status} = 'published')`.mapWith(Number),
    totalCount: count(marketplaceItems.id),
  })
    .from(marketplaceCategories)
    .leftJoin(marketplaceItems, eq(marketplaceItems.categoryId, marketplaceCategories.id))
    .groupBy(marketplaceCategories.id)
    .orderBy(marketplaceCategories.kind, marketplaceCategories.name);
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
    icon: input.icon,
    translations: input.translations,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoNothing().returning())[0];
  if (!inserted) throw new Error("CATEGORY_EXISTS");
  return inserted;
}

/** Renames or re-icons a category. The slug stays put so published items keep filtering the same. */
export async function updateCategory(patch: CategoryPatch) {
  const updated = (await db.update(marketplaceCategories)
    .set({ name: patch.name, icon: patch.icon, translations: patch.translations, updatedAt: new Date() })
    .where(eq(marketplaceCategories.id, patch.id))
    .returning())[0];
  if (!updated) throw new Error("CATEGORY_NOT_FOUND");
  return updated;
}

/** The restrictive foreign key also protects against an item being added during deletion. */
export async function deleteCategory(id: string) {
  try {
    const deleted = (await db.delete(marketplaceCategories)
      .where(eq(marketplaceCategories.id, id))
      .returning({ id: marketplaceCategories.id }))[0];
    if (!deleted) throw new Error("CATEGORY_NOT_FOUND");
  } catch (cause) {
    // Drizzle wraps driver errors in `cause`; the driver may also throw directly.
    const error = cause as { code?: string; cause?: { code?: string } } | null;
    if (error?.code === "23503" || error?.cause?.code === "23503") throw new Error("CATEGORY_HAS_ITEMS");
    throw cause;
  }
}

// MARK: - Kinds

/**
 * How each kind presents itself, with the number of published items. Kinds
 * missing a row fall back to the built-in defaults, so the sidebar is whole
 * even before the seed migration has run.
 */
export async function listKinds(catalogVersion = CATALOG_VERSION) {
  const [rows, counts] = await Promise.all([
    db.select().from(marketplaceKinds),
    db.select({ kind: marketplaceItems.kind, count: count(marketplaceItems.id) })
      .from(marketplaceItems)
      .where(eq(marketplaceItems.status, "published"))
      .groupBy(marketplaceItems.kind),
  ]);
  const byKind = new Map(rows.map((row) => [row.kind, row]));
  const countByKind = new Map(counts.map((row) => [row.kind, row.count]));
  return marketplaceKindValues
    .filter((kind) => kindAllowed(kind, catalogVersion))
    .map((kind) => {
      const defaults = marketplaceKindDefaults[kind];
      const row = byKind.get(kind);
      return {
        kind,
        label: row?.label ?? defaults.label,
        icon: row?.icon ?? defaults.icon,
        sortOrder: row?.sortOrder ?? defaults.sortOrder,
        // No row yet: the built-in label, in every language, so the sidebar
        // reads the same before the seed migration as after it.
        translations: row?.translations ?? kindDefaultTranslations(kind),
        count: countByKind.get(kind) ?? 0,
      };
    })
    .sort((a, b) => a.sortOrder - b.sortOrder || a.label.localeCompare(b.label));
}

/** Writes a kind's sidebar presentation, inserting the row the first time an admin edits it. */
export async function upsertKind(patch: KindPatch) {
  const now = new Date();
  return (await db.insert(marketplaceKinds).values({
    kind: patch.kind,
    label: patch.label,
    icon: patch.icon,
    sortOrder: patch.sortOrder,
    translations: patch.translations,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoUpdate({
    target: marketplaceKinds.kind,
    set: { label: patch.label, icon: patch.icon, sortOrder: patch.sortOrder, translations: patch.translations, updatedAt: now },
  }).returning())[0];
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

export async function listAllItemsForAdmin(requestedPage: number, filters: { createdBy?: string; status?: MarketplaceItemStatus; query?: string } = {}) {
  const pattern = filters.query ? `%${filters.query.replace(/[%_\\]/g, (char) => `\\${char}`)}%` : undefined;
  const where = and(
    filters.createdBy ? eq(marketplaceItems.createdBy, filters.createdBy) : undefined,
    filters.status ? eq(marketplaceItems.status, filters.status) : undefined,
    pattern ? or(ilike(marketplaceItems.title, pattern), ilike(marketplaceItems.description, pattern)) : undefined,
  );
  const [{ total }] = await db.select({ total: count() }).from(marketplaceItems).where(where);
  const { pageCount, currentPage, offset } = page(total, requestedPage, ADMIN_PAGE_SIZE);
  const rows = await itemsJoined()
    .where(where)
    .orderBy(desc(marketplaceItems.updatedAt), desc(marketplaceItems.id))
    .limit(ADMIN_PAGE_SIZE)
    .offset(offset);
  return { items: rows.map(flatten), total, currentPage, pageCount };
}

export async function insertItem(input: ItemInput, createdBy: string) {
  const now = new Date();
  const id = input.draftId ?? crypto.randomUUID();
  const inserted = (await db.insert(marketplaceItems).values({
    id,
    kind: input.kind,
    categoryId: input.categoryId,
    title: input.title,
    description: input.description,
    pricePoints: input.pricePoints,
    metadata: input.metadata,
    translations: input.translations,
    status: "draft",
    createdBy,
    createdAt: now,
    updatedAt: now,
    publishedAt: null,
  }).onConflictDoNothing({ target: marketplaceItems.id }).returning())[0];
  if (inserted) return inserted;
  const existing = await requireItem(id);
  if (existing.createdBy !== createdBy) throw new Error("DRAFT_ID_CONFLICT");
  return existing;
}

export async function updateItem(id: string, patch: Partial<ItemInput>) {
  const { draftId: _draftId, ...columns } = patch;
  void _draftId;
  return (await db.update(marketplaceItems)
    .set({ ...columns, updatedAt: new Date() })
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
