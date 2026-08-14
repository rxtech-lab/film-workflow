import { UnauthorizedError, unauthorizedResponse } from "@/lib/auth/bearer";
import { InsufficientCreditsError, insufficientCreditsResponse } from "@/lib/billing/errors";

export function noStoreHeaders(extra?: HeadersInit) {
  return { "Cache-Control": "private, no-store", ...Object.fromEntries(new Headers(extra)) };
}

export function aiRouteError(cause: unknown) {
  if (cause instanceof UnauthorizedError) return unauthorizedResponse();
  if (cause instanceof InsufficientCreditsError) return insufficientCreditsResponse(cause);
  const code = cause instanceof Error ? cause.message : "AI_REQUEST_FAILED";
  if (code.startsWith("MODEL_NOT_ALLOWED:")) return Response.json({ code: "model_not_allowed", error: "This model is not available for the selected capability." }, { status: 400, headers: noStoreHeaders() });
  if (code.startsWith("PRICE_NOT_FOUND:")) return Response.json({ code: "price_not_found", error: "Pricing is not configured for this model." }, { status: 400, headers: noStoreHeaders() });
  if (code === "INVALID_PROVIDER_RESPONSE") {
    console.error("Metered AI request failed", { code });
    return Response.json({ code: "provider_response_invalid", error: "The provider returned an unreadable response." }, { status: 502, headers: noStoreHeaders() });
  }
  console.error("Metered AI request failed", { code });
  return Response.json({ code: "ai_request_failed", error: "The AI request could not be completed." }, { status: 502, headers: noStoreHeaders() });
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
