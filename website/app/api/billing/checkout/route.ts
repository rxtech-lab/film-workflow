import { z } from "zod";
import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { billingConfig } from "@/lib/billing/config";
import { createTopupCheckout, getCatalog, SubscriptionApiError } from "@/lib/billing/subscription";

const requestSchema = z.object({
  // The rx-subscription topup key, which is what the desktop client and the
  // credits page have always sent as a pack id.
  packId: z.string().min(1).max(40),
  source: z.enum(["web", "desktop"]).optional(),
  couponCode: z.string().max(64).optional(),
});

function siteUrl() {
  const configured = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (!configured) throw new Error("NEXT_PUBLIC_SITE_URL_NOT_CONFIGURED");
  const url = new URL(configured);
  if (process.env.NODE_ENV === "production" && url.protocol !== "https:") throw new Error("NEXT_PUBLIC_SITE_URL_MUST_BE_HTTPS");
  return url.origin;
}

export async function POST(request: Request) {
  try {
    if (!billingConfig.enabled) throw new Error("BILLING_NOT_ENABLED");
    const user = await requireApiUser(request);
    const input = requestSchema.safeParse(await request.json().catch(() => null));
    if (!input.success) return Response.json({ error: "Invalid credit pack" }, { status: 400 });

    const catalog = await getCatalog(user);
    const topup = catalog.topups.find((candidate) => candidate.key === input.data.packId);
    if (!topup) throw new Error("INVALID_CREDIT_PACK");
    // Eligibility is re-checked at checkout and again at fulfillment on the
    // rx-subscription side; this only avoids sending the user to a page that
    // would refuse them.
    if (topup.eligible === false) throw new Error("CREDIT_PACK_NOT_ELIGIBLE");

    const origin = siteUrl();
    const app = input.data.source === "desktop" ? "&app=1" : "";
    const result = await createTopupCheckout({
      user,
      topupId: topup.id,
      couponCode: input.data.couponCode,
      successUrl: `${origin}/credits?checkout=success${app}`,
      cancelUrl: `${origin}/credits?checkout=cancelled${app}`,
    });
    return Response.json({ url: result.checkoutUrl, purchaseId: result.purchaseId, discount: result.discount }, {
      status: 201,
      headers: { "Cache-Control": "private, no-store" },
    });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    if (cause instanceof SubscriptionApiError) {
      // A refused coupon or a gated pack is the buyer's to fix, so the reason
      // survives instead of collapsing into a generic failure.
      if (cause.code === "coupon_not_applicable" || cause.code === "not_eligible") {
        return Response.json({ error: cause.message, code: cause.code }, { status: cause.status, headers: { "Cache-Control": "private, no-store" } });
      }
      console.error("rx-subscription checkout failed", { code: cause.code, status: cause.status });
      return Response.json({ error: "Checkout could not be created" }, { status: 502 });
    }
    const code = cause instanceof Error ? cause.message : "CHECKOUT_FAILED";
    const status = code === "INVALID_CREDIT_PACK" ? 400 : code === "CREDIT_PACK_NOT_ELIGIBLE" ? 403 : code === "BILLING_NOT_ENABLED" ? 503 : 500;
    console.error("Checkout creation failed", { code });
    return Response.json({
      error: status === 503 ? "Credit purchases are not available yet"
        : status === 403 ? "This pack is not available on your plan"
        : "Checkout could not be created",
    }, { status });
  }
}
