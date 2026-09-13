import { noStoreHeaders } from "@/lib/ai/http";
import { ForbiddenError, forbiddenResponse, UnauthorizedError, unauthorizedResponse } from "@/lib/auth/bearer";
import { InsufficientCreditsError, insufficientCreditsResponse } from "@/lib/billing/errors";
import { SubscriptionApiError } from "@/lib/billing/subscription";

export function marketplaceRouteError(cause: unknown) {
  if (cause instanceof UnauthorizedError) return unauthorizedResponse();
  if (cause instanceof ForbiddenError) return forbiddenResponse();
  if (cause instanceof InsufficientCreditsError) return insufficientCreditsResponse(cause);
  const code = cause instanceof Error ? cause.message : "MARKETPLACE_REQUEST_FAILED";
  if (code === "NOT_FOUND") return Response.json({ code: "not_found", error: "Marketplace item not found." }, { status: 404, headers: noStoreHeaders() });
  if (code === "NOT_PURCHASED") return Response.json({ code: "not_purchased", error: "Buy this item before downloading it." }, { status: 403, headers: noStoreHeaders() });
  if (code === "NO_CONTENT") return Response.json({ code: "no_content", error: "This item has no downloadable file yet." }, { status: 409, headers: noStoreHeaders() });
  if (cause instanceof SubscriptionApiError) {
    console.error("Marketplace purchase failed at rx-subscription", { code: cause.code, status: cause.status });
    return Response.json({ code: "billing_unavailable", error: "The purchase could not be completed." }, { status: 502, headers: noStoreHeaders() });
  }
  if (code.startsWith("STORAGE_NOT_CONFIGURED:")) {
    return Response.json({ code: "storage_unavailable", error: "Downloads are not available right now." }, { status: 503, headers: noStoreHeaders() });
  }
  console.error("Marketplace request failed", { code });
  return Response.json({ code: "marketplace_request_failed", error: "The request could not be completed." }, { status: 500, headers: noStoreHeaders() });
}
