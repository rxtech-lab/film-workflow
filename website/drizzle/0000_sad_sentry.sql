CREATE TABLE `ai_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`reservation_id` text,
	`capability` text NOT NULL,
	`status` text NOT NULL,
	`request_json` text NOT NULL,
	`result_blob_url` text,
	`result_meta` text,
	`error_code` text,
	`error_message` text,
	`progress_percent` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `ai_jobs_user_created_idx` ON `ai_jobs` (`user_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `billing_accounts` (
	`user_id` text PRIMARY KEY NOT NULL,
	`stripe_customer_id` text,
	`balance_points` integer DEFAULT 0 NOT NULL,
	`reserved_points` integer DEFAULT 0 NOT NULL,
	`cost_remainder_nano_usd` integer DEFAULT 0 NOT NULL,
	`promotional_grant_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT "billing_accounts_reserved_nonnegative" CHECK("billing_accounts"."reserved_points" >= 0),
	CONSTRAINT "billing_accounts_remainder_nonnegative" CHECK("billing_accounts"."cost_remainder_nano_usd" >= 0)
);
--> statement-breakpoint
CREATE UNIQUE INDEX `billing_accounts_stripe_customer_id_unique` ON `billing_accounts` (`stripe_customer_id`);--> statement-breakpoint
CREATE TABLE `billing_topups` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`pack_id` text NOT NULL,
	`points` integer NOT NULL,
	`amount_cents` integer NOT NULL,
	`currency` text DEFAULT 'usd' NOT NULL,
	`status` text NOT NULL,
	`stripe_checkout_session_id` text,
	`stripe_payment_intent_id` text,
	`stripe_invoice_id` text,
	`hosted_invoice_url` text,
	`invoice_pdf_url` text,
	`refunded_amount_cents` integer DEFAULT 0 NOT NULL,
	`reversed_points` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`paid_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `billing_topups_stripe_checkout_session_id_unique` ON `billing_topups` (`stripe_checkout_session_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `billing_topups_stripe_payment_intent_id_unique` ON `billing_topups` (`stripe_payment_intent_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `billing_topups_stripe_invoice_id_unique` ON `billing_topups` (`stripe_invoice_id`);--> statement-breakpoint
CREATE INDEX `billing_topups_user_created_idx` ON `billing_topups` (`user_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `credit_reservations` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`operation_key` text NOT NULL,
	`feature` text NOT NULL,
	`scope_id` text,
	`reserved_points` integer NOT NULL,
	`settled_points` integer DEFAULT 0 NOT NULL,
	`report_fee_points` integer DEFAULT 0 NOT NULL,
	`status` text NOT NULL,
	`close_requested_success` integer,
	`close_requested_report_fee` integer DEFAULT false NOT NULL,
	`close_requested_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`closed_at` integer,
	CONSTRAINT "credit_reservations_amount_nonnegative" CHECK("credit_reservations"."reserved_points" >= 0 AND "credit_reservations"."settled_points" >= 0 AND "credit_reservations"."report_fee_points" >= 0)
);
--> statement-breakpoint
CREATE UNIQUE INDEX `credit_reservations_operation_key_unique` ON `credit_reservations` (`operation_key`);--> statement-breakpoint
CREATE INDEX `credit_reservations_user_status_idx` ON `credit_reservations` (`user_id`,`status`);--> statement-breakpoint
CREATE INDEX `credit_reservations_scope_idx` ON `credit_reservations` (`scope_id`);--> statement-breakpoint
CREATE TABLE `device_sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`platform` text NOT NULL,
	`app_version` text,
	`device_name` text,
	`last_seen_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `device_sessions_user_seen_idx` ON `device_sessions` (`user_id`,`last_seen_at`);--> statement-breakpoint
CREATE TABLE `points_ledger` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`kind` text NOT NULL,
	`points_delta` integer NOT NULL,
	`balance_after` integer NOT NULL,
	`description` text NOT NULL,
	`reference_id` text,
	`idempotency_key` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `points_ledger_idempotency_key_unique` ON `points_ledger` (`idempotency_key`);--> statement-breakpoint
CREATE INDEX `points_ledger_user_created_idx` ON `points_ledger` (`user_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `stripe_webhook_events` (
	`id` text PRIMARY KEY NOT NULL,
	`type` text NOT NULL,
	`status` text NOT NULL,
	`object_id` text,
	`failure_code` text,
	`created_at` integer NOT NULL,
	`processed_at` integer
);
--> statement-breakpoint
CREATE TABLE `usage_events` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`reservation_id` text,
	`funding_scope` text NOT NULL,
	`provider` text NOT NULL,
	`feature` text NOT NULL,
	`capability` text NOT NULL,
	`unit_kind` text,
	`unit_count` integer,
	`model` text,
	`external_id` text,
	`usage` text,
	`provider_credits` integer,
	`cost_nano_usd` integer NOT NULL,
	`charged_points` integer DEFAULT 0 NOT NULL,
	`status` text NOT NULL,
	`idempotency_key` text NOT NULL,
	`created_at` integer NOT NULL,
	`settled_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `usage_events_idempotency_key_unique` ON `usage_events` (`idempotency_key`);--> statement-breakpoint
CREATE INDEX `usage_events_user_created_idx` ON `usage_events` (`user_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `usage_events_user_capability_idx` ON `usage_events` (`user_id`,`capability`,`created_at`);--> statement-breakpoint
CREATE INDEX `usage_events_external_idx` ON `usage_events` (`provider`,`external_id`);