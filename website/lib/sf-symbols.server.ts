import "server-only";

import { dirname, join } from "node:path";
import SYMBOL_MODULES from "./sf-symbol-index.json";
import { rankSymbols } from "./sf-symbols";

// The package ships one CommonJS module per symbol plus a barrel that requires
// every one of them — half a second and ~12 MB of heap to answer a name search
// that only needs the names. `sf-symbol-index.json` (see
// `scripts/generate-sf-symbol-index.ts`) carries the name list, so a request
// loads at most the single module whose vectors it is about to draw.
//
// The package's `exports` map has no subpath for those modules, so they are
// required by absolute path off the resolved entry point — resolving does not
// load the barrel. `node:module` is reached through `process.getBuiltinModule`
// rather than an import so the bundler cannot follow that require and fail on
// its computed path at build time.
const loadModule = process
  .getBuiltinModule("node:module")
  .createRequire(import.meta.url);
const SYMBOLS_DIR = dirname(loadModule.resolve("@bradleyhodges/sfsymbols"));

export interface SymbolDefinition {
  sourceName: string;
  viewBox: string;
  svgPathData: Array<{
    d: string;
    fill?: string;
    fillOpacity?: number;
  }>;
}

function isSymbolDefinition(value: unknown): value is SymbolDefinition {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<SymbolDefinition>;
  return typeof candidate.sourceName === "string" && Array.isArray(candidate.svgPathData);
}

/** Deprecated Apple names that may still be saved in the catalog. */
const LEGACY_ALIASES: Record<string, string> = {
  "wand.and.stars": "wand.and.sparkles",
  "wand.and.stars.inverse": "wand.and.sparkles.inverse",
};

const SYMBOL_MODULES_BY_NAME: Record<string, string | undefined> = SYMBOL_MODULES;

export const SF_SYMBOL_NAMES = Object.keys(SYMBOL_MODULES);

export function getSymbolDefinition(name: string): SymbolDefinition | undefined {
  const trimmed = name.trim();
  const canonical = Object.hasOwn(LEGACY_ALIASES, trimmed) ? LEGACY_ALIASES[trimmed] : trimmed;
  const moduleName = Object.hasOwn(SYMBOL_MODULES_BY_NAME, canonical) ? SYMBOL_MODULES_BY_NAME[canonical] : undefined;
  if (!moduleName) return undefined;

  // `require` memoizes, so a repeatedly drawn symbol is loaded once per process.
  const loaded = loadModule(join(SYMBOLS_DIR, `${moduleName}.js`)) as Record<string, unknown>;
  const definition = loaded[moduleName];
  return isSymbolDefinition(definition) ? definition : undefined;
}

export function searchSymbols(query: string, limit = 40): string[] {
  return rankSymbols(SF_SYMBOL_NAMES, query, limit);
}
