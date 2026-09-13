import "server-only";

import { and, eq, lt } from "drizzle-orm";
import { googleApiKey } from "@/lib/ai/google-models";
import { closeReservation } from "@/lib/billing/repository";
import { recordUnitUsage, type MeteringContext } from "@/lib/billing/usage";
import { db } from "@/lib/db";
import { aiJobs } from "@/lib/db/schema";
import { putObject } from "@/lib/storage/s3";

/**
 * On-demand finalization of Veo jobs.
 *
 * Nothing waits on Google server-side: the submit route stores the operation
 * name and returns, and every `GET /jobs/:id` for a running video job lands
 * here. A poll that finds the operation still running only bumps the progress
 * estimate. The poll that finds it done takes an optimistic lock on the row —
 * progress jumps to 90 — so that of the several clients that may be polling
 * the same job, exactly one downloads, stores and bills the clip; the rest see
 * 90% until it lands.
 */

export type VideoJob = typeof aiJobs.$inferSelect;

export const VIDEO_FEATURE = "Video · Veo";

/** The lock value: a running video job at or past this is being finalized. */
const FINALIZING_PERCENT = 90;
/** Where the lock is put back on a transient failure, so the next poll retries. */
const RETRY_PERCENT = 50;

type VideoJobRequest = { operationName?: unknown; model?: unknown; priceModel?: unknown; durationSeconds?: unknown; numberOfVideos?: unknown };

type Operation = {
  done?: boolean;
  error?: { code?: number; message?: string };
  response?: { generateVideoResponse?: { generatedSamples?: Array<{ video?: { uri?: string; mimeType?: string } }>; raiMediaFilteredCount?: number; raiMediaFilteredReasons?: string[] } };
};

export type VideoJobPoll = {
  job: VideoJob;
  /** Present only for the poll that won the lock. The route runs it in `after()`. */
  finalize?: () => Promise<void>;
};

/** A failure worth retrying on the next poll: the network, or Google or storage having a bad minute. */
class TransientError extends Error {}

function isTransient(cause: unknown) {
  if (cause instanceof TransientError) return true;
  if (cause instanceof Error && (cause.name === "AbortError" || cause.name === "TimeoutError")) return true;
  // undici surfaces connection failures as a TypeError("fetch failed").
  if (cause instanceof TypeError) return true;
  return cause instanceof Error && /^PROVIDER_5\d\d/.test(cause.message);
}

function running(job: VideoJob) {
  return and(eq(aiJobs.id, job.id), eq(aiJobs.userId, job.userId), eq(aiJobs.status, "running"));
}

async function failJob(job: VideoJob, code: string, message: string): Promise<VideoJob> {
  const now = new Date();
  await db.update(aiJobs).set({ status: "failed", errorCode: code.slice(0, 120), errorMessage: message.slice(0, 600), updatedAt: now }).where(running(job));
  if (job.reservationId) await closeReservation({ reservationId: job.reservationId, userId: job.userId, success: false }).catch((cause) => console.error("Video reservation release failed", { jobId: job.id, cause }));
  return { ...job, status: "failed", errorCode: code.slice(0, 120), errorMessage: message.slice(0, 600), updatedAt: now };
}

/** Downloads a Veo file URI. It redirects to a signed storage host and the key is stripped across the hop, so each hop is re-issued with the header. */
async function downloadWithKey(uri: string, key: string) {
  let url = uri;
  for (let hop = 0; hop < 5; hop += 1) {
    const response = await fetch(url, { headers: { "x-goog-api-key": key }, redirect: "manual", signal: AbortSignal.timeout(280_000) });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error("INVALID_PROVIDER_RESPONSE");
      url = new URL(location, url).toString();
      continue;
    }
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      if (response.status >= 500) throw new TransientError(`PROVIDER_${response.status}:${text.slice(0, 200)}`);
      throw new Error(`PROVIDER_${response.status}:${text.slice(0, 200)}`);
    }
    return { bytes: Buffer.from(await response.arrayBuffer()), contentType: response.headers.get("content-type") };
  }
  throw new Error("VIDEO_DOWNLOAD_REDIRECT_LOOP");
}

