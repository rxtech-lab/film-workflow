import { localizedNoStoreHeaders } from "@/lib/ai/http";
import { requestLocale } from "@/lib/i18n/request";
import { localizedField } from "@/lib/i18n/translations";
import { badRequestResponse, marketplaceRouteError } from "@/lib/marketplace/http";
import { listCategories, listKinds, listMediaTypes } from "@/lib/marketplace/repository";
import { CATALOG_VERSION } from "@/lib/marketplace/schema";
import { z } from "zod";

const query = z.object({ catalog_version: z.coerce.number().int().min(1).max(CATALOG_VERSION).default(1) });

/**
 * The sidebar the app draws: every kind with its label and SF Symbol, and
 * every category that has a published item, with its own symbol and count.
 * Public — the taxonomy is the same for everyone, signed in or not.
 *
 * Every label is resolved against the caller's `Accept-Language`, falling back
 * to the text an admin typed when that language has no translation.
 */
export async function GET(request: Request) {
  const locale = await requestLocale(request);
  try {
    const parsed = query.safeParse(Object.fromEntries(new URL(request.url).searchParams));
    if (!parsed.success) return badRequestResponse(locale, parsed.error.issues[0]?.message);
    const catalogVersion = parsed.data.catalog_version;
    const [kinds, categories, mediaTypes] = await Promise.all([
      listKinds(catalogVersion),
      listCategories(undefined, catalogVersion),
      listMediaTypes(catalogVersion),
    ]);
    return Response.json({
      kinds: kinds.map((entry) => ({ kind: entry.kind, label: localizedField(entry.translations, locale, "label", entry.label), icon: entry.icon, sort_order: entry.sortOrder, count: entry.count })),
      categories: categories.map((entry) => ({ kind: entry.kind, category: entry.slug, name: localizedField(entry.translations, locale, "name", entry.name), icon: entry.icon, count: entry.count })),
      media_types: mediaTypes.map((entry) => ({ kind: entry.kind, media_type: entry.mediaType, label: localizedField(entry.translations, locale, "label", entry.label), icon: entry.icon, sort_order: entry.sortOrder, count: entry.count })),
    }, { headers: localizedNoStoreHeaders(locale) });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
