import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

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

/**
 * What each provider call actually cost.
 *
 * Balances, holds and the credit ledger belong to rx-subscription; `reservation_id`
 * points at the hold it issued. This table is the provider-side detail behind
 * those charges, which rx-subscription does not track.
 */
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
