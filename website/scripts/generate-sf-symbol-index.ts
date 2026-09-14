/**
 * Build `lib/sf-symbol-index.json`: a map from every SF Symbol name to
 * the module file inside `@bradleyhodges/sfsymbols` that holds its vectors.
 *
 * The package ships one CommonJS module per symbol plus a barrel that requires
 * all 7,400 of them. Loading that barrel costs roughly half a second and ~12 MB
 * of heap, which the `/api/sf-symbols` route used to pay on its first request
 * just to answer a name search. With this index the route reads names from a
 * single JSON file and requires only the one module a rendered symbol needs.
 *
 * Re-run after bumping `@bradleyhodges/sfsymbols` and commit the output — the
 * build does not regenerate it. `sf-symbols.test.ts` fails if it drifts.
 *
 *   bun run scripts/generate-sf-symbol-index.ts
 */
import { createRequire } from "node:module";
import { writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);

interface SymbolModule {
  iconName: string;
  sourceName: string;
  svgPathData: unknown[];
}

function isSymbolModule(value: unknown): value is SymbolModule {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<SymbolModule>;
  return (
    typeof candidate.iconName === "string" &&
    typeof candidate.sourceName === "string" &&
    Array.isArray(candidate.svgPathData)
  );
}

/** `{ "star.fill": "sfStarFill", ... }`, sorted by symbol name. */
export function buildSymbolIndex(): Record<string, string> {
  const symbolExports = require("@bradleyhodges/sfsymbols") as Record<string, unknown>;

  const modulesByName = new Map<string, string>();
  for (const value of Object.values(symbolExports)) {
    // First definition wins, matching how the package's own barrel resolves
    // the handful of names that appear under more than one export.
    if (isSymbolModule(value) && !modulesByName.has(value.sourceName)) {
      modulesByName.set(value.sourceName, value.iconName);
    }
  }

  return Object.fromEntries([...modulesByName].sort(([a], [b]) => (a < b ? -1 : 1)));
}

const OUTPUT = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "lib",
  "sf-symbol-index.json",
);

// `sf-symbols.test.ts` imports `buildSymbolIndex` to prove the checked-in file
// still matches the installed package, so only a direct run rewrites it.
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const index = buildSymbolIndex();
  // One symbol per line so a package bump reviews as a readable diff.
  await writeFile(OUTPUT, `${JSON.stringify(index, null, 1)}\n`, "utf8");
  console.log(`Wrote ${Object.keys(index).length} symbols to ${OUTPUT}`);
}
