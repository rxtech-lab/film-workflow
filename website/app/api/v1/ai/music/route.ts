import { after } from "next/server";
import { z } from "zod";
import { measuredAudioDurationSeconds } from "@/lib/ai/audio-duration";
import { aiRouteError, noStoreHeaders, providerError } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { closeReservation, reserveCredits } from "@/lib/billing/repository";
import { estimateReservationPoints } from "@/lib/billing/unit-pricing";
import { recordUnitUsage, type MeteringContext } from "@/lib/billing/usage";
import { db } from "@/lib/db";
import { aiJobs } from "@/lib/db/schema";
import { and, eq } from "drizzle-orm";
import { putObject } from "@/lib/storage/s3";

export const maxDuration = 300;

const schema = z.object({
  prompt: z.string().min(1).max(40_000),
  response_mime_type: z.enum(["audio/wav", "audio/mp3", "audio/mpeg"]).optional(),
  images: z.array(z.object({ mime_type: z.enum(["image/png", "image/jpeg", "image/webp"]), base64: z.string().max(8_000_000) })).max(4).optional(),
});

async function generate(input: z.infer<typeof schema>) {
  const key = process.env.GOOGLE_GENERATIVE_AI_API_KEY?.trim();
  if (!key) throw new Error("GOOGLE_AI_NOT_CONFIGURED");
  const parts: Array<Record<string, unknown>> = [{ text: input.prompt }];
  for (const image of input.images ?? []) parts.push({ inline_data: { mime_type: image.mime_type, data: image.base64 } });
  // lyria-3-pro-preview always returns MP3 and rejects any audio format request: responseMimeType
  // takes text mimetypes only, and responseFormat.audio.mimeType 400s on every enum value (verified
  // against the live API). response_mime_type is accepted from clients but only used as a fallback
  // label below; revisit if WAV, which the docs advertise, actually ships.
  const generationConfig: Record<string, unknown> = { responseModalities: ["AUDIO", "TEXT"] };
  const response = await fetch("https://generativelanguage.googleapis.com/v1beta/models/lyria-3-pro-preview:generateContent", { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key }, body: JSON.stringify({ contents: [{ parts }], generationConfig }), signal: AbortSignal.timeout(290_000) });
  if (!response.ok) await providerError(response);
  const body = await response.json() as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; inlineData?: { data?: string; mimeType?: string }; inline_data?: { data?: string; mime_type?: string } }> } }> };
  let lyrics: string | null = null;
  for (const candidate of body.candidates ?? []) for (const part of candidate.content?.parts ?? []) {
    if (part.text) lyrics = [lyrics, part.text].filter(Boolean).join("\n");
    const inline = part.inlineData ?? (part.inline_data ? { data: part.inline_data.data, mimeType: part.inline_data.mime_type } : undefined);
    if (inline?.data) return { audio: Buffer.from(inline.data, "base64"), mime: inline.mimeType ?? input.response_mime_type ?? "audio/mpeg", lyrics };
  }
  throw new Error("INVALID_PROVIDER_RESPONSE");
}

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid music request" }, { status: 400, headers: noStoreHeaders() });
    const jobId = crypto.randomUUID();
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `music:${user.id}:${jobId}`;
    const reservePoints = reserveWithMargin(estimateReservationPoints({ provider: "google", model: "lyria-3-pro-preview", unit: "audio_seconds", units: 180, floorPoints: billingConfig.musicReservationPoints }));
    const reservation = await reserveCredits({ userId: user.id, operationKey, feature: "Music · Lyria 3 Pro", points: reservePoints, scopeId: jobId });
    const now = new Date();
    await db.insert(aiJobs).values({ id: jobId, userId: user.id, reservationId: reservation?.id ?? null, capability: "music", status: "queued", requestJson: { prompt: parsed.data.prompt, responseMimeType: parsed.data.response_mime_type, imageCount: parsed.data.images?.length ?? 0 }, progressPercent: 0, createdAt: now, updatedAt: now });
    after(async () => {
      const context: MeteringContext = { userId: user.id, reservationId: reservation?.id ?? null, feature: "Music · Lyria 3 Pro", capability: "music", operationId: reservation?.id ?? jobId };
      try {
        await db.update(aiJobs).set({ status: "running", progressPercent: 10, updatedAt: new Date() }).where(and(eq(aiJobs.id, jobId), eq(aiJobs.userId, user.id)));
        const output = await generate(parsed.data);
        const seconds = measuredAudioDurationSeconds(output.audio, output.mime);
        const usage = await recordUnitUsage({ context, provider: "google", model: "lyria-3-pro-preview", capability: "music", unit: "audio_seconds", units: seconds, eventId: "music" });
        const extension = output.mime.includes("mp3") || output.mime.includes("mpeg") ? "mp3" : "wav";
        const stored = await putObject({ key: `music/${user.id}/${jobId}.${extension}`, body: output.audio, contentType: output.mime });
        await db.update(aiJobs).set({ status: "succeeded", progressPercent: 100, resultObjectKey: stored.key, resultMeta: { mimeType: output.mime, lyricsText: output.lyrics, durationSeconds: seconds, chargedPoints: usage?.chargedPoints ?? 0 }, updatedAt: new Date() }).where(and(eq(aiJobs.id, jobId), eq(aiJobs.userId, user.id)));
        if (reservation) await closeReservation({ reservationId: reservation.id, userId: user.id, success: true, scopeId: jobId });
      } catch (cause) {
        const code = cause instanceof Error ? cause.message : "MUSIC_GENERATION_FAILED";
        console.error("Music job failed", { jobId, code });
        await db.update(aiJobs).set({ status: "failed", errorCode: code.slice(0, 120), errorMessage: "Music generation could not be completed.", updatedAt: new Date() }).where(and(eq(aiJobs.id, jobId), eq(aiJobs.userId, user.id)));
        if (reservation) await closeReservation({ reservationId: reservation.id, userId: user.id, success: false, scopeId: jobId });
      }
    });
    return Response.json({ job_id: jobId, status: "queued", poll_url: `/api/v1/jobs/${jobId}` }, { status: 202, headers: noStoreHeaders() });
  } catch (cause) { return aiRouteError(cause); }
}
