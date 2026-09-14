-- Per-row text in the languages the base columns are not written in, keyed by
-- locale then field: `{"zh-Hans": {"title": "…", "description": "…"}}`. A row
-- with no entry for the requested locale reads through to its base column, so
-- this column being empty is the same as it was before it existed.
ALTER TABLE "marketplace_categories" ADD COLUMN "translations" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "marketplace_items" ADD COLUMN "translations" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "marketplace_kinds" ADD COLUMN "translations" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
-- The sidebar's top level, translated to match `lib/i18n/messages.ts`, so a
-- Simplified Chinese app sees Chinese kinds the moment it asks for them.
-- Only rows an admin has not renamed are touched: a custom label is theirs, and
-- guessing a translation for it would overwrite intent. (Hand-edited:
-- drizzle-kit emits only the three ALTERs above.)
UPDATE "marketplace_kinds" SET "translations" = jsonb_build_object('zh-Hans', jsonb_build_object('label', v."label"))
FROM (VALUES
	('footage', '素材', 'Footage'),
	('remotion', 'Remotion 合成', 'Remotion Compositions'),
	('audio', '音乐', 'Music'),
	('sound_effect', '音效', 'Sound Effects'),
	('font', '字体', 'Fonts'),
	('transition', '转场', 'Transitions'),
	('effect', '特效', 'Effects'),
	('project_template', '项目模板', 'Project Templates')
) AS v("kind", "label", "seeded_label")
WHERE "marketplace_kinds"."kind"::text = v."kind"
	AND "marketplace_kinds"."label" = v."seeded_label"
	AND "marketplace_kinds"."translations" = '{}'::jsonb;
