import { isOmniModel, omniRequestBody } from "@/lib/ai/omni";
import { veoDurations, veoFamily, veoRequestBody } from "@/lib/ai/veo";
import { z } from "zod";
import { flowcyMedia, sharedMediaModel, sharedMediaRate, mediaPayload } from "@/lib/ai/flowcy-media";
import { requireApiUser } from "@/lib/auth/bearer";
import { aiRouteError, noStoreHeaders } from "@/lib/ai/http";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { pointsForNanoUsd } from "@/lib/billing/unit-pricing";
import { reserveCredits } from "@/lib/billing/repository";
import { db } from "@/lib/db";
import { aiJobs } from "@/lib/db/schema";
import { VIDEO_FEATURE } from "@/lib/ai/video-jobs";
export const maxDuration = 300;
const image = z.object({ mime_type: z.enum(["image/png", "image/jpeg", "image/webp", "image/heic"]), base64: z.string().min(1).max(8_000_000).optional(), object_key: z.string().min(1).max(500).optional() }).refine((value) => Boolean(value.base64) !== Boolean(value.object_key), "Provide an uploaded image key.");

const schema = z.object({
  model: z.string().min(1).max(160),
  prompt: z.string().min(1).max(20_000),
  negative_prompt: z.string().max(20_000).optional(),
  aspect_ratio: z.enum(["16:9", "9:16"]),
  resolution: z.enum(["360p", "720p", "1080p", "4k"]).optional(),
  duration_seconds: z.number().int().min(3).max(15),
  person_generation: z.enum(["allow_all", "allow_adult", "dont_allow"]),
  number_of_videos: z.number().int().min(1).max(2).optional(),
  generate_audio: z.boolean().optional(),
  seed: z.number().int().optional(),
  first_frame: image.optional(),
  last_frame: image.optional(),
  reference_images: z.array(image).max(6).optional(),
});


export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return Response.json({ code: "bad_request", error: "Invalid video request" }, { status: 400 });
    const input = parsed.data;
    const model = await sharedMediaModel(request, input.model, "video");
    const images = [input.first_frame, input.last_frame, ...(input.reference_images ?? [])].filter(Boolean);
    for (const image of images) if (image?.object_key && (!image.object_key.startsWith(`ai-media/video-inputs/${user.id}/`) || image.object_key.includes("..") || image.object_key.includes("\\"))) throw new Error("VIDEO_OPTIONS_INVALID:Image belongs to another account.");
    const frame = (value: typeof input.first_frame) => value ? { mime_type: value.mime_type, base64: value.base64 ?? "uploaded" } : undefined;
    const videoInput = { prompt: input.prompt, negativePrompt: input.negative_prompt, aspectRatio: input.aspect_ratio, resolution: input.resolution, durationSeconds: input.duration_seconds, personGeneration: input.person_generation, numberOfVideos: input.number_of_videos, generateAudio: input.generate_audio, seed: input.seed, firstFrame: frame(input.first_frame), lastFrame: frame(input.last_frame), referenceImages: input.reference_images?.map(value => frame(value)!) };
    const omni = isOmniModel(model.id);
    if (!omni && (!veoDurations(veoFamily(model.id), input.resolution ?? "720p", Boolean(input.reference_images?.length)).includes(input.duration_seconds) || (input.reference_images?.length ?? 0) > 3)) throw new Error("VIDEO_OPTIONS_INVALID:Unsupported duration or references.");
    if (omni) omniRequestBody(model.id, videoInput);
    const resolution = omni ? input.resolution ?? "720p" : veoRequestBody(model.id, videoInput).resolution;
    const nanoUsdPerUnit = sharedMediaRate(model, resolution);
    const numberOfVideos = input.model.startsWith("veo-2") ? Math.min(input.number_of_videos ?? 1, 2) : 1;
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `video:${user.id}:${crypto.randomUUID()}`;
    const reservation = await reserveCredits({ user, operationKey, feature: VIDEO_FEATURE, points: reserveWithMargin(pointsForNanoUsd(nanoUsdPerUnit * input.duration_seconds * numberOfVideos, billingConfig.videoReservationPoints)) });
    const delegated = new Request(request.url, { method: "POST", headers: { ...Object.fromEntries(request.headers), "idempotency-key": operationKey }, body: JSON.stringify(input) });
    // An uncertain submission keeps the reservation; retrying the same key reuses it.
    const remote = await mediaPayload(await flowcyMedia(delegated, "/api/v1/ai/videos")) as { job_id: string };
    if (!remote.job_id?.startsWith("flowcy-")) throw new Error("INVALID_PROVIDER_RESPONSE");
    const now = new Date();
    await db.insert(aiJobs).values({ id: remote.job_id, userId: user.id, reservationId: reservation?.id ?? null, capability: "video", status: "running", requestJson: { remoteJobId: remote.job_id, model: input.model, durationSeconds: input.duration_seconds, numberOfVideos, nanoUsdPerUnit }, progressPercent: 5, createdAt: now, updatedAt: now }).onConflictDoNothing();
    return Response.json({ job_id: remote.job_id, status: "running", poll_url: `/api/v1/jobs/${remote.job_id}` }, { status: 202, headers: noStoreHeaders() });
  } catch (cause) { return aiRouteError(cause); }
}
