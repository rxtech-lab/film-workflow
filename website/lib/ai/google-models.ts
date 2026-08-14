import "server-only";

/**
 * The live Google AI Studio model list.
 *
 * The gateway does not carry every Google image model, and the ones it does
 * carry it drives through a request shape that drops Imagen's aspect-ratio and
 * resolution controls. So the image catalog reads Google's own
 * `v1beta/models` — the same endpoint the desktop app's `GoogleModelsClient`
 * consumes for BYOK — and the image route calls AI Studio directly for anything
 * it returns.
 */
const MODELS_URL = "https://generativelanguage.googleapis.com/v1beta/models";
const CATALOG_TTL_MS = 15 * 60 * 1000;
const MAX_PAGES = 10;

export type GoogleModel = {
  /** Bare id with the `models/` prefix stripped — what `:predict` and the pricing table are keyed by. */
  id: string;
  displayName?: string | null;
  supportedGenerationMethods: string[];
};

/** How an image model is invoked: Imagen's `:predict`, or Gemini image's `:generateContent`. */
export type GoogleImageMode = "predict" | "generateContent";

let cache: { loadedAt: number; models: GoogleModel[] } | null = null;
let inFlight: Promise<GoogleModel[]> | null = null;

function entry(value: unknown): GoogleModel[] {
  if (typeof value !== "object" || value === null) return [];
  const raw = value as Record<string, unknown>;
  if (typeof raw.name !== "string" || !raw.name) return [];
  return [{
    id: raw.name.startsWith("models/") ? raw.name.slice("models/".length) : raw.name,
    displayName: typeof raw.displayName === "string" ? raw.displayName : null,
    supportedGenerationMethods: Array.isArray(raw.supportedGenerationMethods)
      ? raw.supportedGenerationMethods.filter((method): method is string => typeof method === "string")
      : [],
  }];
}

async function fetchModels(): Promise<GoogleModel[]> {
  const key = process.env.GOOGLE_GENERATIVE_AI_API_KEY?.trim();
  if (!key) throw new Error("GOOGLE_AI_NOT_CONFIGURED");
  const models: GoogleModel[] = [];
  let pageToken: string | null = null;
  // The list is paginated and Imagen sorts late, so a single page can miss it.
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const url = new URL(MODELS_URL);
    url.searchParams.set("pageSize", "200");
    if (pageToken) url.searchParams.set("pageToken", pageToken);
    const response = await fetch(url, { headers: { "x-goog-api-key": key }, signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new Error(`GOOGLE_MODELS_${response.status}`);
    const body = await response.json() as { models?: unknown; nextPageToken?: unknown };
    if (!Array.isArray(body.models)) throw new Error("INVALID_PROVIDER_RESPONSE");
    models.push(...body.models.flatMap(entry));
    pageToken = typeof body.nextPageToken === "string" && body.nextPageToken ? body.nextPageToken : null;
    if (!pageToken) break;
  }
  return models;
}

/**
 * The Google model list, cached for 15 minutes. A failed refresh serves the
 * last good snapshot rather than emptying the catalog.
 */
export async function googleModels(): Promise<GoogleModel[]> {
  if (cache && Date.now() - cache.loadedAt < CATALOG_TTL_MS) return cache.models;
  inFlight ??= fetchModels()
    .then((models) => {
      cache = { loadedAt: Date.now(), models };
      return models;
    })
    .catch((cause: unknown) => {
      if (cache) return cache.models;
      throw cause;
    })
    .finally(() => { inFlight = null; });
  return inFlight;
}

export function resetGoogleModelCache() {
  cache = null;
  inFlight = null;
}

/**
 * The call shape for a Google image model, or null when the model does not
 * generate images. Imagen is the only family served over plain `predict`
 * (Veo uses `predictLongRunning`); Gemini image models are ordinary
 * `generateContent` models that emit an inline image part, and announce
 * themselves by name because the list API exposes no output-modality field.
 */
export function googleImageMode(model: GoogleModel): GoogleImageMode | null {
  const id = model.id.toLowerCase();
  if (model.supportedGenerationMethods.includes("predict") && id.includes("imagen")) return "predict";
  // `nano-banana-pro-preview` is an alias for `gemini-3-pro-image` that carries
  // the marketing name instead of "image", so both stems have to match.
  if (model.supportedGenerationMethods.includes("generateContent") && (id.includes("image") || id.includes("nano-banana"))) return "generateContent";
  return null;
}
