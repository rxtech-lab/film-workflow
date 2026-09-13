/**
 * What each Veo model can actually do, and the `predictLongRunning` request
 * that expresses a generation to it.
 *
 * Ported from the desktop app's `VeoModelFamily` and `VideoGenClient.startGoogleVeo`.
 * Classified from the model id rather than an allowlist: Google renames these
 * regularly (`veo-3.1-generate-preview` → `veo-3.1-generate-001` → …), so the
 * catalog is fed from the live model list and this only *classifies* whatever
 * came back. An unrecognised id falls through to `unknown`, which offers the
 * conservative common denominator rather than nothing.
 *
 * Kept free of `server-only` and of every framework import so the rules are
 * unit-testable as plain functions.
 */

export type VeoFamily = "veo2" | "veo3" | "veo31" | "veo31Fast" | "veo31Lite" | "unknown";
export type VideoAspectRatio = "16:9" | "9:16";
export type VideoResolution = "720p" | "1080p" | "4k";
export type VideoPersonGeneration = "allow_all" | "allow_adult" | "dont_allow";
export type VideoInputImage = { mime_type: string; base64: string };

export const VIDEO_RESOLUTIONS: readonly VideoResolution[] = ["720p", "1080p", "4k"];

/** Veo renders 1080p and 4k as 8-second clips only. */
export function resolutionRequiresEightSeconds(resolution: VideoResolution) {
  return resolution !== "720p";
}

export function veoFamily(id: string): VeoFamily {
  const name = id.toLowerCase();
  if (name.includes("veo-3.1") || name.includes("veo-31")) {
    if (name.includes("lite")) return "veo31Lite";
    if (name.includes("fast")) return "veo31Fast";
    return "veo31";
  }
  if (name.includes("veo-3")) return "veo3";
  if (name.includes("veo-2")) return "veo2";
  return "unknown";
}

export type VeoRules = {
  resolutions: readonly VideoResolution[];
  /** Durations before the resolution / reference-image constraints narrow them. */
  baseDurations: readonly number[];
  maxVideos: number;
  /** Veo 3 onwards returns exactly one clip and rejects the parameter outright — it can't be sent even as `1`. */
  supportsNumberOfVideos: boolean;
  supportsSeed: boolean;
  /**
   * Native audio arrived with Veo 3, but only as a *switchable* parameter: Veo 2
   * has no audio at all and 3.1 Lite rejects the key outright (it decides for
   * itself), so neither can be sent one.
   */
  supportsAudio: boolean;
  supportsReferenceImages: boolean;
};

export function veoRules(family: VeoFamily): VeoRules {
  const resolutions: readonly VideoResolution[] = family === "veo2" ? ["720p"]
    : family === "veo31" || family === "veo31Fast" ? ["720p", "1080p", "4k"]
    : ["720p", "1080p"];
  const maxVideos = family === "veo2" ? 2 : 1;
  return {
    resolutions,
    baseDurations: family === "veo2" ? [5, 6, 8] : [4, 6, 8],
    maxVideos,
    supportsNumberOfVideos: maxVideos > 1,
    supportsSeed: family !== "veo2",
    supportsAudio: family !== "veo2" && family !== "veo31Lite",
    supportsReferenceImages: family === "veo31" || family === "veo31Fast",
  };
}

/** 1080p/4k and reference images both force an 8-second clip. */
export function veoDurations(family: VeoFamily, resolution: VideoResolution, usingReferenceImages: boolean): readonly number[] {
  if (resolutionRequiresEightSeconds(resolution) || usingReferenceImages) return [8];
  return veoRules(family).baseDurations;
}

/**
 * The pricing-table key for a live Veo id. Google suffixes ids with a release
 * marker — `-preview` while in preview, `-001`-style build numbers once GA —
 * that never changes the rate, so the row is keyed by the family stem.
 */
export function veoPriceId(id: string) {
  return id.replace(/-preview$/, "").replace(/-\d{3}$/, "");
}

export type VeoRequest = {
  prompt: string;
  negativePrompt?: string | null;
  aspectRatio: VideoAspectRatio;
  resolution?: VideoResolution | null;
  durationSeconds: number;
  personGeneration: VideoPersonGeneration;
  numberOfVideos?: number | null;
  generateAudio?: boolean | null;
  seed?: number | null;
  firstFrame?: VideoInputImage | null;
  lastFrame?: VideoInputImage | null;
  referenceImages?: VideoInputImage[] | null;
};

export type VeoRequestBody = {
  instances: [Record<string, unknown>];
  parameters: Record<string, unknown>;
};

function inlineData(image: VideoInputImage) {
  return { inlineData: { mimeType: image.mime_type, data: image.base64 } };
}

/**
 * Builds the `predictLongRunning` body, plus the values the request will
 * actually be billed at. Every parameter the selected family does not support
 * is omitted rather than sent with a default — Veo rejects unknown
 * combinations — so the returned `numberOfVideos` and `resolution` are what
 * the provider will serve, not what was asked for.
 */
export function veoRequestBody(model: string, input: VeoRequest): { body: VeoRequestBody; numberOfVideos: number; resolution: VideoResolution } {
  const family = veoFamily(model);
  const rules = veoRules(family);
  const prompt = input.prompt.trim();
  if (!prompt) throw new Error("VIDEO_PROMPT_REQUIRED");

  const instance: Record<string, unknown> = { prompt };
  if (input.firstFrame) instance.image = inlineData(input.firstFrame);
  if (input.lastFrame) instance.lastFrame = inlineData(input.lastFrame);
  if (rules.supportsReferenceImages && input.referenceImages?.length) {
    instance.referenceImages = input.referenceImages.map((image) => ({ image: inlineData(image), referenceType: "asset" }));
  }

  const parameters: Record<string, unknown> = {
    aspectRatio: input.aspectRatio,
    // Number, not a string — Veo rejects `"4"`.
    durationSeconds: input.durationSeconds,
    personGeneration: input.personGeneration,
  };
  const numberOfVideos = rules.supportsNumberOfVideos ? Math.max(1, Math.min(input.numberOfVideos ?? 1, rules.maxVideos)) : 1;
  if (rules.supportsNumberOfVideos) parameters.numberOfVideos = numberOfVideos;
  // A resolution the family cannot render is dropped, and Veo then serves its
  // default tier — which is what the billing has to reflect.
  const resolution: VideoResolution = input.resolution && rules.resolutions.includes(input.resolution) ? input.resolution : "720p";
  if (input.resolution && rules.resolutions.includes(input.resolution)) parameters.resolution = input.resolution;
  if (rules.supportsAudio && input.generateAudio !== undefined && input.generateAudio !== null) parameters.generateAudio = input.generateAudio;
  if (rules.supportsSeed && input.seed !== undefined && input.seed !== null) parameters.seed = input.seed;
  const negative = input.negativePrompt?.trim();
  if (negative) parameters.negativePrompt = negative;

  return { body: { instances: [instance], parameters }, numberOfVideos, resolution };
}
