-- Offer the current Gemini API video models without overriding admin choices.
-- Live discovery still gates availability for the configured Google account.
INSERT INTO "catalog_models" ("id", "model_id", "capability", "sort_order", "created_at", "updated_at")
VALUES
  ('google-omni-12-video', 'gemini-omni-1.2-flash', 'video', 0, now(), now()),
  ('google-omni-11-video', 'gemini-omni-1.1-flash', 'video', 1, now(), now())
ON CONFLICT ("capability", "model_id") DO NOTHING;
