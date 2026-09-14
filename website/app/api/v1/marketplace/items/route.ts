import { localizedNoStoreHeaders } from "@/lib/ai/http";
import { getRequestUser } from "@/lib/auth/bearer";
import { requestLocale } from "@/lib/i18n/request";
import { localizedField } from "@/lib/i18n/translations";
import { badRequestResponse, marketplaceRouteError } from "@/lib/marketplace/http";
import { toWireItem } from "@/lib/marketplace/presenter";
import { listCategories, listPublishedItems, ownedItemIds } from "@/lib/marketplace/repository";
import { listQuery } from "@/lib/marketplace/schema";

/**
 * The published catalog. Sign-in is optional; with it, `owned` reflects the
 * caller's purchases. Titles, descriptions and category names come back in the
 * language `Accept-Language` asked for, and `q` searches that language too.
 */
export async function GET(request: Request) {
  const locale = await requestLocale(request);
  try {
    const parsed = listQuery.safeParse(Object.fromEntries(new URL(request.url).searchParams));
    if (!parsed.success) return badRequestResponse(locale, parsed.error.issues[0]?.message);
    const user = await getRequestUser(request).catch(() => null);
    const [page, categories] = await Promise.all([listPublishedItems(parsed.data, locale), listCategories(parsed.data.kind, parsed.data.catalog_version, parsed.data.media_type)]);
    const owned = user ? await ownedItemIds(user.id, page.items.map((item) => item.id)) : new Set<string>();
    const items = await Promise.all(page.items.map((item) => toWireItem(item, owned.has(item.id), locale)));
    return Response.json({
      items,
      total: page.total,
      page: page.currentPage,
      page_count: page.pageCount,
      page_size: page.pageSize,
      categories: categories.map((entry) => ({ kind: entry.kind, category: entry.slug, name: localizedField(entry.translations, locale, "name", entry.name), icon: entry.icon, count: entry.count })),
    }, { headers: localizedNoStoreHeaders(locale) });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
