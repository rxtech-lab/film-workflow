import { noStoreHeaders } from "@/lib/ai/http";
import { isAdmin } from "@/lib/auth";
import { getRequestUser } from "@/lib/auth/bearer";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { toWireItem } from "@/lib/marketplace/presenter";
import { findPurchase, getItem } from "@/lib/marketplace/repository";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { id } = await params;
    const user = await getRequestUser(request).catch(() => null);
    const item = await getItem(id);
    if (!item || (item.status !== "published" && !(user && isAdmin(user)))) throw new Error("NOT_FOUND");
    const owned = user ? Boolean(await findPurchase(user.id, item.id)) : false;
    return Response.json(await toWireItem(item, owned), { headers: noStoreHeaders() });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
