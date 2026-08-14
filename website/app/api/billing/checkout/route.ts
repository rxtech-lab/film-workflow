import { z } from "zod";
import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { createTopupCheckout } from "@/lib/billing/stripe";

const requestSchema = z.object({
  packId: z.string().min(1).max(40),
  source: z.enum(["web", "desktop"]).optional(),
});

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const input = requestSchema.safeParse(await request.json().catch(() => null));
    if (!input.success) return Response.json({ error: "Invalid credit pack" }, { status: 400 });
    const result = await createTopupCheckout(user, input.data.packId, input.data.source);
    return Response.json({ url: result.checkoutUrl }, { status: 201, headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    const code = cause instanceof Error ? cause.message : "CHECKOUT_FAILED";
    const status = code === "INVALID_CREDIT_PACK" ? 400 : code === "BILLING_NOT_ENABLED" ? 503 : 500;
    console.error("Stripe Checkout creation failed", { code });
    return Response.json({ error: status === 503 ? "Credit purchases are not available yet" : "Checkout could not be created" }, { status });
  }
}
