import { gateway } from "@ai-sdk/gateway";
import { generateImage } from "ai";
import { z } from "zod";
import { googleImagePrice, imageUnitNanoUsd, requireCatalogModel } from "@/lib/ai/catalog";
import { googleImageMode, googleModels, type GoogleImageMode } from "@/lib/ai/google-models";
import { aiRouteError, noStoreHeaders, providerError } from "@/lib/ai/http";
import { withMeteredOperation } from "@/lib/ai/meter";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { getBalance } from "@/lib/billing/subscription";
import { pointsForNanoUsd } from "@/lib/billing/unit-pricing";
import { gatewayProviderOptions, recordUnitUsage, type MeteringContext } from "@/lib/billing/usage";

export const maxDuration = 300;

const schema = z.object({
  model: z.string().min(1).max(160),
  prompt: z.string().min(1).max(20_000),
  n: z.number().int().min(1).max(4).default(1),
  aspect_ratio: z.string().max(20).optional(),
  resolution: z.string().max(20).optional(),
  size: z.string().max(30).optional(),
  quality: z.enum(["low", "medium", "high", "auto"]).optional(),
  format: z.enum(["png", "jpeg", "webp"]).optional(),
  compression: z.number().int().min(0).max(100).optional(),
  background: z.enum(["transparent", "opaque", "auto"]).optional(),
});

type ImageResult = { b64_json: string; mime_type: string };

function googleApiKey() {
  const key = process.env.GOOGLE_GENERATIVE_AI_API_KEY?.trim();
  if (!key) throw new Error("GOOGLE_AI_NOT_CONFIGURED");
  return key;
}

function googleUrl(model: string, method: string) {
  return `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:${method}`;
}

/** How AI Studio serves this model. Resolved from the live list so a new image model needs no code change. */
async function googleMethod(id: string): Promise<GoogleImageMode> {
  const model = (await googleModels().catch(() => [])).find((entry) => entry.id === id);
  const mode = model ? googleImageMode(model) : null;
  if (!mode) throw new Error(`MODEL_NOT_ALLOWED:image:${id}`);
  return mode;
}

/** Imagen: one `:predict` call returns `sampleCount` images. */
async function imagenPredict(input: z.infer<typeof schema>): Promise<ImageResult[]> {
  const response = await fetch(googleUrl(input.model, "predict"), {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": googleApiKey() },
    body: JSON.stringify({ instances: [{ prompt: input.prompt }], parameters: { sampleCount: input.n, ...(input.aspect_ratio ? { aspectRatio: input.aspect_ratio } : {}), ...(input.resolution ? { imageSize: input.resolution } : {}) } }),
    signal: AbortSignal.timeout(290_000),
  });
  if (!response.ok) await providerError(response);
  const body = await response.json() as { predictions?: Array<{ bytesBase64Encoded?: string; mimeType?: string }> };
  return (body.predictions ?? []).flatMap((image) => image.bytesBase64Encoded ? [{ b64_json: image.bytesBase64Encoded, mime_type: image.mimeType ?? "image/png" }] : []);
}

/**
 * Gemini image models emit an inline image part from an ordinary
 * `:generateContent` turn. They take no sample count, so `n` images means `n`
 * calls — and billing counts what actually comes back, not what was asked for.
 */
async function geminiImages(input: z.infer<typeof schema>): Promise<ImageResult[]> {
  const imageConfig = {
    ...(input.aspect_ratio ? { aspectRatio: input.aspect_ratio } : {}),
    ...(input.resolution ? { imageSize: input.resolution } : {}),
  };
  const once = async (): Promise<ImageResult[]> => {
    const response = await fetch(googleUrl(input.model, "generateContent"), {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": googleApiKey() },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: input.prompt }] }],
        generationConfig: { responseModalities: ["IMAGE"], ...(Object.keys(imageConfig).length ? { imageConfig } : {}) },
      }),
      signal: AbortSignal.timeout(290_000),
    });
    if (!response.ok) await providerError(response);
    const body = await response.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ inlineData?: { data?: string; mimeType?: string } }> } }>;
    };
    return (body.candidates ?? []).flatMap((candidate) => (candidate.content?.parts ?? []).flatMap((part) =>
      part.inlineData?.data ? [{ b64_json: part.inlineData.data, mime_type: part.inlineData.mimeType ?? "image/png" }] : []));
  };
  const batches = await Promise.all(Array.from({ length: input.n }, () => once()));
  return batches.flat();
}

