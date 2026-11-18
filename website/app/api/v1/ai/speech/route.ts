import { flowcyMedia, mediaPayload } from "@/lib/ai/flowcy-media";
import { z } from "zod";
import { GEMINI_SPEECH_MODEL } from "@/lib/ai/gemini-speech";
import { aiRouteError, noStoreHeaders } from "@/lib/ai/http";
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
    const model = input.provider === "azure" && /DragonHD/i.test(input.ssml) ? "azure-hd-tts" : input.provider === "azure" ? "azure-neural-tts" : GEMINI_SPEECH_MODEL;
    const estimated = input.provider === "azure"
      ? estimateReservationPoints({ provider: "azure", model, unit: "characters", units: characters, floorPoints: billingConfig.speechReservationPoints })
      : estimateReservationPoints({ provider: "google", model, unit: "audio_seconds", units: Math.max(1, characters / 12), floorPoints: billingConfig.speechReservationPoints });
    console.info("Speech request", { provider: input.provider, model, characters, estimatedPoints: estimated, operationKey });
    const { value } = await withMeteredOperation({ user, feature: input.provider === "azure" ? "Narrative · Azure TTS" : "Narrative · Gemini TTS", capability: "speech", operationKey, reservePoints: reserveWithMargin(estimated), run: async (context) => {
      const delegated = new Request(request.url, { method: "POST", headers: { ...Object.fromEntries(request.headers), "idempotency-key": operationKey }, body: JSON.stringify(input) });
      const remote = await mediaPayload(await flowcyMedia(delegated, "/api/v1/ai/speech")) as { audio_base64: string; mime_type: string; duration_seconds: number };
      const output = { audio: Buffer.from(remote.audio_base64, "base64"), mime: remote.mime_type };
      const usage = input.provider === "azure"
        ? await recordUnitUsage({ context, provider: "azure", model, capability: "speech", unit: "characters", units: characters, eventId: "speech" })
        : await recordUnitUsage({ context, provider: "google", model, capability: "speech", unit: "audio_seconds", units: remote.duration_seconds, eventId: "speech" });
      const sampleRate = Number(output.mime.match(/rate=(\d+)/)?.[1] ?? 24_000);
      const responseAudio = input.provider === "gemini" && output.mime.includes("L16") ? pcm16ToWav(output.audio, sampleRate) : output.audio;
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
