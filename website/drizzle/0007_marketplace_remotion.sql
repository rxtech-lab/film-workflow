-- Retires `remotion_prompt` and introduces `remotion`, whose content is a zip of
-- a whole Remotion project rather than a prompt file.
--
-- Destructive, and deliberately loud about it: the kind is removed outright, so
-- the guard below aborts the whole transaction rather than letting the casts
-- further down fail with "invalid input value for enum". (Hand-edited:
-- drizzle-kit emits only the type swap.)
DO $$
DECLARE stuck int;
BEGIN
  SELECT count(*) INTO stuck FROM "marketplace_items" WHERE "kind"::text = 'remotion_prompt';
  IF stuck > 0 THEN
    RAISE EXCEPTION
      'Refusing to retire marketplace_kind.remotion_prompt: % marketplace_items row(s) still use it. Re-kind or delete them first (an item with purchases cannot be deleted, so unpublish and re-kind that one), then re-run.',
      stuck;
  END IF;
END $$;--> statement-breakpoint
-- Safe now that no item references them: `marketplace_items.category_id` is
-- ON DELETE restrict, so the guard above is what makes this delete legal.
DELETE FROM "marketplace_categories" WHERE "kind"::text = 'remotion_prompt';--> statement-breakpoint
DELETE FROM "marketplace_kinds" WHERE "kind"::text = 'remotion_prompt';--> statement-breakpoint
ALTER TABLE "marketplace_categories" ALTER COLUMN "kind" SET DATA TYPE text;--> statement-breakpoint
ALTER TABLE "marketplace_items" ALTER COLUMN "kind" SET DATA TYPE text;--> statement-breakpoint
ALTER TABLE "marketplace_kinds" ALTER COLUMN "kind" SET DATA TYPE text;--> statement-breakpoint
DROP TYPE "public"."marketplace_kind";--> statement-breakpoint
CREATE TYPE "public"."marketplace_kind" AS ENUM('footage', 'remotion', 'audio', 'sound_effect', 'font', 'transition', 'effect', 'project_template');--> statement-breakpoint
ALTER TABLE "marketplace_categories" ALTER COLUMN "kind" SET DATA TYPE "public"."marketplace_kind" USING "kind"::"public"."marketplace_kind";--> statement-breakpoint
ALTER TABLE "marketplace_items" ALTER COLUMN "kind" SET DATA TYPE "public"."marketplace_kind" USING "kind"::"public"."marketplace_kind";--> statement-breakpoint
ALTER TABLE "marketplace_kinds" ALTER COLUMN "kind" SET DATA TYPE "public"."marketplace_kind" USING "kind"::"public"."marketplace_kind";--> statement-breakpoint
-- The sidebar row for the new kind, matching `marketplaceKindDefaults`.
INSERT INTO "marketplace_kinds" ("kind", "label", "icon", "sort_order", "created_at", "updated_at") VALUES
	('remotion', 'Remotion Compositions', 'cube.transparent', 1, now(), now())
ON CONFLICT ("kind") DO NOTHING;--> statement-breakpoint
-- Every footage item predates the image media type, and MP4/MOV were the only
-- content types footage ever accepted, so this is correct by construction.
UPDATE "marketplace_items"
SET "metadata" = "metadata" || '{"mediaType":"video"}'::jsonb
WHERE "kind" = 'footage' AND "metadata"->>'mediaType' IS NULL;--> statement-breakpoint
-- Serves the per-media-type counts the sidebar asks for on every load, which
-- group on a jsonb field the existing (status, kind, created_at) index cannot.
CREATE INDEX IF NOT EXISTS "marketplace_items_media_type_idx"
  ON "marketplace_items" ("status", "kind", (("metadata"->>'mediaType')));
