import { noStoreHeaders } from "@/lib/ai/http";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { listCategories, listKinds } from "@/lib/marketplace/repository";
import { z } from "zod";

const query = z.object({ catalog_version: z.coerce.number().int().min(1).max(2).default(1) });

/**
 * The sidebar the app draws: every kind with its label and SF Symbol, and
 * every category that has a published item, with its own symbol and count.
 * Public — the taxonomy is the same for everyone, signed in or not.
 */
export async function GET(request: Request) {
  try {
    const parsed = query.safeParse(Object.fromEntries(new URL(request.url).searchParams));
    if (!parsed.success) {
      return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid query." }, { status: 400, headers: noStoreHeaders() });
    }
    const catalogVersion = parsed.data.catalog_version;
    const [kinds, categories] = await Promise.all([listKinds(catalogVersion), listCategories(undefined, catalogVersion)]);
    return Response.json({
      kinds: kinds.map((entry) => ({ kind: entry.kind, label: entry.label, icon: entry.icon, sort_order: entry.sortOrder, count: entry.count })),
      categories: categories.map((entry) => ({ kind: entry.kind, category: entry.slug, name: entry.name, icon: entry.icon, count: entry.count })),
    }, { headers: noStoreHeaders() });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
