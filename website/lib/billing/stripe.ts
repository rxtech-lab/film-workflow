import "server-only";

import Stripe from "stripe";
import type { AppUser } from "@/lib/auth";
import { billingConfig, creditPack } from "@/lib/billing/config";
import {
  beginStripeEvent,
  createBillingTopup,
  failTopupByCheckoutSession,
  finishStripeEvent,
  fulfillTopup,
  getBillingAccount,
  reverseTopupPoints,
  setStripeCustomerId,
  setTopupCheckoutSession,
  updateTopupInvoice,
} from "@/lib/billing/repository";

let stripeClient: Stripe | null = null;

export function stripe() {
  const key = process.env.STRIPE_SECRET_KEY?.trim();
  if (!key) throw new Error("STRIPE_NOT_CONFIGURED");
  stripeClient ??= new Stripe(key, { appInfo: { name: "RxFilm Studio" } });
  return stripeClient;
}

function siteUrl() {
  const configured = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (!configured) throw new Error("NEXT_PUBLIC_SITE_URL_NOT_CONFIGURED");
  const url = new URL(configured);
  if (process.env.NODE_ENV === "production" && url.protocol !== "https:") throw new Error("NEXT_PUBLIC_SITE_URL_MUST_BE_HTTPS");
  return url.origin;
}

async function customerForUser(user: AppUser) {
  const account = await getBillingAccount(user.id);
  const email = user.email?.trim() || undefined;
  if (account.stripeCustomerId) {
    // Keep the Stripe Customer's email in sync so Checkout pre-fills it even when
    // the customer was first created before an email was available.
    if (email) await stripe().customers.update(account.stripeCustomerId, { email });
    return account.stripeCustomerId;
  }
  const customer = await stripe().customers.create({
    email,
    name: user.name,
    metadata: { applicationUserId: user.id },
  }, { idempotencyKey: `billing-customer:${user.id}` });
  await setStripeCustomerId(user.id, customer.id);
  return customer.id;
}

export async function createTopupCheckout(user: AppUser, packId: string, source: "web" | "desktop" = "web") {
  if (!billingConfig.enabled) throw new Error("BILLING_NOT_ENABLED");
  const pack = creditPack(packId);
  if (!pack) throw new Error("INVALID_CREDIT_PACK");
  const customer = await customerForUser(user);
  const topupId = await createBillingTopup({ userId: user.id, packId: pack.id, points: pack.points, amountCents: pack.amountCents });
  const origin = siteUrl();
  const metadata = { topupId, applicationUserId: user.id, packId: pack.id };
  const session = await stripe().checkout.sessions.create({
    mode: "payment",
    customer,
    allow_promotion_codes: true,
    client_reference_id: topupId,
    success_url: `${origin}/credits?checkout=success&session_id={CHECKOUT_SESSION_ID}${source === "desktop" ? "&app=1" : ""}`,
    cancel_url: `${origin}/credits?checkout=cancelled${source === "desktop" ? "&app=1" : ""}`,
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "usd",
        unit_amount: pack.amountCents,
        product_data: {
          name: `${pack.points.toLocaleString("en-US")} RxFilm Studio credits`,
          description: "Prepaid usage credits",
          metadata: { packId: pack.id },
        },
      },
    }],
    invoice_creation: {
      enabled: true,
      invoice_data: { metadata },
    },
    payment_intent_data: { metadata },
    automatic_tax: { enabled: billingConfig.automaticTax },
    metadata,
  }, { idempotencyKey: `billing-checkout:${topupId}` });
  if (!session.url) throw new Error("STRIPE_CHECKOUT_URL_MISSING");
  await setTopupCheckoutSession(topupId, user.id, session.id);
  return { topupId, checkoutUrl: session.url };
}

function objectId(value: Stripe.Event.Data.Object) {
  return "id" in value && typeof value.id === "string" ? value.id : null;
}

