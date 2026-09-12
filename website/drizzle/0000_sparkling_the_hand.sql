CREATE TYPE "public"."capability" AS ENUM('chat', 'image', 'speech', 'music', 'transcription', 'translation');--> statement-breakpoint
CREATE TYPE "public"."funding_scope" AS ENUM('user', 'platform');--> statement-breakpoint
CREATE TYPE "public"."job_status" AS ENUM('queued', 'running', 'succeeded', 'failed', 'cancelled');--> statement-breakpoint
CREATE TYPE "public"."marketplace_item_status" AS ENUM('draft', 'published');--> statement-breakpoint
CREATE TYPE "public"."marketplace_kind" AS ENUM('footage', 'remotion_prompt', 'audio', 'sound_effect', 'font', 'transition', 'effect');--> statement-breakpoint
CREATE TYPE "public"."platform" AS ENUM('macos', 'ios');--> statement-breakpoint
CREATE TYPE "public"."unit_kind" AS ENUM('tokens', 'images', 'characters', 'audio_seconds', 'audio_minutes');--> statement-breakpoint
CREATE TYPE "public"."usage_status" AS ENUM('pending', 'settled', 'needs_review');--> statement-breakpoint
CREATE TABLE "ai_jobs" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"reservation_id" text,
	"capability" "capability" NOT NULL,
	"status" "job_status" NOT NULL,
	"request_json" jsonb NOT NULL,
	"result_object_key" text,
	"result_meta" jsonb,
	"error_code" text,
	"error_message" text,
	"progress_percent" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "device_sessions" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"platform" "platform" NOT NULL,
	"app_version" text,
	"device_name" text,
	"last_seen_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "marketplace_items" (
	"id" text PRIMARY KEY NOT NULL,
	"kind" "marketplace_kind" NOT NULL,
	"category" text DEFAULT 'general' NOT NULL,
	"title" text NOT NULL,
	"description" text DEFAULT '' NOT NULL,
	"price_points" integer DEFAULT 0 NOT NULL,
	"preview_image_key" text,
	"preview_video_key" text,
	"content_key" text,
	"content_filename" text,
	"content_size_bytes" bigint,
	"content_type" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"status" "marketplace_item_status" DEFAULT 'draft' NOT NULL,
	"created_by" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	"published_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "marketplace_purchases" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"item_id" text NOT NULL,
	"points_charged" integer NOT NULL,
	"reservation_id" text,
	"idempotency_key" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	CONSTRAINT "marketplace_purchases_idempotency_key_unique" UNIQUE("idempotency_key")
);
--> statement-breakpoint
CREATE TABLE "usage_events" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text,
	"reservation_id" text,
	"funding_scope" "funding_scope" NOT NULL,
	"provider" text NOT NULL,
	"feature" text NOT NULL,
	"capability" "capability" NOT NULL,
	"unit_kind" "unit_kind",
	"unit_count" integer,
	"model" text,
	"external_id" text,
	"usage" jsonb,
	"provider_credits" integer,
	"cost_nano_usd" bigint NOT NULL,
	"charged_points" integer DEFAULT 0 NOT NULL,
	"status" "usage_status" NOT NULL,
	"idempotency_key" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"settled_at" timestamp with time zone,
	CONSTRAINT "usage_events_idempotency_key_unique" UNIQUE("idempotency_key")
);
--> statement-breakpoint
ALTER TABLE "marketplace_purchases" ADD CONSTRAINT "marketplace_purchases_item_id_marketplace_items_id_fk" FOREIGN KEY ("item_id") REFERENCES "public"."marketplace_items"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "ai_jobs_user_created_idx" ON "ai_jobs" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "device_sessions_user_seen_idx" ON "device_sessions" USING btree ("user_id","last_seen_at");--> statement-breakpoint
CREATE INDEX "marketplace_items_status_kind_idx" ON "marketplace_items" USING btree ("status","kind","created_at");--> statement-breakpoint
CREATE INDEX "marketplace_items_kind_category_idx" ON "marketplace_items" USING btree ("kind","category");--> statement-breakpoint
CREATE UNIQUE INDEX "marketplace_purchases_user_item_idx" ON "marketplace_purchases" USING btree ("user_id","item_id");--> statement-breakpoint
CREATE INDEX "marketplace_purchases_user_created_idx" ON "marketplace_purchases" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "usage_events_user_created_idx" ON "usage_events" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "usage_events_user_capability_idx" ON "usage_events" USING btree ("user_id","capability","created_at");--> statement-breakpoint
CREATE INDEX "usage_events_external_idx" ON "usage_events" USING btree ("provider","external_id");