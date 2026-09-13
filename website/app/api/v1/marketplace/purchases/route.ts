import { noStoreHeaders } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { toWireItem } from "@/lib/marketplace/presenter";
import { listPurchases } from "@/lib/marketplace/repository";

export async function GET(request: Request) {
  try {
    const user = await requireApiUser(request);
    const version = new URL(request.url).searchParams.get("catalog_version");
    const rows = (await listPurchases(user.id)).filter(({ item }) => version === "2" || item.kind !== "project_template");
    const purchases = await Promise.all(rows.map(async ({ purchase, item }) => ({
      id: purchase.id,
      item: await toWireItem(item, true),
      points_charged: purchase.pointsCharged,
      created_at: purchase.createdAt.toISOString(),
    })));
    return Response.json({ purchases }, { headers: noStoreHeaders() });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
