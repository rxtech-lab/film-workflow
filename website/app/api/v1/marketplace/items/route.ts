import { noStoreHeaders } from "@/lib/ai/http";
import { getRequestUser } from "@/lib/auth/bearer";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { toWireItem } from "@/lib/marketplace/presenter";
import { listCategories, listPublishedItems, ownedItemIds } from "@/lib/marketplace/repository";
import { listQuery } from "@/lib/marketplace/schema";

/** The published catalog. Sign-in is optional; with it, `owned` reflects the caller's purchases. */
export async function GET(request: Request) {
  try {
    const parsed = listQuery.safeParse(Object.fromEntries(new URL(request.url).searchParams));
    if (!parsed.success) {
      return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid query." }, { status: 400, headers: noStoreHeaders() });
    }
    const user = await getRequestUser(request).catch(() => null);
    const [page, categories] = await Promise.all([listPublishedItems(parsed.data), listCategories(parsed.data.kind, parsed.data.catalog_version)]);
    const owned = user ? await ownedItemIds(user.id, page.items.map((item) => item.id)) : new Set<string>();
    const items = await Promise.all(page.items.map((item) => toWireItem(item, owned.has(item.id))));
    return Response.json({
      items,
      total: page.total,
      page: page.currentPage,
      page_count: page.pageCount,
      page_size: page.pageSize,
      categories: categories.map((entry) => ({ kind: entry.kind, category: entry.slug, name: entry.name, icon: entry.icon, count: entry.count })),
    }, { headers: noStoreHeaders() });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
