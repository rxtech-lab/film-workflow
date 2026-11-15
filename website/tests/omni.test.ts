import { afterEach, describe, expect, it, vi } from "vitest";
import { omniRequestBody } from "@/lib/ai/omni";
import { veoDurations, veoFamily, veoRules, type VeoRequest } from "@/lib/ai/veo";
vi.mock("server-only", () => ({}));
vi.mock("@/lib/models/repository", () => ({ enabledCatalogModels: async () => ["gemini-omni-1.2-flash", "gemini-omni-1.1-flash", "veo-3.1-generate-preview"].map((modelId) => ({ modelId, capability: "video", displayNameOverride: null, isDefault: false, sortOrder: 0 })) }));
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
const input: VeoRequest = { prompt: "A cinematic sunset", durationSeconds: 15, resolution: "4k", aspectRatio: "16:9", personGeneration: "allow_adult" };
const image = { mime_type: "image/png", base64: "aW1hZ2U=" };

describe("Google Omni video models", () => {
  it("discovers stable Omni versions and excludes retired previews", async () => {
    const { googleVideoMode } = await import("@/lib/ai/google-models");
    for (const id of ["gemini-omni-1.2-flash", "gemini-omni-1.1-flash"]) expect(googleVideoMode({ id, supportedGenerationMethods: ["generateContent"] })).toBe("interactions");
    for (const id of ["gemini-omni-flash-preview", "veo-3.1-generate-preview", "veo-3.1-fast-generate-preview", "veo-3.1-lite-generate-preview"]) expect(googleVideoMode({ id, supportedGenerationMethods: ["predictLongRunning"] })).toBeNull();
    expect(googleVideoMode({ id: "gemini-3.8-flash", supportedGenerationMethods: ["generateContent"] })).toBeNull();
  });
  it("offers both curated Omni versions even when Google gives them the same display name", async () => {
    vi.stubEnv("GOOGLE_GENERATIVE_AI_API_KEY", "test-key");
    vi.stubGlobal("fetch", vi.fn(async (url: string | URL) => Response.json(String(url).includes("generativelanguage.googleapis.com")
      ? { models: ["gemini-omni-1.2-flash", "gemini-omni-1.1-flash", "veo-3.1-generate-preview"].map((id) => ({ name: `models/${id}`, displayName: "Gemini Omni Flash", supportedGenerationMethods: ["generateContent", "predictLongRunning"] })) }
      : { data: [] })));
    const { resetGoogleModelCache } = await import("@/lib/ai/google-models");
    resetGoogleModelCache();
    const { modelCatalog } = await import("@/lib/ai/catalog");
    expect((await modelCatalog()).filter((entry) => entry.capability === "video").map((entry) => entry.id)).toEqual(["gemini-omni-1.2-flash", "gemini-omni-1.1-flash"]);
  });
  it("uses background interactions with URI video delivery and no Veo parameters", () => {
    const body = omniRequestBody("gemini-omni-1.2-flash", { ...input, seed: 42, generateAudio: false, negativePrompt: "Rain" });
    expect(body).toMatchObject({ model: "gemini-omni-1.2-flash", background: true, response_format: { type: "video", delivery: "uri", duration: "15s", resolution: "4k" } });
    expect(body).not.toHaveProperty("parameters");
    expect(body.input.at(-1)?.text).toContain("Rain");
  });
  it("keeps durations independent of resolution and allows six references", () => {
    expect(veoFamily("gemini-omni-1.2-flash")).toBe("omni12");
    expect(veoRules("omni12").resolutions).toContain("360p");
    expect(veoDurations("omni12", "4k", true)).toEqual([3,4,5,6,7,8,9,10,11,12,13,14,15]);
    expect(omniRequestBody("gemini-omni-1.2-flash", { ...input, referenceImages: Array(6).fill(image) }).input.filter((part) => part.type === "image")).toHaveLength(6);
  });
  it("rejects unsupported durations, mixed modes and incomplete interpolation", () => {
    expect(() => omniRequestBody("gemini-omni-1.1-flash", input)).toThrow("duration");
    expect(() => omniRequestBody("gemini-omni-1.2-flash", { ...input, firstFrame: image, lastFrame: image })).toThrow("duration");
    expect(() => omniRequestBody("gemini-omni-1.2-flash", { ...input, firstFrame: image, referenceImages: [image] })).toThrow("frames or reference");
    expect(() => omniRequestBody("gemini-omni-1.2-flash", { ...input, lastFrame: image })).toThrow("first frame");
  });
  it("prices both models at the published output token rates for each resolution", async () => {
    const { googleVideoPrice } = await import("@/lib/ai/catalog");
    expect(googleVideoPrice("gemini-omni-1.2-flash", "720p")?.nanoUsdPerUnit).toBe(69_504_000);
    expect(googleVideoPrice("gemini-omni-1.2-flash", "4k")?.nanoUsdPerUnit).toBe(208_512_000);
    expect(googleVideoPrice("gemini-omni-1.1-flash", "720p")?.nanoUsdPerUnit).toBe(101_360_000);
  });
});
