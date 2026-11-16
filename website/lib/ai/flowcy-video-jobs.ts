import { and, eq, lt } from "drizzle-orm";
import { db } from "@/lib/db";
import { aiJobs } from "@/lib/db/schema";
import { flowcyMedia, mediaPayload } from "./flowcy-media";
import { noStoreHeaders } from "./http";
import { VIDEO_FEATURE } from "./video-jobs";
import { closeReservation } from "@/lib/billing/repository";
import { recordUnitUsage } from "@/lib/billing/usage";

type Job = typeof aiJobs.$inferSelect;
export async function sharedVideoJob(request: Request, job: Job) {
  const response = await flowcyMedia(request, `/api/v1/jobs/${encodeURIComponent(job.id)}`);
  if (!response.ok) return response;
  const remote = await mediaPayload(response) as { status: string; progress_percent: number; result_meta?: Record<string, unknown>; error?: { code: string; message: string } };
  const own = and(eq(aiJobs.id, job.id), eq(aiJobs.userId, job.userId));
  if (remote.status === "failed" && job.status === "running") {
    if (job.reservationId) await closeReservation({ reservationId: job.reservationId, userId: job.userId, success: false });
    await db.update(aiJobs).set({ status: "failed", errorCode: remote.error?.code ?? "SHARED_VIDEO_FAILED", errorMessage: "Video generation failed.", updatedAt: new Date() }).where(own);
  }
  if (remote.status === "succeeded" && job.status !== "succeeded") {
    if (job.progressPercent >= 90 && Date.now() - job.updatedAt.getTime() > 330000) {
      await db.update(aiJobs).set({ progressPercent: 50 }).where(and(own, eq(aiJobs.updatedAt, job.updatedAt)));
    }
    const lock = await db.update(aiJobs).set({ progressPercent: 90, updatedAt: new Date() }).where(and(own, eq(aiJobs.status, "running"), lt(aiJobs.progressPercent, 90))).returning();
    if (!lock.length) return Response.json({ id: job.id, status: "running", progress_percent: 90, result_url: null, result_meta: null, error: null }, { headers: noStoreHeaders() });
    try {
      const input = job.requestJson as { model: string; durationSeconds: number; numberOfVideos: number; nanoUsdPerUnit: number };
      const usage = await recordUnitUsage({ context: { userId: job.userId, reservationId: job.reservationId, feature: VIDEO_FEATURE, capability: "video", operationId: job.reservationId ?? job.id }, provider: "google", model: input.model, capability: "video", unit: "video_seconds", units: input.durationSeconds * (Array.isArray(remote.result_meta?.objectKeys) ? remote.result_meta.objectKeys.length : input.numberOfVideos), nanoUsdPerUnit: input.nanoUsdPerUnit, eventId: "video" });
      if (job.reservationId) await closeReservation({ reservationId: job.reservationId, userId: job.userId, success: true });
      const resultMeta = { ...remote.result_meta, chargedPoints: usage?.chargedPoints ?? 0 };
      await db.update(aiJobs).set({ status: "succeeded", progressPercent: 100, resultMeta, updatedAt: new Date() }).where(own);
      job = { ...job, resultMeta };
    } catch (cause) {
      await db.update(aiJobs).set({ progressPercent: 50, updatedAt: new Date() }).where(own);
      throw cause;
    }
  }
  return Response.json({ ...remote, result_meta: remote.status === "succeeded" ? { ...remote.result_meta, chargedPoints: job.resultMeta?.chargedPoints ?? 0 } : remote.result_meta }, { headers: noStoreHeaders() });
}