function referenceId(value: string | { id: string } | null | undefined) {
  return typeof value === "string" ? value : value?.id ?? null;
}

async function invoiceDetails(invoiceId: string | null) {
  if (!invoiceId) return { invoiceId: null, hostedInvoiceUrl: null, invoicePdfUrl: null };
  const invoice = await stripe().invoices.retrieve(invoiceId);
  return {
    invoiceId: invoice.id,
    hostedInvoiceUrl: invoice.hosted_invoice_url,
    invoicePdfUrl: invoice.invoice_pdf,
  };
}

async function handleCheckoutSession(session: Stripe.Checkout.Session) {
  if (session.payment_status !== "paid") return false;
  const topupId = session.metadata?.topupId ?? session.client_reference_id;
  if (!topupId) throw new Error("STRIPE_TOPUP_METADATA_MISSING");
  const invoice = await invoiceDetails(referenceId(session.invoice));
  await fulfillTopup({
    topupId,
    sessionId: session.id,
    paymentIntentId: referenceId(session.payment_intent),
    ...invoice,
  });
  return true;
}

async function handleInvoice(invoice: Stripe.Invoice) {
  await updateTopupInvoice({
    invoiceId: invoice.id,
    topupId: invoice.metadata?.topupId ?? null,
    hostedInvoiceUrl: invoice.hosted_invoice_url,
    invoicePdfUrl: invoice.invoice_pdf,
  });
}

export async function processStripeWebhook(rawBody: string, signature: string | null) {
  const secret = process.env.STRIPE_WEBHOOK_SECRET?.trim();
  if (!secret || !signature) throw new Error("STRIPE_WEBHOOK_NOT_CONFIGURED");
  const event = stripe().webhooks.constructEvent(rawBody, signature, secret);
  if (!await beginStripeEvent({ id: event.id, type: event.type, objectId: objectId(event.data.object) })) {
    return { duplicate: true, eventId: event.id };
  }
  try {
    let handled = true;
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded":
        handled = await handleCheckoutSession(event.data.object);
        break;
      case "checkout.session.async_payment_failed":
        await failTopupByCheckoutSession(event.data.object.id);
        break;
      case "invoice.paid":
        await handleInvoice(event.data.object);
        break;
      case "charge.refunded": {
        const charge = event.data.object;
        const paymentIntentId = referenceId(charge.payment_intent);
        if (paymentIntentId) await reverseTopupPoints({
          paymentIntentId,
          refundedAmountCents: charge.amount_refunded,
          kind: "refund",
          eventId: event.id,
        });
        else handled = false;
        break;
      }
      case "charge.dispute.created": {
        const dispute = event.data.object;
        const charge = await stripe().charges.retrieve(referenceId(dispute.charge)!);
        const paymentIntentId = referenceId(charge.payment_intent);
        if (paymentIntentId) await reverseTopupPoints({
          paymentIntentId,
          refundedAmountCents: charge.amount,
          kind: "dispute",
          eventId: event.id,
        });
        else handled = false;
        break;
      }
      case "charge.dispute.closed": {
        const dispute = event.data.object;
        if (dispute.status !== "won") {
          handled = false;
          break;
        }
        const charge = await stripe().charges.retrieve(referenceId(dispute.charge)!);
        const paymentIntentId = referenceId(charge.payment_intent);
        if (paymentIntentId) await reverseTopupPoints({
          paymentIntentId,
          refundedAmountCents: 0,
          kind: "dispute_reversal",
          eventId: event.id,
        });
        else handled = false;
        break;
      }
      default:
        handled = false;
    }
    await finishStripeEvent(event.id, handled ? "processed" : "ignored");
    return { duplicate: false, eventId: event.id };
  } catch (cause) {
    await finishStripeEvent(event.id, "failed", cause instanceof Error ? cause.message.slice(0, 120) : "STRIPE_WEBHOOK_FAILED");
    throw cause;
  }
}
