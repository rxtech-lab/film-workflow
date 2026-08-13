import { z } from "zod";
import { measuredAudioDurationSeconds } from "@/lib/ai/audio-duration";
import { requireCatalogModel } from "@/lib/ai/catalog";
import { aiRouteError, noStoreHeaders, providerError } from "@/lib/ai/http";
import { withMeteredOperation } from "@/lib/ai/meter";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { getBillingSummary } from "@/lib/billing/repository";
import { estimateReservationPoints } from "@/lib/billing/unit-pricing";
import { recordUnitUsage } from "@/lib/billing/usage";
import { deleteObject, getObjectBytes, ownsTranscriptionObject } from "@/lib/storage/s3";

export const maxDuration = 300;

type Input = { provider: "openai" | "azure"; model: string; audio: Buffer; mimeType: string; filename: string; language?: string; prompt?: string; diarization?: boolean; maxSpeakers?: number; sourceObjectKey?: string };

async function parseInput(request: Request, userId: string): Promise<Input> {
  const contentType = request.headers.get("content-type") ?? "";
  if (contentType.includes("multipart/form-data")) {
    const form = await request.formData();
    const file = form.get("audio") ?? form.get("file");
    if (!(file instanceof File)) throw new Error("AUDIO_FILE_REQUIRED");
    const provider = form.get("provider") === "azure" ? "azure" : "openai";
    return { provider, model: String(form.get("model") || (provider === "azure" ? "azure-fast-transcription" : "whisper-1")), audio: Buffer.from(await file.arrayBuffer()), mimeType: file.type || "application/octet-stream", filename: file.name || "audio", language: String(form.get("language") || ""), prompt: String(form.get("prompt") || ""), diarization: String(form.get("diarization") || "") === "true", maxSpeakers: Number(form.get("max_speakers") || 2) };
  }
  const schema = z.object({ provider: z.enum(["openai", "azure"]), model: z.string().min(1), object_key: z.string().min(1).max(500), mime_type: z.string().optional(), filename: z.string().optional(), language: z.string().optional(), prompt: z.string().optional(), diarization: z.boolean().optional(), max_speakers: z.number().int().min(1).max(20).optional() });
  const parsed = schema.parse(await request.json());
  if (!ownsTranscriptionObject(userId, parsed.object_key)) throw new Error("INVALID_UPLOAD_OBJECT");
  const object = await getObjectBytes(parsed.object_key);
  return { provider: parsed.provider, model: parsed.model, audio: object.bytes, mimeType: parsed.mime_type || object.contentType, filename: parsed.filename || "audio", language: parsed.language, prompt: parsed.prompt, diarization: parsed.diarization, maxSpeakers: parsed.max_speakers, sourceObjectKey: parsed.object_key };
}

async function openAI(input: Input) {
  const key = process.env.OPENAI_API_KEY?.trim();
  if (!key) throw new Error("OPENAI_NOT_CONFIGURED");
  const form = new FormData();
  const audioBytes = input.audio.buffer.slice(input.audio.byteOffset, input.audio.byteOffset + input.audio.byteLength) as ArrayBuffer;
  form.set("file", new File([audioBytes], input.filename, { type: input.mimeType }));
  form.set("model", input.model);
  form.set("response_format", "verbose_json");
  if (input.prompt) form.set("prompt", input.prompt);
  if (input.language) form.set("language", input.language.slice(0, 2).toLowerCase());
  form.append("timestamp_granularities[]", "segment");
  form.append("timestamp_granularities[]", "word");
  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", { method: "POST", headers: { Authorization: `Bearer ${key}` }, body: form, signal: AbortSignal.timeout(290_000) });
  if (!response.ok) await providerError(response);
  return response.json() as Promise<Record<string, unknown>>;
}

async function azure(input: Input) {
  const key = process.env.AZURE_SPEECH_KEY?.trim();
  const configured = process.env.AZURE_SPEECH_REGION?.trim() || process.env.AZURE_SPEECH_ENDPOINT?.trim();
  if (!key || !configured) throw new Error("AZURE_SPEECH_NOT_CONFIGURED");
  let host = `${configured}.api.cognitive.microsoft.com`;
  try { host = new URL(configured).host.replace(".tts.speech.microsoft.com", ".api.cognitive.microsoft.com"); } catch {}
  const definition: Record<string, unknown> = { profanityFilterMode: "None" };
  if (input.diarization) definition.diarization = { enabled: true, maxSpeakers: Math.min(20, Math.max(1, input.maxSpeakers ?? 2)) };
  if (input.language) definition.locales = [input.language];
  const form = new FormData();
  form.set("definition", JSON.stringify(definition));
  const audioBytes = input.audio.buffer.slice(input.audio.byteOffset, input.audio.byteOffset + input.audio.byteLength) as ArrayBuffer;
  form.set("audio", new File([audioBytes], input.filename, { type: input.mimeType }));
  const response = await fetch(`https://${host}/speechtotext/transcriptions:transcribe?api-version=2025-10-15`, { method: "POST", headers: { "Ocp-Apim-Subscription-Key": key }, body: form, signal: AbortSignal.timeout(290_000) });
  if (!response.ok) await providerError(response);
  return response.json() as Promise<Record<string, unknown>>;
}

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const input = await parseInput(request, user.id);
    try {
      requireCatalogModel(input.model, "transcription");
      if (input.audio.length > 300 * 1024 * 1024) return Response.json({ code: "audio_too_large", error: "Audio exceeds the 300 MB limit." }, { status: 413, headers: noStoreHeaders() });
      const minutes = Math.ceil(measuredAudioDurationSeconds(input.audio, input.mimeType) / 60);
      const billingModel = input.provider === "azure" ? "azure-fast-transcription" : input.model;
      const reservePoints = reserveWithMargin(estimateReservationPoints({ provider: input.provider, model: billingModel, unit: "audio_minutes", units: minutes, floorPoints: billingConfig.transcriptionReservationPoints }));
      const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `transcription:${user.id}:${crypto.randomUUID()}`;
      const { value } = await withMeteredOperation({ user, feature: `Transcription · ${input.provider === "azure" ? "Azure" : "OpenAI"}`, capability: "transcription", operationKey, reservePoints, run: async (context) => {
        const body = input.provider === "azure" ? await azure(input) : await openAI(input);
        const usage = await recordUnitUsage({ context, provider: input.provider, model: billingModel, capability: "transcription", unit: "audio_minutes", units: minutes, eventId: "transcription" });
        return { body, chargedPoints: usage?.chargedPoints ?? 0 };
      } });
      const summary = await getBillingSummary(user.id);
      return Response.json({ ...value.body, rxlab_usage: { chargedPoints: value.chargedPoints, availablePoints: summary.availablePoints } }, { headers: noStoreHeaders() });
    } finally {
      if (input.sourceObjectKey) {
        await deleteObject(input.sourceObjectKey).catch((cause) => console.error("Failed to delete transcription upload", { key: input.sourceObjectKey, cause }));
      }
    }
  } catch (cause) { return aiRouteError(cause); }
}
