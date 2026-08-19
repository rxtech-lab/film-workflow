import { z } from "zod";
import { aiRouteError, noStoreHeaders, providerError } from "@/lib/ai/http";
import { withMeteredOperation } from "@/lib/ai/meter";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { getBalance } from "@/lib/billing/subscription";
import { estimateReservationPoints } from "@/lib/billing/unit-pricing";
import { recordUnitUsage } from "@/lib/billing/usage";

export const maxDuration = 300;

const speaker = z.object({ name: z.string().max(120), voice: z.string().min(1).max(160) });
const schema = z.discriminatedUnion("provider", [
  z.object({ provider: z.literal("azure"), ssml: z.string().min(1).max(200_000), format: z.string().max(100).default("audio-24khz-48kbitrate-mono-mp3") }),
  z.object({ provider: z.literal("gemini"), transcript: z.string().min(1).max(120_000), speakers: z.array(speaker).min(1).max(2) }),
]);

function billableCharacters(ssml: string) {
  return ssml.replace(/<[^>]*>/g, "").replace(/&(?:amp|lt|gt|quot|apos);/g, "x").length;
}

function azureRegion() {
  const value = process.env.AZURE_SPEECH_REGION?.trim() || process.env.AZURE_SPEECH_ENDPOINT?.trim();
  if (!value) throw new Error("AZURE_SPEECH_NOT_CONFIGURED");
  try {
    const host = new URL(value).host;
    return host.split(".")[0];
  } catch { return value; }
}

function azureMime(format: string) {
  if (format.includes("mp3")) return "audio/mpeg";
  if (format.includes("ogg")) return "audio/ogg";
  return "audio/wav";
}

async function azureSpeech(ssml: string, format: string) {
  const key = process.env.AZURE_SPEECH_KEY?.trim();
  if (!key) throw new Error("AZURE_SPEECH_NOT_CONFIGURED");
  const startedAt = Date.now();
  const response = await fetch(`https://${azureRegion()}.tts.speech.microsoft.com/cognitiveservices/v1`, { method: "POST", headers: { "Ocp-Apim-Subscription-Key": key, "Content-Type": "application/ssml+xml", "X-Microsoft-OutputFormat": format, "User-Agent": "RxFilm-Studio" }, body: ssml, signal: AbortSignal.timeout(290_000) });
  console.info("Speech provider responded", { provider: "azure", status: response.status, elapsedMs: Date.now() - startedAt, ssmlLength: ssml.length, format });
  if (!response.ok) await providerError(response);
  const audio = Buffer.from(await response.arrayBuffer());
  if (!audio.length) {
    console.error("Azure speech returned an empty body", { status: response.status, elapsedMs: Date.now() - startedAt, ssml: ssml.slice(0, 800) });
    throw new Error("INVALID_PROVIDER_RESPONSE");
  }
  return { audio, mime: response.headers.get("content-type") ?? azureMime(format) };
}

async function geminiSpeech(transcript: string, speakers: Array<{ name: string; voice: string }>) {
  const key = process.env.GOOGLE_GENERATIVE_AI_API_KEY?.trim();
  if (!key) throw new Error("GOOGLE_AI_NOT_CONFIGURED");
  const speechConfig = speakers.length === 1
    ? { voiceConfig: { prebuiltVoiceConfig: { voiceName: speakers[0].voice } } }
    : { multiSpeakerVoiceConfig: { speakerVoiceConfigs: speakers.map((item) => ({ speaker: item.name, voiceConfig: { prebuiltVoiceConfig: { voiceName: item.voice } } })) } };
  const startedAt = Date.now();
  const response = await fetch("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent", { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key }, body: JSON.stringify({ contents: [{ parts: [{ text: transcript }] }], generationConfig: { responseModalities: ["AUDIO"], speechConfig } }), signal: AbortSignal.timeout(290_000) });
  console.info("Speech provider responded", { provider: "gemini", status: response.status, elapsedMs: Date.now() - startedAt, transcriptLength: transcript.length, speakers: speakers.map((item) => item.voice) });
  if (!response.ok) await providerError(response);
  const body = await response.json() as {
    promptFeedback?: { blockReason?: string; safetyRatings?: unknown };
    candidates?: Array<{ finishReason?: string; safetyRatings?: unknown; content?: { parts?: Array<{ text?: string; inlineData?: { data?: string; mimeType?: string }; inline_data?: { data?: string; mime_type?: string } }> } }>;
  };
  for (const candidate of body.candidates ?? []) for (const part of candidate.content?.parts ?? []) {
    const inline = part.inlineData ?? (part.inline_data ? { data: part.inline_data.data, mimeType: part.inline_data.mime_type } : undefined);
    if (inline?.data) return { audio: Buffer.from(inline.data, "base64"), mime: inline.mimeType ?? "audio/L16;rate=24000" };
  }
  // A 200 with no audio part is the model declining or truncating, never a transport
  // failure — the reason only lives in blockReason/finishReason, so log it before
  // it collapses into a generic INVALID_PROVIDER_RESPONSE.
  console.error("Gemini speech returned no audio", {
    elapsedMs: Date.now() - startedAt,
    blockReason: body.promptFeedback?.blockReason ?? null,
    finishReasons: (body.candidates ?? []).map((candidate) => candidate.finishReason ?? null),
    partKinds: (body.candidates ?? []).flatMap((candidate) => (candidate.content?.parts ?? []).map((part) => Object.keys(part).join("+"))),
    textParts: (body.candidates ?? []).flatMap((candidate) => (candidate.content?.parts ?? []).map((part) => part.text).filter(Boolean)),
    promptFeedback: body.promptFeedback ?? null,
    safetyRatings: (body.candidates ?? []).map((candidate) => candidate.safetyRatings ?? null),
    transcript: transcript.slice(0, 800),
  });
  throw new Error("INVALID_PROVIDER_RESPONSE");
}

