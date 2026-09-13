CREATE TABLE "marketplace_categories" (
	"id" text PRIMARY KEY NOT NULL,
	"kind" "marketplace_kind" NOT NULL,
	"slug" text NOT NULL,
	"name" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "marketplace_categories_kind_slug_idx" ON "marketplace_categories" USING btree ("kind","slug");--> statement-breakpoint
DROP INDEX "marketplace_items_kind_category_idx";--> statement-breakpoint
-- Added nullable, backfilled from the old free-text column, then locked down.
-- (Hand-edited: drizzle-kit emits NOT NULL directly, which fails on existing rows.)
ALTER TABLE "marketplace_items" ADD COLUMN "category_id" text;--> statement-breakpoint
-- One category per (kind, existing category string). The string was never
-- constrained, so it becomes the display name as-is and a lowercased,
-- dash-joined copy becomes the slug the app filters on.
INSERT INTO "marketplace_categories" ("id", "kind", "slug", "name", "created_at", "updated_at")
SELECT gen_random_uuid()::text,
       "kind",
       COALESCE(NULLIF(trim(BOTH '-' FROM regexp_replace(lower("category"), '[^a-z0-9]+', '-', 'g')), ''), 'general'),
       "category",
       now(),
       now()
FROM (SELECT DISTINCT "kind", "category" FROM "marketplace_items") AS existing
ON CONFLICT ("kind", "slug") DO NOTHING;--> statement-breakpoint
UPDATE "marketplace_items" AS items
SET "category_id" = categories."id"
FROM "marketplace_categories" AS categories
WHERE categories."kind" = items."kind"
  AND categories."slug" = COALESCE(NULLIF(trim(BOTH '-' FROM regexp_replace(lower(items."category"), '[^a-z0-9]+', '-', 'g')), ''), 'general');--> statement-breakpoint
ALTER TABLE "marketplace_items" ALTER COLUMN "category_id" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "marketplace_items" ADD CONSTRAINT "marketplace_items_category_id_marketplace_categories_id_fk" FOREIGN KEY ("category_id") REFERENCES "public"."marketplace_categories"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "marketplace_items_kind_category_idx" ON "marketplace_items" USING btree ("kind","category_id");
