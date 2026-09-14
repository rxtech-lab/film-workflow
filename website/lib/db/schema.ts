import {
  bigint,
  boolean,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
} from "drizzle-orm/pg-core";

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

export const capabilityEnum = pgEnum("capability", ["chat", "image", "speech", "music", "transcription", "translation", "video"]);
export type Capability = (typeof capabilityEnum.enumValues)[number];

export const unitKindEnum = pgEnum("unit_kind", ["tokens", "images", "characters", "audio_seconds", "audio_minutes", "video_seconds"]);
export type UnitKind = (typeof unitKindEnum.enumValues)[number];

export const fundingScopeEnum = pgEnum("funding_scope", ["user", "platform"]);
export const usageStatusEnum = pgEnum("usage_status", ["pending", "settled", "needs_review"]);
export const platformEnum = pgEnum("platform", ["macos", "ios"]);
export const jobStatusEnum = pgEnum("job_status", ["queued", "running", "succeeded", "failed", "cancelled"]);

function timestamps() {
  return {
    createdAt: timestamp("created_at", { withTimezone: true, mode: "date" }).notNull(),
  };
}

/**
 * What each provider call actually cost.
 *
 * Balances, holds and the credit ledger belong to rx-subscription; `reservation_id`
 * points at the hold it issued. This table is the provider-side detail behind
 * those charges, which rx-subscription does not track.
 */
export const usageEvents = pgTable("usage_events", {
  id: text("id").primaryKey(),
  userId: text("user_id"),
  reservationId: text("reservation_id"),
  fundingScope: fundingScopeEnum("funding_scope").notNull(),
  provider: text("provider").notNull(),
  feature: text("feature").notNull(),
  capability: capabilityEnum("capability").notNull(),
  unitKind: unitKindEnum("unit_kind"),
  unitCount: integer("unit_count"),
  model: text("model"),
  externalId: text("external_id"),
  usage: jsonb("usage").$type<AiUsageSnapshot | null>(),
  providerCredits: integer("provider_credits"),
  costNanoUsd: bigint("cost_nano_usd", { mode: "number" }).notNull(),
  chargedPoints: integer("charged_points").notNull().default(0),
  status: usageStatusEnum("status").notNull(),
  idempotencyKey: text("idempotency_key").notNull().unique(),
  ...timestamps(),
  settledAt: timestamp("settled_at", { withTimezone: true, mode: "date" }),
}, (table) => [
  index("usage_events_user_created_idx").on(table.userId, table.createdAt),
  index("usage_events_user_capability_idx").on(table.userId, table.capability, table.createdAt),
  index("usage_events_external_idx").on(table.provider, table.externalId),
]);

export const deviceSessions = pgTable("device_sessions", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  platform: platformEnum("platform").notNull(),
  appVersion: text("app_version"),
  deviceName: text("device_name"),
  lastSeenAt: timestamp("last_seen_at", { withTimezone: true, mode: "date" }).notNull(),
  ...timestamps(),
}, (table) => [index("device_sessions_user_seen_idx").on(table.userId, table.lastSeenAt)]);

export const aiJobs = pgTable("ai_jobs", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  reservationId: text("reservation_id"),
  capability: capabilityEnum("capability").notNull(),
  status: jobStatusEnum("status").notNull(),
  requestJson: jsonb("request_json").$type<Record<string, unknown>>().notNull(),
  resultObjectKey: text("result_object_key"),
  resultMeta: jsonb("result_meta").$type<Record<string, unknown> | null>(),
  errorCode: text("error_code"),
  errorMessage: text("error_message"),
  progressPercent: integer("progress_percent").notNull().default(0),
  ...timestamps(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).notNull(),
}, (table) => [index("ai_jobs_user_created_idx").on(table.userId, table.createdAt)]);

// MARK: - Marketplace

export const marketplaceKindEnum = pgEnum("marketplace_kind", [
  "footage",
  "remotion_prompt",
  "audio",
  "sound_effect",
  "font",
  "transition",
  "effect",
  "project_template",
]);
export type MarketplaceKind = (typeof marketplaceKindEnum.enumValues)[number];

export const marketplaceItemStatusEnum = pgEnum("marketplace_item_status", ["draft", "published"]);
export type MarketplaceItemStatus = (typeof marketplaceItemStatusEnum.enumValues)[number];

/** Kind-specific facts the app needs before it downloads the content file. */
export type MarketplaceItemMetadata = {
  /** Footage, audio and preview video. */
  durationSeconds?: number;
  width?: number;
  height?: number;
  /** Fonts: the family name the text style picker should select. */
  fontFamily?: string;
  /** Effects and transitions: a summary of the CIFilter descriptor. */
  descriptor?: { filterName: string; parameterCount: number };
  /** Remotion prompts: the first lines, for the card. */
  promptExcerpt?: string;
  tags?: string[];
  preview?: { durationSeconds?: number; width?: number; height?: number; mock?: boolean };
  template?: import("@/lib/marketplace/template").TemplateSummary;
};

/**
 * How one kind presents itself in the app's marketplace sidebar. One row per
 * `marketplace_kind` value, seeded with the labels and symbols the app used to
 * compile in; the app reads them off the wire so a rename or a new icon needs
 * no release. `icon` is an SF Symbol name, and the app falls back to its own
 * default when the running OS does not have the symbol.
 */
