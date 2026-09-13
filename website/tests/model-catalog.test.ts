import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

/** Trimmed rows in the exact shape the gateway's `/v1/models` returns. */
const GATEWAY_MODELS = [
  { id: "openai/gpt-5.4-mini", name: "GPT-5.4 mini", type: "language", tags: ["tool-use"], pricing: { input: "0.00000025", output: "0.000002", input_cache_read: "0.000000025" } },
  { id: "alibaba/qwen-3-14b", name: "Qwen3-14B", type: "language", tags: ["reasoning"], pricing: { input: "0.00000008", output: "0.00000024" } },
  { id: "vendor/unpriced-chat", name: "Unpriced Chat", type: "language", pricing: {} },
  { id: "bfl/flux-pro-1.1", name: "FLUX 1.1 [pro]", type: "image", tags: ["image-generation"], pricing: { image: "0.04" } },
  { id: "xai/grok-imagine-image-2.0", name: "Grok Imagine Image 2.0", type: "image", tags: ["image-generation"], pricing: { image: "0.06", image_dimension_quality_pricing: [{ quality: "low", cost: "0.04" }, { size: "2048x2048", cost: "0.08" }] } },
  { id: "openai/gpt-image-1", name: "GPT Image 1", type: "image", tags: ["image-generation"], pricing: { input: "0.000005", output: "0.00004" } },
  { id: "openai/gpt-image-1-mini", name: "GPT Image 1 Mini", type: "image", tags: ["image-generation"], pricing: { input: "0.000002", output: "0.000008" } },
  { id: "google/imagen-4.0-generate-001", name: "Imagen 4", type: "image", tags: ["image-generation"], pricing: { image: "0.04" } },
  { id: "bfl/flux-2-flex", name: "FLUX.2 [flex]", type: "image", tags: ["image-generation"], pricing: {} },
  { id: "openai/whisper-1", name: "Whisper", type: "transcription", pricing: { input: "0.0000001" } },
  { id: "fish-audio/s1", name: "S1", type: "speech", pricing: { input: "0.000015", speech_input_character_cost: "0.000015" } },
  { id: "google/veo-3.1-generate-001", name: "Veo 3.1", type: "video", pricing: { video_duration_pricing: [{ resolution: "720p", cost_per_second: "0.4" }] } },
  { id: "openai/text-embedding-3-small", name: "Embedding 3 small", type: "embedding", pricing: { input: "0.00000002", output: "0" } },
];

