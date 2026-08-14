import { sql } from "drizzle-orm";
import { check, index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

export type AiUsageSnapshot = {
  inputTokens?: number;
  inputTokenDetails?: {
    noCacheTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
  };
  outputTokens?: number;
  outputTokenDetails?: {
    textTokens?: number;
    reasoningTokens?: number;
  };
  totalTokens?: number;
};

export type Capability =
  | "chat"
  | "image"
  | "speech"
  | "music"
  | "transcription"
  | "translation";

export type UnitKind =
  | "tokens"
  | "images"
  | "characters"
  | "audio_seconds"
  | "audio_minutes";

export const billingAccounts = sqliteTable("billing_accounts", {
  userId: text("user_id").primaryKey(),
  stripeCustomerId: text("stripe_customer_id").unique(),
  balancePoints: integer("balance_points").notNull().default(0),
  reservedPoints: integer("reserved_points").notNull().default(0),
  costRemainderNanoUsd: integer("cost_remainder_nano_usd").notNull().default(0),
  promotionalGrantAt: integer("promotional_grant_at", { mode: "timestamp_ms" }),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [
  check("billing_accounts_reserved_nonnegative", sql`${table.reservedPoints} >= 0`),
  check("billing_accounts_remainder_nonnegative", sql`${table.costRemainderNanoUsd} >= 0`),
]);

export const creditReservations = sqliteTable("credit_reservations", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  operationKey: text("operation_key").notNull().unique(),
  feature: text("feature").notNull(),
  scopeId: text("scope_id"),
  reservedPoints: integer("reserved_points").notNull(),
  settledPoints: integer("settled_points").notNull().default(0),
  reportFeePoints: integer("report_fee_points").notNull().default(0),
  status: text("status", { enum: ["open", "settled", "released", "needs_review"] }).notNull(),
  closeRequestedSuccess: integer("close_requested_success", { mode: "boolean" }),
  closeRequestedReportFee: integer("close_requested_report_fee", { mode: "boolean" }).notNull().default(false),
  closeRequestedAt: integer("close_requested_at", { mode: "timestamp_ms" }),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
  closedAt: integer("closed_at", { mode: "timestamp_ms" }),
}, (table) => [
  index("credit_reservations_user_status_idx").on(table.userId, table.status),
  index("credit_reservations_scope_idx").on(table.scopeId),
  check("credit_reservations_amount_nonnegative", sql`${table.reservedPoints} >= 0 AND ${table.settledPoints} >= 0 AND ${table.reportFeePoints} >= 0`),
]);

export const pointsLedger = sqliteTable("points_ledger", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  kind: text("kind", { enum: ["promotional_grant", "top_up", "provider_usage", "report_fee", "refund", "dispute", "dispute_reversal", "adjustment"] }).notNull(),
  pointsDelta: integer("points_delta").notNull(),
  balanceAfter: integer("balance_after").notNull(),
  description: text("description").notNull(),
  referenceId: text("reference_id"),
  idempotencyKey: text("idempotency_key").notNull().unique(),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("points_ledger_user_created_idx").on(table.userId, table.createdAt)]);

export const usageEvents = sqliteTable("usage_events", {
  id: text("id").primaryKey(),
  userId: text("user_id"),
  reservationId: text("reservation_id"),
  fundingScope: text("funding_scope", { enum: ["user", "platform"] }).notNull(),
  provider: text("provider").notNull(),
  feature: text("feature").notNull(),
  capability: text("capability", { enum: ["chat", "image", "speech", "music", "transcription", "translation"] }).notNull(),
  unitKind: text("unit_kind", { enum: ["tokens", "images", "characters", "audio_seconds", "audio_minutes"] }),
  unitCount: integer("unit_count"),
  model: text("model"),
  externalId: text("external_id"),
  usage: text("usage", { mode: "json" }).$type<AiUsageSnapshot | null>(),
  providerCredits: integer("provider_credits"),
  costNanoUsd: integer("cost_nano_usd").notNull(),
  chargedPoints: integer("charged_points").notNull().default(0),
  status: text("status", { enum: ["pending", "settled", "needs_review"] }).notNull(),
  idempotencyKey: text("idempotency_key").notNull().unique(),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  settledAt: integer("settled_at", { mode: "timestamp_ms" }),
}, (table) => [
  index("usage_events_user_created_idx").on(table.userId, table.createdAt),
  index("usage_events_user_capability_idx").on(table.userId, table.capability, table.createdAt),
  index("usage_events_external_idx").on(table.provider, table.externalId),
]);

export const billingTopups = sqliteTable("billing_topups", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  packId: text("pack_id").notNull(),
  points: integer("points").notNull(),
  amountCents: integer("amount_cents").notNull(),
  currency: text("currency").notNull().default("usd"),
  status: text("status", { enum: ["pending", "paid", "failed", "refunded", "disputed"] }).notNull(),
  stripeCheckoutSessionId: text("stripe_checkout_session_id").unique(),
  stripePaymentIntentId: text("stripe_payment_intent_id").unique(),
  stripeInvoiceId: text("stripe_invoice_id").unique(),
  hostedInvoiceUrl: text("hosted_invoice_url"),
  invoicePdfUrl: text("invoice_pdf_url"),
  refundedAmountCents: integer("refunded_amount_cents").notNull().default(0),
  reversedPoints: integer("reversed_points").notNull().default(0),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
  paidAt: integer("paid_at", { mode: "timestamp_ms" }),
}, (table) => [index("billing_topups_user_created_idx").on(table.userId, table.createdAt)]);

export const stripeWebhookEvents = sqliteTable("stripe_webhook_events", {
  id: text("id").primaryKey(),
  type: text("type").notNull(),
  status: text("status", { enum: ["processing", "processed", "ignored", "failed"] }).notNull(),
  objectId: text("object_id"),
  failureCode: text("failure_code"),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  processedAt: integer("processed_at", { mode: "timestamp_ms" }),
});

export const deviceSessions = sqliteTable("device_sessions", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  platform: text("platform", { enum: ["macos", "ios"] }).notNull(),
  appVersion: text("app_version"),
  deviceName: text("device_name"),
  lastSeenAt: integer("last_seen_at", { mode: "timestamp_ms" }).notNull(),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("device_sessions_user_seen_idx").on(table.userId, table.lastSeenAt)]);

export const aiJobs = sqliteTable("ai_jobs", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  reservationId: text("reservation_id"),
  capability: text("capability", { enum: ["chat", "image", "speech", "music", "transcription", "translation"] }).notNull(),
  status: text("status", { enum: ["queued", "running", "succeeded", "failed", "cancelled"] }).notNull(),
  requestJson: text("request_json", { mode: "json" }).$type<Record<string, unknown>>().notNull(),
  // Keep the original SQL column name for migration compatibility; it stores an
  // S3 object key now, never a provider-specific URL.
  resultObjectKey: text("result_blob_url"),
  resultMeta: text("result_meta", { mode: "json" }).$type<Record<string, unknown> | null>(),
  errorCode: text("error_code"),
  errorMessage: text("error_message"),
  progressPercent: integer("progress_percent").notNull().default(0),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("ai_jobs_user_created_idx").on(table.userId, table.createdAt)]);