export const marketplaceKinds = pgTable("marketplace_kinds", {
  kind: marketplaceKindEnum("kind").primaryKey(),
  label: text("label").notNull(),
  icon: text("icon").notNull(),
  /** Sidebar order, low first; ties break on label. */
  sortOrder: integer("sort_order").notNull().default(0),
  ...timestamps(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).notNull(),
});

/**
 * A shelf inside one kind ("nature" footage, "lo-fi" music). `slug` is the
 * string the app filters and groups by on the wire; `name` is what people see.
 * Admins create these from the item form; items reference them by id so a
 * rename never touches the items. `icon` is an SF Symbol name, same contract
 * as `marketplace_kinds.icon`.
 */
export const marketplaceCategories = pgTable("marketplace_categories", {
  id: text("id").primaryKey(),
  kind: marketplaceKindEnum("kind").notNull(),
  slug: text("slug").notNull(),
  name: text("name").notNull(),
  icon: text("icon").notNull().default("folder"),
  ...timestamps(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).notNull(),
}, (table) => [
  uniqueIndex("marketplace_categories_kind_slug_idx").on(table.kind, table.slug),
]);

/**
 * One purchasable asset. Preview media are public R2 objects; the content
 * object is only ever handed out as a short-lived download URL after the
 * purchase check, so its key never reaches the wire.
 */
export const marketplaceItems = pgTable("marketplace_items", {
  id: text("id").primaryKey(),
  kind: marketplaceKindEnum("kind").notNull(),
  categoryId: text("category_id").notNull().references(() => marketplaceCategories.id, { onDelete: "restrict" }),
  title: text("title").notNull(),
  description: text("description").notNull().default(""),
  pricePoints: integer("price_points").notNull().default(0),
  previewImageKey: text("preview_image_key"),
  previewVideoKey: text("preview_video_key"),
  contentKey: text("content_key"),
  contentFilename: text("content_filename"),
  contentSizeBytes: bigint("content_size_bytes", { mode: "number" }),
  contentType: text("content_type"),
  metadata: jsonb("metadata").$type<MarketplaceItemMetadata>().notNull().default({}),
  status: marketplaceItemStatusEnum("status").notNull().default("draft"),
  createdBy: text("created_by").notNull(),
  ...timestamps(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).notNull(),
  publishedAt: timestamp("published_at", { withTimezone: true, mode: "date" }),
}, (table) => [
  index("marketplace_items_status_kind_idx").on(table.status, table.kind, table.createdAt),
  index("marketplace_items_kind_category_idx").on(table.kind, table.categoryId),
]);

/**
 * A user's entitlement to one item. Free items get a row with zero points so
 * the download check is the same either way. `(user_id, item_id)` is unique,
 * which is what makes a retried purchase land on the existing row instead of
 * charging twice.
 */
export const marketplacePurchases = pgTable("marketplace_purchases", {
  id: text("id").primaryKey(),
  userId: text("user_id").notNull(),
  itemId: text("item_id").notNull().references(() => marketplaceItems.id, { onDelete: "restrict" }),
  pointsCharged: integer("points_charged").notNull(),
  reservationId: text("reservation_id"),
  idempotencyKey: text("idempotency_key").notNull().unique(),
  ...timestamps(),
}, (table) => [
  uniqueIndex("marketplace_purchases_user_item_idx").on(table.userId, table.itemId),
  index("marketplace_purchases_user_created_idx").on(table.userId, table.createdAt),
]);

export type MarketplaceKindRow = typeof marketplaceKinds.$inferSelect;
export type MarketplaceCategoryRow = typeof marketplaceCategories.$inferSelect;
export type MarketplaceItemRow = typeof marketplaceItems.$inferSelect;
export type MarketplacePurchaseRow = typeof marketplacePurchases.$inferSelect;

// MARK: - Model catalog

/**
 * The models we offer, chosen by an admin on behalf of everyone.
 *
 * Discovery finds what *could* be offered — the live gateway and Google lists in
 * `lib/ai/catalog.ts`; this table decides what *is*. A row names a model by the
 * id and capability discovery reports and nothing more: display name, provider
 * and the credit estimate are still joined from the live list at read time, so a
 * provider's price change needs no edit here, and a model that stops being
 * discoverable stops being served rather than being quoted from a stale copy.
 *
 * `display_name_override` is the one exception — null means "use the provider's
 * name", which is what almost every row wants.
 */
export const catalogModels = pgTable("catalog_models", {
  id: text("id").primaryKey(),
  /** The id discovery reports, e.g. `openai/gpt-5.4-mini` or `veo-3.1-generate-001`. */
  modelId: text("model_id").notNull(),
  capability: capabilityEnum("capability").notNull(),
  displayNameOverride: text("display_name_override"),
  enabled: boolean("enabled").notNull().default(true),
  /** The model a picker preselects for this capability. At most one row per capability, enforced by a partial unique index. */
  isDefault: boolean("is_default").notNull().default(false),
  /** Picker order within a capability, low first; ties break on display name. */
  sortOrder: integer("sort_order").notNull().default(0),
  ...timestamps(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).notNull(),
}, (table) => [
  uniqueIndex("catalog_models_capability_model_idx").on(table.capability, table.modelId),
  index("catalog_models_capability_order_idx").on(table.capability, table.sortOrder),
]);

export type CatalogModelRow = typeof catalogModels.$inferSelect;
