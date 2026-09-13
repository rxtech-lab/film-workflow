CREATE TABLE "marketplace_kinds" (
	"kind" "marketplace_kind" PRIMARY KEY NOT NULL,
	"label" text NOT NULL,
	"icon" text NOT NULL,
	"sort_order" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "marketplace_categories" ADD COLUMN "icon" text DEFAULT 'folder' NOT NULL;
--> statement-breakpoint
-- Seeded with the labels and SF Symbols the app used to compile in, so the
-- sidebar looks the same the moment it starts reading them off the wire.
-- (Hand-edited: drizzle-kit only emits the DDL.)
INSERT INTO "marketplace_kinds" ("kind", "label", "icon", "sort_order", "created_at", "updated_at") VALUES
	('footage', 'Footage', 'film', 0, now(), now()),
	('remotion_prompt', 'Remotion Prompts', 'text.quote', 1, now(), now()),
	('audio', 'Music', 'music.note', 2, now(), now()),
	('sound_effect', 'Sound Effects', 'waveform', 3, now(), now()),
	('font', 'Fonts', 'textformat', 4, now(), now()),
	('transition', 'Transitions', 'arrow.left.arrow.right.square', 5, now(), now()),
	('effect', 'Effects', 'wand.and.stars', 6, now(), now()),
	('project_template', 'Project Templates', 'rectangle.stack.badge.play', 7, now(), now())
ON CONFLICT ("kind") DO NOTHING;
