import "server-only";

import { googleApiKey } from "@/lib/ai/google-models";
import { providerError } from "@/lib/ai/http";

/**
 * Transcription via Gemini's multimodal `generateContent` with a structured
 * output schema, diarized by prompt.
 *
 * Port of the desktop app's `GeminiTranscriptionClient`. The raw
 * `generateContent` envelope is returned unchanged: the app decodes
 * `candidates[].content.parts[].text` itself, and this route stays as thin as
 * the Whisper and Azure branches beside it.
 */

const BASE_URL = "https://generativelanguage.googleapis.com";
/** Above this, the audio must go through the Files API instead of inline base64 — the request itself has a hard size ceiling. */
export const INLINE_LIMIT_BYTES = 18 * 1024 * 1024;
const TIMEOUT_MS = 290_000;
const FILE_ACTIVE_DEADLINE_MS = 5 * 60 * 1000;

/**
 * Ported verbatim from `geminiSTTPrompt`. The explicit instructions about not
 * estimating timestamps from text length, and about verifying monotonicity,
 * measurably improve the output — do not "tidy" them away.
 */
export const PROMPT_TEMPLATE = `Transcribe this audio with speaker diarization. Rules:
- Identify distinct speakers and number them 1, 2, 3, ... in order of first appearance. Use at most %d speakers.
- Split the transcript into complete sentences or complete speaker turns. Never split one sentence at a comma, colon, or other clause punctuation.
- For each phrase, listen for the first and last spoken word and give its exact start offset and duration in milliseconds. Do not estimate timestamps from text length.
- Offsets must be non-decreasing and every phrase must end within the audio's real duration. Before responding, verify that no later phrase starts earlier than a preceding phrase.
- Keep the verbatim text with natural punctuation.
- Also report the total audio duration in milliseconds as durationMs.
Output only the JSON.`;

export const RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    durationMs: { type: "integer" },
    phrases: {
      type: "array",
      items: {
        type: "object",
        properties: {
          speaker: { type: "integer" },
          offsetMs: { type: "integer" },
          durationMs: { type: "integer" },
          text: { type: "string" },
        },
        required: ["speaker", "offsetMs", "durationMs", "text"],
      },
    },
  },
  required: ["durationMs", "phrases"],
} as const;

export type GeminiTranscribeInput = {
  model: string;
  audio: Buffer;
  mimeType: string;
  filename: string;
  language?: string;
  /** Names and jargon this recording uses, spelled out as a hint rather than a rule. */
  prompt?: string;
  maxSpeakers?: number;
};

export function geminiPrompt(input: Pick<GeminiTranscribeInput, "language" | "prompt" | "maxSpeakers">) {
  const speakers = Math.min(20, Math.max(1, Math.floor(input.maxSpeakers ?? 2)));
  let prompt = PROMPT_TEMPLATE.replace("%d", String(speakers));
  const language = input.language?.trim();
  if (language) prompt += `\nThe audio is primarily in ${language}.`;
  const terms = input.prompt?.trim();
  // Forcing the terms would make the model insert words it never heard.
  if (terms) prompt += `\nThese names and terms appear in the audio and are spelled exactly like this: ${terms}.`;
  return prompt;
}

function audioBytes(audio: Buffer) {
  return audio.buffer.slice(audio.byteOffset, audio.byteOffset + audio.byteLength) as ArrayBuffer;
}

type UploadedFile = { name: string; uri: string; state?: string };

/** Uploads via the resumable protocol and waits for the file to become ACTIVE — Gemini won't accept a reference until processing completes. */
async function uploadResumable(input: GeminiTranscribeInput, key: string): Promise<UploadedFile> {
  const start = await fetch(`${BASE_URL}/upload/v1beta/files`, {
    method: "POST",
    headers: {
      "x-goog-api-key": key,
      "X-Goog-Upload-Protocol": "resumable",
      "X-Goog-Upload-Command": "start",
      "X-Goog-Upload-Header-Content-Length": String(input.audio.length),
      "X-Goog-Upload-Header-Content-Type": input.mimeType,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ file: { display_name: input.filename } }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!start.ok) await providerError(start);
  const uploadURL = start.headers.get("x-goog-upload-url");
  if (!uploadURL) throw new Error("INVALID_PROVIDER_RESPONSE");

  const upload = await fetch(uploadURL, {
    method: "POST",
    headers: {
      "x-goog-api-key": key,
      "X-Goog-Upload-Command": "upload, finalize",
      "X-Goog-Upload-Offset": "0",
      "Content-Length": String(input.audio.length),
    },
    body: audioBytes(input.audio),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!upload.ok) await providerError(upload);
  const uploaded = await upload.json() as { file?: { name?: string; uri?: string; state?: string } };
  if (!uploaded.file?.name || !uploaded.file.uri) throw new Error("INVALID_PROVIDER_RESPONSE");
  const file: UploadedFile = { name: uploaded.file.name, uri: uploaded.file.uri, state: uploaded.file.state };
  if ((file.state ?? "").toUpperCase() !== "ACTIVE") await waitUntilActive(file.name, key);
  return file;
}

/** Polls the file until it leaves PROCESSING. Capped so a stuck upload surfaces as an error rather than hanging the request. */
async function waitUntilActive(name: string, key: string) {
  const deadline = Date.now() + FILE_ACTIVE_DEADLINE_MS;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    const response = await fetch(`${BASE_URL}/v1beta/${name}`, { headers: { "x-goog-api-key": key }, signal: AbortSignal.timeout(30_000) });
    if (!response.ok) continue;
    const state = ((await response.json() as { state?: string }).state ?? "").toUpperCase();
    if (state === "ACTIVE") return;
    if (state === "FAILED") throw new Error("GEMINI_FILE_PROCESSING_FAILED");
  }
  throw new Error("GEMINI_FILE_NEVER_ACTIVE");
}

async function deleteFile(name: string, key: string) {
  await fetch(`${BASE_URL}/v1beta/${name}`, { method: "DELETE", headers: { "x-goog-api-key": key }, signal: AbortSignal.timeout(30_000) })
    .catch((cause) => console.error("Failed to delete Gemini upload", { name, cause }));
}

export async function geminiTranscribe(input: GeminiTranscribeInput): Promise<Record<string, unknown>> {
  const key = googleApiKey();
  const prompt = geminiPrompt(input);
  // Small files ride along inline; large ones must be uploaded first.
  let uploaded: UploadedFile | null = null;
  try {
    let audioPart: Record<string, unknown>;
    if (input.audio.length <= INLINE_LIMIT_BYTES) {
      audioPart = { inline_data: { mime_type: input.mimeType, data: input.audio.toString("base64") } };
    } else {
      uploaded = await uploadResumable(input, key);
      audioPart = { file_data: { mime_type: input.mimeType, file_uri: uploaded.uri } };
    }
    const response = await fetch(`${BASE_URL}/v1beta/models/${encodeURIComponent(input.model)}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }, audioPart] }],
        generationConfig: { temperature: 0, responseMimeType: "application/json", responseSchema: RESPONSE_SCHEMA },
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) await providerError(response);
    return await response.json() as Record<string, unknown>;
  } finally {
    if (uploaded) await deleteFile(uploaded.name, key);
  }
}