async function finalize(job: VideoJob, request: VideoJobRequest, operation: Operation) {
  const samples = operation.response?.generateVideoResponse?.generatedSamples ?? [];
  const first = samples[0]?.video;
  const priceModel = typeof request.priceModel === "string" ? request.priceModel : String(request.model ?? "");
  const durationSeconds = typeof request.durationSeconds === "number" ? request.durationSeconds : 8;
  try {
    if (!first?.uri) {
      const filtered = operation.response?.generateVideoResponse?.raiMediaFilteredCount ?? 0;
      const reasons = operation.response?.generateVideoResponse?.raiMediaFilteredReasons ?? [];
      throw new Error(filtered > 0 ? `VIDEO_FILTERED:${reasons.join("; ")}` : "INVALID_PROVIDER_RESPONSE");
    }
    const downloaded = await downloadWithKey(first.uri, googleApiKey());
    const mimeType = first.mimeType ?? downloaded.contentType ?? "video/mp4";
    const stored = await putObject({ key: `videos/${job.userId}/${job.id}.mp4`, body: downloaded.bytes, contentType: mimeType });
    const context: MeteringContext = { userId: job.userId, reservationId: job.reservationId, feature: VIDEO_FEATURE, capability: "video", operationId: job.reservationId ?? job.id };
    const usage = await recordUnitUsage({ context, provider: "google", model: priceModel, capability: "video", unit: "video_seconds", units: durationSeconds * samples.length, eventId: "video" });
    await db.update(aiJobs).set({
      status: "succeeded",
      progressPercent: 100,
      resultObjectKey: stored.key,
      resultMeta: { mimeType, durationSeconds, chargedPoints: usage?.chargedPoints ?? 0, model: typeof request.model === "string" ? request.model : priceModel },
      updatedAt: new Date(),
    }).where(running(job));
    if (job.reservationId) await closeReservation({ reservationId: job.reservationId, userId: job.userId, success: true });
  } catch (cause) {
    const code = cause instanceof Error ? cause.message : "VIDEO_FINALIZE_FAILED";
    if (isTransient(cause)) {
      // Hand the lock back so the next poll tries again.
      console.error("Video finalization will retry", { jobId: job.id, code });
      await db.update(aiJobs).set({ progressPercent: RETRY_PERCENT, updatedAt: new Date() }).where(running(job));
      return;
    }
    console.error("Video job failed", { jobId: job.id, code });
    await failJob(job, code, code.startsWith("VIDEO_FILTERED") ? "The provider filtered this video." : "Video generation could not be completed.");
  }
}

export async function pollVideoJob(job: VideoJob): Promise<VideoJobPoll> {
  const request = (job.requestJson ?? {}) as VideoJobRequest;
  const operationName = typeof request.operationName === "string" ? request.operationName : "";
  if (!operationName) return { job: await failJob(job, "VIDEO_OPERATION_MISSING", "Video generation could not be completed.") };

  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/${operationName}`, { headers: { "x-goog-api-key": googleApiKey() }, signal: AbortSignal.timeout(30_000) });
  if (!response.ok) {
    // A bad minute at Google keeps the job running; an operation it no longer
    // knows will never complete.
    if (response.status >= 500 || response.status === 429) return { job };
    const text = await response.text().catch(() => "");
    return { job: await failJob(job, `PROVIDER_${response.status}`, text.slice(0, 600) || "The provider rejected the poll.") };
  }
  const operation = await response.json() as Operation;
  if (operation.error) {
    return { job: await failJob(job, `PROVIDER_${operation.error.code ?? "ERROR"}`, operation.error.message ?? "Video generation failed.") };
  }
  if (!operation.done) {
    const elapsedSeconds = Math.max(0, (Date.now() - job.createdAt.getTime()) / 1000);
    const progressPercent = Math.max(job.progressPercent, Math.min(80, Math.floor(elapsedSeconds / 3)));
    if (progressPercent !== job.progressPercent) {
      await db.update(aiJobs).set({ progressPercent, updatedAt: new Date() }).where(running(job));
    }
    return { job: { ...job, progressPercent } };
  }

  // Done. Take the lock: only the poll that moves progress to 90 finalizes.
  const won = await db.update(aiJobs)
    .set({ progressPercent: FINALIZING_PERCENT, updatedAt: new Date() })
    .where(and(running(job), lt(aiJobs.progressPercent, FINALIZING_PERCENT)))
    .returning({ id: aiJobs.id });
  const locked = { ...job, progressPercent: FINALIZING_PERCENT };
  if (!won.length) return { job: locked };
  return { job: locked, finalize: () => finalize(job, request, operation) };
}
