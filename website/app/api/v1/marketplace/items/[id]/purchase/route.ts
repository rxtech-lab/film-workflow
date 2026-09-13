import { noStoreHeaders } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { purchaseItem } from "@/lib/marketplace/purchase";

/** Idempotent per user and item: a second call returns the existing purchase with `already_owned`. */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const user = await requireApiUser(request);
    const { id } = await params;
    const { purchase, alreadyOwned } = await purchaseItem(user, id);
    return Response.json({
      purchase_id: purchase.id,
      item_id: purchase.itemId,
      points_charged: purchase.pointsCharged,
      already_owned: alreadyOwned,
      created_at: purchase.createdAt.toISOString(),
    }, { status: alreadyOwned ? 200 : 201, headers: noStoreHeaders() });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
