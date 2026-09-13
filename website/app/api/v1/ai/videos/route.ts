import { z } from "zod";
import { googleVideoPrice, requireCatalogModel } from "@/lib/ai/catalog";
import { googleApiKey } from "@/lib/ai/google-models";
import { aiRouteError, noStoreHeaders, providerError } from "@/lib/ai/http";
import { veoRequestBody } from "@/lib/ai/veo";
import { VIDEO_FEATURE } from "@/lib/ai/video-jobs";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { closeReservation, reserveCredits } from "@/lib/billing/repository";
import { estimateReservationPoints } from "@/lib/billing/unit-pricing";
import { db } from "@/lib/db";
import { aiJobs } from "@/lib/db/schema";

const image = z.object({ mime_type: z.enum(["image/png", "image/jpeg", "image/webp", "image/heic"]), base64: z.string().min(1).max(8_000_000) });

const schema = z.object({
  model: z.string().min(1).max(160),
  prompt: z.string().min(1).max(20_000),
  negative_prompt: z.string().max(20_000).optional(),
  aspect_ratio: z.enum(["16:9", "9:16"]),
  resolution: z.enum(["720p", "1080p", "4k"]).optional(),
  duration_seconds: z.number().int().min(4).max(8),
  person_generation: z.enum(["allow_all", "allow_adult", "dont_allow"]),
  number_of_videos: z.number().int().min(1).max(2).optional(),
  generate_audio: z.boolean().optional(),
  seed: z.number().int().optional(),
  first_frame: image.optional(),
  last_frame: image.optional(),
  reference_images: z.array(image).max(3).optional(),
});

/**
 * Submits a Veo generation and returns as soon as Google accepts it. Nothing
 * waits here: the operation name is stored on the job and `GET /jobs/:id`
 * polls Google and finalizes the clip on demand, so a request that outlives
 * this function — Veo runs for minutes — loses nothing.
 */
export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid video request" }, { status: 400, headers: noStoreHeaders() });
    const input = parsed.data;
    const model = await requireCatalogModel(input.model, "video");
    if (model.provider !== "google") throw new Error("MODEL_NOT_ALLOWED:video");
    const { body, numberOfVideos, resolution } = veoRequestBody(model.id, {
      prompt: input.prompt,
      negativePrompt: input.negative_prompt,
      aspectRatio: input.aspect_ratio,
      resolution: input.resolution,
      durationSeconds: input.duration_seconds,
      personGeneration: input.person_generation,
      numberOfVideos: input.number_of_videos,
      generateAudio: input.generate_audio,
      seed: input.seed,
      firstFrame: input.first_frame,
      lastFrame: input.last_frame,
      referenceImages: input.reference_images,
    });
    const price = googleVideoPrice(model.id, resolution);
    if (!price) throw new Error(`PRICE_NOT_FOUND:google:${model.id}:video_seconds`);
    const key = googleApiKey();

    const jobId = crypto.randomUUID();
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `video:${user.id}:${jobId}`;
    const reservePoints = reserveWithMargin(estimateReservationPoints({ provider: "google", model: price.model, unit: "video_seconds", units: input.duration_seconds * numberOfVideos, floorPoints: billingConfig.videoReservationPoints }));
    const reservation = await reserveCredits({ user, operationKey, feature: VIDEO_FEATURE, points: reservePoints, scopeId: jobId });

    let operationName: string;
    try {
      const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model.id)}:predictLongRunning`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(120_000),
      });
      if (!response.ok) await providerError(response);
      const accepted = await response.json() as { name?: unknown };
      if (typeof accepted.name !== "string" || !accepted.name) throw new Error("INVALID_PROVIDER_RESPONSE");
      operationName = accepted.name;
    } catch (cause) {
      if (reservation) await closeReservation({ reservationId: reservation.id, userId: user.id, success: false }).catch(() => null);
      throw cause;
    }

    const now = new Date();
    await db.insert(aiJobs).values({
      id: jobId,
      userId: user.id,
      reservationId: reservation?.id ?? null,
      capability: "video",
      status: "running",
      requestJson: { operationName, model: model.id, priceModel: price.model, durationSeconds: input.duration_seconds, numberOfVideos, prompt: input.prompt, generateAudio: input.generate_audio ?? null },
      progressPercent: 5,
      createdAt: now,
      updatedAt: now,
    });
    return Response.json({ job_id: jobId, status: "running", poll_url: `/api/v1/jobs/${jobId}` }, { status: 202, headers: noStoreHeaders() });
  } catch (cause) { return aiRouteError(cause); }
}
