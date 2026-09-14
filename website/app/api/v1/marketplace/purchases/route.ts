import { localizedNoStoreHeaders } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";
import { requestLocale } from "@/lib/i18n/request";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { toWireItem } from "@/lib/marketplace/presenter";
import { listPurchases } from "@/lib/marketplace/repository";
import { kindAllowed } from "@/lib/marketplace/schema";

export async function GET(request: Request) {
  const locale = await requestLocale(request);
  try {
    const user = await requireApiUser(request);
    // Numeric, not a string compare: a v3 client would otherwise lose every
    // purchased project template.
    const version = Number(new URL(request.url).searchParams.get("catalog_version")) || 1;
    const rows = (await listPurchases(user.id)).filter(({ item }) => kindAllowed(item.kind, version));
    const purchases = await Promise.all(rows.map(async ({ purchase, item }) => ({
      id: purchase.id,
      item: await toWireItem(item, true, locale),
      points_charged: purchase.pointsCharged,
      created_at: purchase.createdAt.toISOString(),
    })));
    return Response.json({ purchases }, { headers: localizedNoStoreHeaders(locale) });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