function pcmDurationSeconds(audio: Buffer, mime: string) {
  const rate = Number(mime.match(/rate=(\d+)/)?.[1] ?? 24_000);
  if (mime.toLowerCase().includes("l16") || mime.toLowerCase().includes("pcm")) return audio.length / (rate * 2);
  return Math.max(1, audio.length / 6_000);
}

function pcm16ToWav(audio: Buffer, sampleRate: number) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + audio.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(audio.length, 40);
  return Buffer.concat([header, audio]);
}

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) {
      console.error("Speech request rejected", { issues: parsed.error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`) });
      return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid speech request" }, { status: 400, headers: noStoreHeaders() });
    }
    const input = parsed.data;
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `speech:${user.id}:${crypto.randomUUID()}`;
    const characters = billableCharacters(input.provider === "azure" ? input.ssml : input.transcript);
    const model = input.provider === "azure" && /DragonHD/i.test(input.ssml) ? "azure-hd-tts" : input.provider === "azure" ? "azure-neural-tts" : "gemini-3.1-flash-tts-preview";
    const estimated = input.provider === "azure"
      ? estimateReservationPoints({ provider: "azure", model, unit: "characters", units: characters, floorPoints: billingConfig.speechReservationPoints })
      : estimateReservationPoints({ provider: "google", model, unit: "audio_seconds", units: Math.max(1, characters / 12), floorPoints: billingConfig.speechReservationPoints });
    console.info("Speech request", { provider: input.provider, model, characters, estimatedPoints: estimated, operationKey });
    const { value } = await withMeteredOperation({ user, feature: input.provider === "azure" ? "Narrative · Azure TTS" : "Narrative · Gemini TTS", capability: "speech", operationKey, reservePoints: reserveWithMargin(estimated), run: async (context) => {
      const output = input.provider === "azure" ? await azureSpeech(input.ssml, input.format) : await geminiSpeech(input.transcript, input.speakers);
      const usage = input.provider === "azure"
        ? await recordUnitUsage({ context, provider: "azure", model, capability: "speech", unit: "characters", units: characters, eventId: "speech" })
        : await recordUnitUsage({ context, provider: "google", model, capability: "speech", unit: "audio_seconds", units: pcmDurationSeconds(output.audio, output.mime), eventId: "speech" });
      const sampleRate = Number(output.mime.match(/rate=(\d+)/)?.[1] ?? 24_000);
      const responseAudio = input.provider === "gemini" ? pcm16ToWav(output.audio, sampleRate) : output.audio;
      const responseMime = input.provider === "gemini" ? "audio/wav" : output.mime;
      return { audio: responseAudio.toString("base64"), mime: responseMime, chargedPoints: usage?.chargedPoints ?? 0 };
    } });
    const balance = await getBalance(user);
    console.info("Speech request completed", { provider: input.provider, model, characters, audioBytes: Math.floor(value.audio.length * 3 / 4), chargedPoints: value.chargedPoints });
    return Response.json({ audio_base64: value.audio, mime_type: value.mime, characters, usage: { chargedPoints: value.chargedPoints, availablePoints: balance.available } }, { headers: noStoreHeaders() });
  } catch (cause) {
    // aiRouteError only logs the message; the stack is what separates a provider
    // rejection from a billing or database failure.
    if (!(cause instanceof Error) || cause.name !== "UnauthorizedError") {
      console.error("Speech request failed", { error: cause instanceof Error ? cause.message : String(cause), stack: cause instanceof Error ? cause.stack : undefined });
    }
    return aiRouteError(cause);
  }
}
