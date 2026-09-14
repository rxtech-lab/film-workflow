/**
 * Client-safe helpers for the SF Symbols combobox. The full vector catalog is
 * intentionally kept in `sf-symbols.server.ts`; importing it here would ship
 * thousands of SVG definitions in the browser bundle.
 */

/**
 * Rank symbol names against a query: exact match, then names starting with the
 * query, then names containing it, then names containing every word. Spaces
 * and underscores in the query are treated as dots so "lock open" finds
 * `lock.open.fill`.
 */
export function rankSymbols(symbolNames: readonly string[], query: string, limit = 40): string[] {
  const normalized = query.trim().toLowerCase().replace(/[\s_]+/g, ".");
  if (!normalized) return symbolNames.slice(0, limit);
  const words = normalized.split(".").filter(Boolean);

  const buckets: string[][] = [[], [], [], []];
  for (const name of symbolNames) {
    if (name === normalized) buckets[0].push(name);
    else if (name.startsWith(normalized)) buckets[1].push(name);
    else if (name.includes(normalized)) buckets[2].push(name);
    else if (words.length > 1 && words.every((word) => name.includes(word))) buckets[3].push(name);
  }
  return buckets.flat().slice(0, limit);
}

/** A handful of symbols worth suggesting before the user has typed anything. */
export const SUGGESTED_SYMBOLS = [
  "folder",
  "tag",
  "film",
  "music.note",
  "waveform",
  "textformat",
  "checkmark.circle.fill",
  "star.fill",
  "sparkles",
  "bolt.fill",
  "heart.fill",
  "lock.open.fill",
  "cloud.fill",
  "infinity",
  "person.2.fill",
  "gift.fill",
  "shield.fill",
  "checkmark.seal.fill",
  "paperplane.fill",
  "wand.and.sparkles",
  "headphones",
  "photo.on.rectangle",
] as const;
