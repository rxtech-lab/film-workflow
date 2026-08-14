import { processStripeWebhook } from "@/lib/billing/stripe";

export async function POST(request: Request) {
  const rawBody = await request.text();
  try {
    const result = await processStripeWebhook(rawBody, request.headers.get("stripe-signature"));
    return Response.json({ received: true, duplicate: result.duplicate });
  } catch (cause) {
    const code = cause instanceof Error ? cause.message : "STRIPE_WEBHOOK_FAILED";
    console.error("Stripe webhook processing failed", { code });
    return Response.json({ error: "Webhook could not be processed" }, { status: 400 });
  }
}
