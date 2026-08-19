import "server-only";

import type { AppUser } from "@/lib/auth";
import { InsufficientCreditsError } from "@/lib/billing/errors";

/**
 * Client for rx-subscription's machine API (`/api/v1`).
 *
 * rx-subscription owns balances, purchases, and the Stripe relationship; this
 * app owns only the per-model provider cost that rx-subscription does not
 * track. Users are addressed by their rxlab id, which is the access token `sub`
 * and therefore `AppUser.id` — rx-subscription creates its own user record on
 * first reference, so nothing needs registering up front.
 */

function baseUrl() {
  const configured = process.env.RX_SUBSCRIPTION_URL?.trim();
  if (!configured) throw new Error("RX_SUBSCRIPTION_URL_NOT_CONFIGURED");
  return configured.replace(/\/+$/, "");
}

function apiKey() {
  const key = process.env.RX_SUBSCRIPTION_API_KEY?.trim();
  if (!key) throw new Error("RX_SUBSCRIPTION_API_KEY_NOT_CONFIGURED");
  return key;
}

/** The balance unit film-workflow meters in. 1,000 points = 1 USD of provider cost. */
export const BALANCE_UNIT = process.env.RX_SUBSCRIPTION_BALANCE_UNIT?.trim() || "points";

export class SubscriptionApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    description: string,
  ) {
    super(description);
    this.name = "SubscriptionApiError";
  }
}

type ErrorBody = { error?: string; error_description?: string; available?: number; required?: number };

