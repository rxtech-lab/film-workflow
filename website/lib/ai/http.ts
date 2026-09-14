import { UnauthorizedError, unauthorizedResponse } from "@/lib/auth/bearer";
import { InsufficientCreditsError, insufficientCreditsResponse } from "@/lib/billing/errors";
import { localeHeaders, type Locale } from "@/lib/i18n/locale";
import { requestLocale } from "@/lib/i18n/request";
import { t } from "@/lib/i18n/messages";

export function noStoreHeaders(extra?: HeadersInit) {
  return { "Cache-Control": "private, no-store", ...Object.fromEntries(new Headers(extra)) };
}

/** `noStoreHeaders` for a body whose text was chosen by `Accept-Language`. */
export function localizedNoStoreHeaders(locale: Locale, extra?: HeadersInit) {
  return noStoreHeaders(localeHeaders(locale, extra));
}

export async function aiRouteError(cause: unknown) {
  if (cause instanceof UnauthorizedError) return unauthorizedResponse();
  if (cause instanceof InsufficientCreditsError) return insufficientCreditsResponse(cause);
  const locale = await requestLocale();
  const headers = localizedNoStoreHeaders(locale);
  const code = cause instanceof Error ? cause.message : "AI_REQUEST_FAILED";
  if (code.startsWith("MODEL_NOT_ALLOWED:")) return Response.json({ code: "model_not_allowed", error: t(locale, "error.ai.modelNotAllowed") }, { status: 400, headers });
  if (code.startsWith("PRICE_NOT_FOUND:")) return Response.json({ code: "price_not_found", error: t(locale, "error.ai.priceNotFound") }, { status: 400, headers });
  if (code === "INVALID_PROVIDER_RESPONSE") {
    console.error("Metered AI request failed", { code });
    return Response.json({ code: "provider_response_invalid", error: t(locale, "error.ai.providerResponseInvalid") }, { status: 502, headers });
  }
  console.error("Metered AI request failed", { code });
  return Response.json({ code: "ai_request_failed", error: t(locale, "error.ai.requestFailed") }, { status: 502, headers });
}

export async function providerError(response: Response) {
  const text = await response.text();
  let message = text.slice(0, 600);
  try {
    const body = JSON.parse(text) as { error?: { message?: string } | string; message?: string };
    message = typeof body.error === "string" ? body.error : body.error?.message ?? body.message ?? message;
  } catch {}
  throw new Error(`PROVIDER_${response.status}:${message}`);
}
