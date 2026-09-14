import { localizedNoStoreHeaders } from "@/lib/ai/http";
import { ForbiddenError, forbiddenResponse, UnauthorizedError, unauthorizedResponse } from "@/lib/auth/bearer";
import { InsufficientCreditsError, insufficientCreditsResponse } from "@/lib/billing/errors";
import { SubscriptionApiError } from "@/lib/billing/subscription";
import { type Locale } from "@/lib/i18n/locale";
import { requestLocale } from "@/lib/i18n/request";
import { t } from "@/lib/i18n/messages";

export async function marketplaceRouteError(cause: unknown) {
  if (cause instanceof UnauthorizedError) return unauthorizedResponse();
  if (cause instanceof ForbiddenError) return forbiddenResponse();
  if (cause instanceof InsufficientCreditsError) return insufficientCreditsResponse(cause);
  const locale = await requestLocale();
  const headers = localizedNoStoreHeaders(locale);
  const code = cause instanceof Error ? cause.message : "MARKETPLACE_REQUEST_FAILED";
  if (code === "NOT_FOUND") return Response.json({ code: "not_found", error: t(locale, "error.marketplace.notFound") }, { status: 404, headers });
  if (code === "NOT_PURCHASED") return Response.json({ code: "not_purchased", error: t(locale, "error.marketplace.notPurchased") }, { status: 403, headers });
  if (code === "NO_CONTENT") return Response.json({ code: "no_content", error: t(locale, "error.marketplace.noContent") }, { status: 409, headers });
  if (cause instanceof SubscriptionApiError) {
    console.error("Marketplace purchase failed at rx-subscription", { code: cause.code, status: cause.status });
    return Response.json({ code: "billing_unavailable", error: t(locale, "error.marketplace.billingUnavailable") }, { status: 502, headers });
  }
  if (code.startsWith("STORAGE_NOT_CONFIGURED:")) {
    return Response.json({ code: "storage_unavailable", error: t(locale, "error.marketplace.storageUnavailable") }, { status: 503, headers });
  }
  console.error("Marketplace request failed", { code });
  return Response.json({ code: "marketplace_request_failed", error: t(locale, "error.marketplace.requestFailed") }, { status: 500, headers });
}

/**
 * A query the route could not parse. The reason zod gives is English and
 * developer-facing, so it rides along as `details` while `error` — the string
 * the app puts in front of someone — is translated.
 */
export function badRequestResponse(locale: Locale, details?: string) {
  return Response.json(
    { code: "bad_request", error: t(locale, "error.invalidRequest"), ...(details ? { details } : {}) },
    { status: 400, headers: localizedNoStoreHeaders(locale) },
  );
}