async function request<T>(path: string, init?: { method?: string; body?: unknown; query?: Record<string, string | undefined> }): Promise<T> {
  const url = new URL(`${baseUrl()}/api/v1${path}`);
  for (const [key, value] of Object.entries(init?.query ?? {})) {
    if (value !== undefined) url.searchParams.set(key, value);
  }
  const response = await fetch(url, {
    method: init?.method ?? "GET",
    headers: {
      "X-Api-Key": apiKey(),
      ...(init?.body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: init?.body === undefined ? undefined : JSON.stringify(init.body),
    cache: "no-store",
  });
  if (response.ok) return await response.json() as T;

  const body = await response.json().catch(() => null) as ErrorBody | null;
  const code = body?.error ?? `http_${response.status}`;
  // A refused spend is the caller's to render, not a fault to log, so it keeps
  // the shape the AI routes already return a 402 from.
  if (code === "insufficient_balance") {
    throw new InsufficientCreditsError(body?.available ?? 0, body?.required ?? 0);
  }
  throw new SubscriptionApiError(response.status, code, body?.error_description ?? `rx-subscription ${path} failed`);
}

export type Balance = {
  unit: string;
  name: string;
  symbol?: string;
  precision: number;
  amount: number;
  available: number;
};

export type Entitlements = {
  user: { id: string; rxlabUserId: string; level: number | null; levelKey: string | null };
  plans: unknown[];
  roles: string[];
  permissions: string[];
  balances: Balance[];
  usage: Array<{ key: string; name: string; used: number; limit: number | null; remaining: number | null; resetsAt: string | null; resetPolicy: string }>;
};

export async function getEntitlements(user: AppUser) {
  return request<Entitlements>("/entitlements", {
    query: { rxlabUserId: user.id, email: user.email || undefined },
  });
}

/** The metered balance, or a zeroed one when the user has never transacted. */
export async function getBalance(user: AppUser) {
  const entitlements = await getEntitlements(user);
  return entitlements.balances.find((balance) => balance.unit === BALANCE_UNIT)
    ?? { unit: BALANCE_UNIT, name: "Credits", precision: 0, amount: 0, available: 0 };
}

export type TopupProduct = {
  id: string;
  key: string;
  name: string;
  description: string | null;
  unit: string | null;
  amount: number;
  priceAmountCents: number;
  currency: string;
  eligible: boolean | null;
  blockedBy: string[] | null;
};

export async function getCatalog(user?: AppUser) {
  const catalog = await request<{ plans: unknown[]; topups: TopupProduct[] }>("/catalog", {
    query: { rxlabUserId: user?.id },
  });
  return {
    ...catalog,
    topups: catalog.topups.filter((topup) => topup.unit === null || topup.unit === BALANCE_UNIT),
  };
}

export async function createTopupCheckout(input: {
  user: AppUser;
  topupId: string;
  successUrl: string;
  cancelUrl: string;
  couponCode?: string;
}) {
  return request<{ checkoutUrl: string; sessionId: string; purchaseId: string; discount: { code: string; discountCents: number } | null }>("/checkout", {
    method: "POST",
    body: {
      rxlabUserId: input.user.id,
      email: input.user.email || undefined,
      displayName: input.user.name || undefined,
      kind: "topup",
      topupId: input.topupId,
      couponCode: input.couponCode,
      successUrl: input.successUrl,
      cancelUrl: input.cancelUrl,
    },
  });
}

export type Invoice = {
  id: string;
  number: string | null;
  description: string | null;
  status: string;
  amountCents: number;
  currency: string;
  createdAt: string;
  hostedInvoiceUrl: string | null;
  invoicePdfUrl: string | null;
};

/**
 * Receipts, straight from Stripe.
 *
 * Cursor-paginated rather than page-numbered because it reads Stripe's list API
 * live, so there is no stable total to count pages against — `after`/`before`
 * are invoice ids and are mutually exclusive.
 */
export async function getInvoices(input: { user: AppUser; after?: string; before?: string }) {
  return request<{ invoices: Invoice[]; pagination: { hasMore: boolean; firstCursor: string | null; lastCursor: string | null } }>(
    "/invoices",
    { query: { rxlabUserId: input.user.id, after: input.after, before: input.before } },
  );
}

/** Stripe-hosted portal, for payment methods and anything the receipts list does not cover. */
export async function createBillingPortalSession(input: { user: AppUser; returnUrl: string }) {
  return request<{ url: string }>("/checkout", {
    method: "POST",
    body: {
      rxlabUserId: input.user.id,
      email: input.user.email || undefined,
      kind: "portal",
      returnUrl: input.returnUrl,
    },
  });
}

export type Reservation = {
  reservationId: string;
  amount: number;
  available: number;
  expiresAt: string | null;
  duplicate: boolean;
};

/**
 * Hold points for an in-flight operation.
 *
 * Idempotent on `idempotencyKey`: a retried request re-attaches to the existing
 * hold rather than taking a second one, so the operation key can be derived
 * from the request without tracking reservation ids across retries.
 */
export async function reserveBalance(input: {
  user: AppUser;
  amount: number;
  idempotencyKey: string;
  description?: string;
  expiresInSeconds?: number;
  metadata?: Record<string, unknown>;
}) {
  return request<Reservation>("/balances/reserve", {
    method: "POST",
    body: {
      rxlabUserId: input.user.id,
      unit: BALANCE_UNIT,
      amount: input.amount,
      idempotencyKey: input.idempotencyKey,
      description: input.description,
      expiresInSeconds: input.expiresInSeconds,
      metadata: input.metadata,
    },
  });
}

export type Settlement = {
  /** What this call charged, which is less than it asked for when the balance ran out. */
  operationSettledAmount: number;
  operationShortfallAmount: number;
  remainingReserved: number;
  balanceAfter: number;
  status: "open" | "closed" | "expired";
  duplicate: boolean;
};

/**
 * Charge part of a hold, leaving it open for the rest of the operation.
 *
 * `amount` may exceed the hold — provider costs come back from the gateway
 * after the fact and can overrun the estimate — in which case the excess is
 * charged against unreserved balance and anything still uncovered comes back as
 * `operationShortfallAmount` rather than an error. An expired hold settles the
 * same way, so a job that outlives its TTL still bills.
 */
export async function settleReservation(input: {
  reservationId: string;
  amount: number;
  idempotencyKey: string;
  description?: string;
  metadata?: Record<string, unknown>;
}) {
  return request<Settlement>(
    `/balances/reservations/${encodeURIComponent(input.reservationId)}/settle`,
    {
      method: "POST",
      body: {
        amount: input.amount,
        idempotencyKey: input.idempotencyKey,
        description: input.description,
        metadata: input.metadata,
      },
    },
  );
}

/** Drop what is left of a hold, charging nothing for it. */
export async function releaseReservation(input: { reservationId: string; idempotencyKey: string; reason?: string }) {
  return request<{ released: boolean; releasedAmount: number; balanceAfter: number; duplicate: boolean }>(
    `/balances/reservations/${encodeURIComponent(input.reservationId)}/release`,
    {
      method: "POST",
      body: { idempotencyKey: input.idempotencyKey, reason: input.reason },
    },
  );
}

export type LedgerEntry = {
  id: string;
  kind: string;
  unit: string;
  delta: number;
  balanceAfter: number;
  description: string | null;
  referenceType: string | null;
  referenceId: string | null;
  createdAt: string;
  metadata: Record<string, unknown> | null;
};

/** Every credit movement rx-subscription recorded for the metered unit. */
export async function getLedger(input: { user: AppUser; page: number; pageSize?: number }) {
  return request<{ entries: LedgerEntry[]; total: number; page: number; pageSize: number; pageCount: number }>(
    "/balances/ledger",
    {
      query: {
        rxlabUserId: input.user.id,
        unit: BALANCE_UNIT,
        page: String(input.page),
        pageSize: input.pageSize === undefined ? undefined : String(input.pageSize),
      },
    },
  );
}

/** Grow an open hold when an estimate is revised upward mid-flight. */
export async function increaseReservation(input: { reservationId: string; amount: number; idempotencyKey: string }) {
  return request<Reservation>(
    `/balances/reservations/${encodeURIComponent(input.reservationId)}/increase`,
    {
      method: "POST",
      body: { amount: input.amount, idempotencyKey: input.idempotencyKey },
    },
  );
}
