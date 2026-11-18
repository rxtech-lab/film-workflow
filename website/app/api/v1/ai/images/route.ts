import { z } from "zod";
import { flowcyMedia, sharedMediaModel, sharedMediaRate, mediaPayload } from "@/lib/ai/flowcy-media";
import { aiRouteError, noStoreHeaders } from "@/lib/ai/http";
import { withMeteredOperation } from "@/lib/ai/meter";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { getBalance } from "@/lib/billing/subscription";
import { pointsForNanoUsd } from "@/lib/billing/unit-pricing";
import { recordUnitUsage } from "@/lib/billing/usage";

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

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid image request" }, { status: 400, headers: noStoreHeaders() });
    const input = parsed.data;
    const model = await sharedMediaModel(request, input.model, "image");
    if (model.provider !== "google" && model.provider !== "gateway") throw new Error("MODEL_NOT_ALLOWED:image");
    const quality = input.quality === "low" || input.quality === "high" ? input.quality : "medium";
    // Gateway models are priced from the gateway's own published rate, falling
    // back to the hand-maintained table for the ones it prices by tokens. Google
    // models are priced per requested output resolution.
    const nanoUsdPerImage = sharedMediaRate(model, model.provider === "google" ? input.resolution ?? "1K" : quality);
    const billingModel = model.id;
    const reservePoints = reserveWithMargin(pointsForNanoUsd(nanoUsdPerImage * input.n, billingConfig.imageReservationPoints));
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `image:${user.id}:${crypto.randomUUID()}`;
    const { value } = await withMeteredOperation({ user, feature: `Image · ${model.displayName}`, capability: "image", operationKey, reservePoints, run: async (context) => {
      const delegated = new Request(request.url, { method: "POST", headers: { ...Object.fromEntries(request.headers), "idempotency-key": operationKey }, body: JSON.stringify(input) });
      const { images } = await mediaPayload(await flowcyMedia(delegated, "/api/v1/ai/images")) as { images: Array<{ b64_json: string; mime_type: string }> };
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