async function googleImages(input: z.infer<typeof schema>): Promise<ImageResult[]> {
  const mode = await googleMethod(input.model);
  return mode === "predict" ? imagenPredict(input) : geminiImages(input);
}

async function gatewayImages(input: z.infer<typeof schema>, context: MeteringContext): Promise<ImageResult[]> {
  if (!process.env.AI_GATEWAY_API_KEY?.trim()) throw new Error("AI_GATEWAY_NOT_CONFIGURED");
  const size = input.size && /^\d+x\d+$/.test(input.size)
    ? input.size as `${number}x${number}`
    : undefined;
  const result = await generateImage({
    model: gateway.image(input.model),
    prompt: input.prompt,
    n: input.n,
    ...(size ? { size } : {}),
    providerOptions: {
      ...gatewayProviderOptions(context),
      openai: {
        ...(input.quality ? { quality: input.quality } : {}),
        ...(input.format ? { outputFormat: input.format } : {}),
        ...(input.compression !== undefined ? { outputCompression: input.compression } : {}),
        ...(input.background ? { background: input.background } : {}),
      },
    },
    abortSignal: AbortSignal.timeout(290_000),
    headers: {
      "http-referer": process.env.NEXT_PUBLIC_SITE_URL ?? "https://filmstudio.rxlab.app",
      "x-title": "RxFilm Studio",
    },
  });
  return result.images.map((image) => ({ b64_json: image.base64, mime_type: image.mediaType }));
}

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid image request" }, { status: 400, headers: noStoreHeaders() });
    const input = parsed.data;
    const model = await requireCatalogModel(input.model, "image");
    if (model.provider !== "google" && model.provider !== "gateway") throw new Error("MODEL_NOT_ALLOWED:image");
    const quality = input.quality === "low" || input.quality === "high" ? input.quality : "medium";
    // Gateway models are priced from the gateway's own published rate, falling
    // back to the hand-maintained table for the ones it prices by tokens. Google
    // models are priced per requested output resolution.
    const googlePrice = model.provider === "google" ? googleImagePrice(model.id, input.resolution) : null;
    const nanoUsdPerImage = model.provider === "gateway"
      ? await imageUnitNanoUsd(model.id, quality)
      : googlePrice?.nanoUsdPerUnit ?? null;
    if (nanoUsdPerImage === null) throw new Error(`PRICE_NOT_FOUND:${model.provider}:${model.id}:images`);
    const billingModel = model.provider === "gateway" ? `${model.id}:${quality}` : googlePrice?.model ?? model.id;
    const reservePoints = reserveWithMargin(pointsForNanoUsd(nanoUsdPerImage * input.n, billingConfig.imageReservationPoints));
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `image:${user.id}:${crypto.randomUUID()}`;
    const { value } = await withMeteredOperation({ user, feature: `Image · ${model.displayName}`, capability: "image", operationKey, reservePoints, run: async (context) => {
      const images = model.provider === "google" ? await googleImages(input) : await gatewayImages(input, context);
      if (!images.length) throw new Error("INVALID_PROVIDER_RESPONSE");
      const usage = await recordUnitUsage({
        context,
        provider: model.provider === "gateway" ? "vercel-ai-gateway" : "google",
        model: billingModel,
        capability: "image",
        unit: "images",
        units: images.length,
        nanoUsdPerUnit: nanoUsdPerImage,
        eventId: "images",
      });
      return { images, chargedPoints: usage?.chargedPoints ?? 0 };
    } });
    const balance = await getBalance(user);
    return Response.json({ images: value.images, usage: { chargedPoints: value.chargedPoints, availablePoints: balance.available } }, { headers: noStoreHeaders() });
  } catch (cause) { return aiRouteError(cause); }
}
