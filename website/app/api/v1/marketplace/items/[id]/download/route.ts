import { noStoreHeaders } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { findPurchase, getItem } from "@/lib/marketplace/repository";
import { objectDownloadURL } from "@/lib/storage/s3";

/**
 * A short-lived URL for the content file. Free items pass the purchase check
 * without a row so the app never has to "buy" a free item first.
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const user = await requireApiUser(request);
    const { id } = await params;
    const item = await getItem(id);
    if (!item || item.status !== "published") throw new Error("NOT_FOUND");
    if (item.pricePoints > 0 && !(await findPurchase(user.id, item.id))) throw new Error("NOT_PURCHASED");
    if (!item.contentKey) throw new Error("NO_CONTENT");
    const ttlSeconds = Number(process.env.S3_PRESIGN_TTL_SECONDS ?? 900);
    return Response.json({
      url: await objectDownloadURL(item.contentKey),
      filename: item.contentFilename ?? "content",
      content_type: item.contentType ?? "application/octet-stream",
      size_bytes: item.contentSizeBytes,
      expires_at: new Date(Date.now() + (Number.isFinite(ttlSeconds) ? ttlSeconds : 900) * 1000).toISOString(),
      metadata: item.metadata,
    }, { headers: noStoreHeaders() });
  } catch (cause) {
    return marketplaceRouteError(cause);
  }
}
