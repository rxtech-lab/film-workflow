import { fileExtension, listQuery, resolutionLabel, type ListQuery, type MarketplaceKind } from "./schema";

/**
 * The public `/marketplace` pages: browsing what the app can install, without
 * signing in. Buying and installing still happen inside the app, so nothing
 * here touches purchases or the content file.
 */

/** What the storefront reads out of its URL; anything malformed is dropped rather than erroring the page. */
export type StorefrontQuery = Pick<ListQuery, "kind" | "category" | "q" | "page">;

export function parseStorefrontQuery(params: Record<string, string | string[] | undefined>): StorefrontQuery {
  const single = (value: string | string[] | undefined) => (Array.isArray(value) ? value[0] : value)?.trim() || undefined;
  const raw = { kind: single(params.kind), category: single(params.category), q: single(params.q), page: single(params.page) };
  const parsed = listQuery.safeParse(raw);
  if (parsed.success) return { kind: parsed.data.kind, category: parsed.data.category, q: parsed.data.q, page: parsed.data.page };
  // Keep whatever did parse: a bad page number should not also lose the shelf.
  const kind = listQuery.shape.kind.safeParse(raw.kind);
  const category = listQuery.shape.category.safeParse(raw.category);
  const q = listQuery.shape.q.safeParse(raw.q);
  return {
    kind: kind.success ? kind.data : undefined,
    category: kind.success && kind.data && category.success ? category.data : undefined,
    q: q.success ? q.data : undefined,
    page: 1,
  };
}

/** A storefront link. A category only means something inside its kind, so changing kind drops it. */
export function storefrontHref(query: Partial<StorefrontQuery>) {
  const params = new URLSearchParams();
  if (query.kind) params.set("kind", query.kind);
  if (query.kind && query.category) params.set("category", query.category);
  if (query.q) params.set("q", query.q);
  if (query.page && query.page > 1) params.set("page", String(query.page));
  const search = params.toString();
  return search ? `/marketplace?${search}` : "/marketplace";
}

export function priceLabel(pricePoints: number) {
  return pricePoints === 0 ? "Free" : `${pricePoints.toLocaleString("en-US")} credits`;
}

/** 7 → "0:07", 245 → "4:05", 3725 → "1:02:05". */
export function durationLabel(seconds: number | undefined) {
  if (seconds === undefined || !Number.isFinite(seconds) || seconds <= 0) return undefined;
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${secs}` : `${minutes}:${secs}`;
}

export function sizeLabel(bytes: number | null | undefined) {
  if (!bytes || bytes <= 0) return undefined;
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

const audioPreviewExtensions = ["mp3", "wav", "m4a", "aac"];

/**
 * How a preview plays on the page. Music and sound-effect items may carry an
 * audio file in the preview-video slot, so the URL's extension decides.
 */
export function previewMediaKind(kind: MarketplaceKind, previewUrl: string | null): "audio" | "video" | null {
  if (!previewUrl) return null;
  let path = previewUrl;
  try { path = new URL(previewUrl).pathname; } catch { /* a relative URL; use it as is */ }
  if (audioPreviewExtensions.includes(fileExtension(path))) return "audio";
  return kind === "audio" || kind === "sound_effect" ? "audio" : "video";
}

/** The short facts a card prints under its title: resolution, length, font family. */
export function itemFacts(kind: MarketplaceKind, metadata: { width?: number; height?: number; durationSeconds?: number; fontFamily?: string }) {
  const facts: string[] = [];
  if (kind === "footage") {
    const resolution = resolutionLabel(metadata);
    if (resolution) facts.push(resolution);
  }
  const duration = durationLabel(metadata.durationSeconds);
  if (duration) facts.push(duration);
  if (kind === "font" && metadata.fontFamily) facts.push(metadata.fontFamily);
  return facts;
}
