CREATE TABLE "catalog_models" (
	"id" text PRIMARY KEY NOT NULL,
	"model_id" text NOT NULL,
	"capability" "capability" NOT NULL,
	"display_name_override" text,
	"enabled" boolean DEFAULT true NOT NULL,
	"is_default" boolean DEFAULT false NOT NULL,
	"sort_order" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "catalog_models_capability_model_idx" ON "catalog_models" USING btree ("capability","model_id");--> statement-breakpoint
CREATE INDEX "catalog_models_capability_order_idx" ON "catalog_models" USING btree ("capability","sort_order");--> statement-breakpoint
-- At most one default per capability. Drizzle cannot express a partial unique
-- index, so this is hand-added; `setDefaultCatalogModel` clears the old default
-- and sets the new one in one batch, and this index is the backstop that keeps a
-- bug or a concurrent edit from leaving two.
CREATE UNIQUE INDEX "catalog_models_one_default_idx" ON "catalog_models" ("capability") WHERE "is_default";