function stubGatewayFetch(models: unknown[] = GATEWAY_MODELS) {
  const fetchMock = vi.fn(async () => new Response(JSON.stringify({ object: "list", data: models }), { status: 200, headers: { "content-type": "application/json" } }));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

beforeEach(() => {
  vi.resetModules();
  process.env.AI_GATEWAY_API_KEY = "test-key";
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("gateway model classification", () => {
  it("classifies models the same way the desktop client does", async () => {
    const { isChatModel, isImageModel, isTranscriptionModel } = await import("@/lib/ai/gateway-models");
    expect(isChatModel({ id: "openai/gpt-5.4-mini", type: "language" })).toBe(true);
    expect(isChatModel({ id: "bfl/flux-pro-1.1", type: "image" })).toBe(false);
    expect(isImageModel({ id: "vendor/untyped", tags: ["image-generation"] })).toBe(true);
    expect(isTranscriptionModel({ id: "openai/whisper-1", type: "transcription" })).toBe(true);
    // A declared type settles it: a TTS model is never speech-to-text.
    expect(isTranscriptionModel({ id: "vendor/whisper-tts", type: "speech" })).toBe(false);
    expect(isTranscriptionModel({ id: "vendor/gpt-4o-transcribe" })).toBe(true);
    // Untyped models fall back to "anything that is not an image or transcription".
    expect(isChatModel({ id: "vendor/mystery-model" })).toBe(true);
  });

  it("reads per-image, quality-variant and token pricing", async () => {
    const { imageNanoUsdPerUnit, tokenPricing } = await import("@/lib/ai/gateway-models");
    const grok = GATEWAY_MODELS.find((model) => model.id === "xai/grok-imagine-image-2.0")!;
    expect(imageNanoUsdPerUnit(grok)).toBe(60_000_000);
    expect(imageNanoUsdPerUnit(grok, "low")).toBe(40_000_000);
    // No row for "high", and the size-keyed row is not selectable here.
    expect(imageNanoUsdPerUnit(grok, "high")).toBe(60_000_000);
    expect(imageNanoUsdPerUnit({ id: "bfl/flux-2-flex", type: "image", pricing: {} })).toBeNull();
    expect(tokenPricing(GATEWAY_MODELS[0])).toEqual({ input: 2.5e-7, output: 2e-6, cachedInputTokens: 2.5e-8, cacheCreationInputTokens: null });
    expect(tokenPricing({ id: "vendor/unpriced-chat", pricing: {} })).toBeNull();
  });

  it("serves the last good snapshot when a refresh fails", async () => {
    const { gatewayModels } = await import("@/lib/ai/gateway-models");
    stubGatewayFetch();
    expect(await gatewayModels()).toHaveLength(GATEWAY_MODELS.length);
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("network down"); }));
    vi.useFakeTimers();
    vi.setSystemTime(Date.now() + 20 * 60 * 1000);
    try {
      expect(await gatewayModels()).toHaveLength(GATEWAY_MODELS.length);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("model catalog", () => {
  it("builds chat and image entries from the live gateway list", async () => {
    stubGatewayFetch();
    const { catalogForCapability } = await import("@/lib/ai/catalog");

    const chat = await catalogForCapability("chat");
    expect(chat.map((model) => model.id)).toEqual(["alibaba/qwen-3-14b", "openai/gpt-5.4-mini"]);
    // Chat is settled from reported tokens, so it quotes no per-unit estimate.
    expect(chat.every((model) => model.estimate === undefined)).toBe(true);

    const image = await catalogForCapability("image");
    expect(image).toContainEqual({ id: "bfl/flux-pro-1.1", provider: "gateway", displayName: "FLUX 1.1 [pro]", capability: "image", estimate: { unit: "images", pointsPerUnit: 40 } });
    // gpt-image-1 is token-priced upstream, so it keeps the hand-maintained rate.
    expect(image).toContainEqual(expect.objectContaining({ id: "openai/gpt-image-1", estimate: { unit: "images", pointsPerUnit: 42 } }));
    // Unbillable and non-routable kinds never reach the picker, and a sibling of
    // a priced model does not inherit its wildcard rate.
    expect(image.map((model) => model.id)).not.toContain("bfl/flux-2-flex");
    expect(image.map((model) => model.id)).not.toContain("openai/gpt-image-1-mini");
    expect(await catalogForCapability("speech")).toEqual([expect.objectContaining({ id: "azure-neural-tts" }), expect.objectContaining({ id: "gemini-3.1-flash-tts-preview" })]);
    expect((await catalogForCapability("transcription")).map((model) => model.id)).toEqual(["azure-fast-transcription", "gemini-2.5-flash", "whisper-1"]);
    // Veo comes from Google's own list, never the gateway: the gateway prices
    // video by a shape this app does not call.
    expect((await catalogForCapability("video")).map((model) => model.id)).not.toContain("google/veo-3.1-generate-001");
  });

  it("keeps the direct Imagen entries instead of their gateway duplicates", async () => {
    stubGatewayFetch();
    const { catalogForCapability } = await import("@/lib/ai/catalog");
    const ids = (await catalogForCapability("image")).map((model) => model.id);
    expect(ids).toContain("imagen-4.0-generate-001");
    expect(ids).not.toContain("google/imagen-4.0-generate-001");
  });

  it("prices images from the gateway and falls back to the table", async () => {
    stubGatewayFetch();
    const { imageUnitNanoUsd } = await import("@/lib/ai/catalog");
    expect(await imageUnitNanoUsd("openai/gpt-image-1", "high")).toBe(167_000_000);
    expect(await imageUnitNanoUsd("bfl/flux-2-flex")).toBeNull();
    expect(await imageUnitNanoUsd("openai/gpt-image-1-mini", "medium")).toBeNull();
    // xAI never receives the quality flag, so it is billed at its base rate.
    expect(await imageUnitNanoUsd("xai/grok-imagine-image-2.0", "low")).toBe(60_000_000);
  });

  it("only accepts models the catalog offers for that capability", async () => {
    stubGatewayFetch();
    const { requireCatalogModel } = await import("@/lib/ai/catalog");
    await expect(requireCatalogModel("openai/gpt-5.4-mini", "chat")).resolves.toMatchObject({ provider: "gateway" });
    await expect(requireCatalogModel("openai/gpt-5.4-mini", "image")).rejects.toThrow(/MODEL_NOT_ALLOWED/);
    await expect(requireCatalogModel("bfl/flux-2-flex", "image")).rejects.toThrow(/MODEL_NOT_ALLOWED/);
  });

  it("falls back to the static gateway list when the gateway is unreachable", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 500 })));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { catalogForCapability } = await import("@/lib/ai/catalog");
    expect((await catalogForCapability("chat")).map((model) => model.id)).toEqual(["google/gemini-3-flash", "openai/gpt-5.4-mini"]);
    expect((await catalogForCapability("image")).map((model) => model.id)).toContain("openai/gpt-image-1");
  });
});

