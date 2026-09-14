/**
 * Offer everything the providers currently give us.
 *
 * The catalog is a strict allowlist, so between `db:migrate` and this script no
 * model is offered and every AI route refuses every request. Run the two as one
 * step. Re-running is safe: existing rows are left alone, so an admin's renames,
 * ordering and disables survive a top-up.
 *
 * Run it through `bun run db:seed-models`: the modules it pulls in are marked
 * `server-only`, which throws unless bun resolves with the `react-server`
 * condition the way Next does.
 *
 * Needs the same provider credentials the app runs with — `AI_GATEWAY_API_KEY`
 * and `GOOGLE_GENERATIVE_AI_API_KEY` — or the list it seeds from will be short.
 */
import { discoveredCatalog } from "@/lib/ai/catalog";
import { insertCatalogModels, listCatalogModels } from "@/lib/models/repository";

async function main() {
  const discovered = await discoveredCatalog();
  if (discovered.length === 0) throw new Error("Discovered nothing — check AI_GATEWAY_API_KEY and GOOGLE_GENERATIVE_AI_API_KEY.");

  const existing = new Set((await listCatalogModels()).map((row) => `${row.capability}:${row.modelId}`));
  const rows = discovered
    .filter((model) => !existing.has(`${model.capability}:${model.id}`))
    .map((model) => ({ modelId: model.id, capability: model.capability }));

  const inserted = await insertCatalogModels(rows);
  console.info(`Discovered ${discovered.length}, already offered ${existing.size}, added ${inserted.length}.`);
}

main().catch((cause) => {
  console.error(cause instanceof Error ? cause.message : cause);
  process.exit(1);
});