describe("veo rules", () => {
  it("omits every parameter the model's family rejects", async () => {
    const { veoRequestBody } = await import("@/lib/ai/veo");
    const image = { mime_type: "image/png", base64: "AA==" };

    // Veo 3.1 takes one clip only, so numberOfVideos is never sent.
    const veo31 = veoRequestBody("veo-3.1-generate-preview", {
      prompt: "a shot", aspectRatio: "16:9", resolution: "1080p", durationSeconds: 8,
      personGeneration: "allow_adult", numberOfVideos: 2, generateAudio: true, seed: 7,
      referenceImages: [image],
    });
    expect(veo31.body.parameters).toMatchObject({ aspectRatio: "16:9", durationSeconds: 8, resolution: "1080p", generateAudio: true, seed: 7 });
    expect(veo31.body.parameters).not.toHaveProperty("numberOfVideos");
    expect(veo31.numberOfVideos).toBe(1);
    expect(veo31.body.instances[0]).toHaveProperty("referenceImages");

    // Veo 2 has no audio, no seed and no reference images, but does take a count.
    const veo2 = veoRequestBody("veo-2.0-generate-001", {
      prompt: "a shot", aspectRatio: "9:16", resolution: "4k", durationSeconds: 5,
      personGeneration: "dont_allow", numberOfVideos: 5, generateAudio: true, seed: 7,
      referenceImages: [image],
    });
    expect(veo2.body.parameters).not.toHaveProperty("generateAudio");
    expect(veo2.body.parameters).not.toHaveProperty("seed");
    // 4k is not a Veo 2 tier, so it is dropped and billed at the default.
    expect(veo2.body.parameters).not.toHaveProperty("resolution");
    expect(veo2.resolution).toBe("720p");
    expect(veo2.body.parameters.numberOfVideos).toBe(2);
    expect(veo2.body.instances[0]).not.toHaveProperty("referenceImages");

    // 3.1 Lite decides audio for itself and rejects the key.
    const lite = veoRequestBody("veo-3.1-lite-generate-preview", {
      prompt: "a shot", aspectRatio: "16:9", durationSeconds: 6,
      personGeneration: "allow_all", generateAudio: false,
    });
    expect(lite.body.parameters).not.toHaveProperty("generateAudio");
  });

  it("keys prices by the family stem, ignoring preview and build suffixes", async () => {
    const { veoPriceId } = await import("@/lib/ai/veo");
    expect(veoPriceId("veo-3.1-generate-preview")).toBe("veo-3.1-generate");
    expect(veoPriceId("veo-3.1-generate-001")).toBe("veo-3.1-generate");
    expect(veoPriceId("veo-2.0-generate")).toBe("veo-2.0-generate");
  });

  it("prices a Veo model by resolution tier and refuses an unlisted id", async () => {
    stubGatewayFetch();
    const { googleVideoPrice } = await import("@/lib/ai/catalog");
    expect(googleVideoPrice("veo-3.1-generate-001", "4k")?.nanoUsdPerUnit).toBe(600_000_000);
    // No resolution named: billed at the tier Google serves by default.
    expect(googleVideoPrice("veo-3.1-generate-001")?.nanoUsdPerUnit).toBe(400_000_000);
    // Flat-priced families fall through to their bare row.
    expect(googleVideoPrice("veo-2.0-generate-001", "720p")?.nanoUsdPerUnit).toBe(350_000_000);
    // An id the table has never heard of stays unpriced rather than inheriting a sibling's rate.
    expect(googleVideoPrice("veo-9.9-generate-001") ?? null).toBeNull();
  });
});
