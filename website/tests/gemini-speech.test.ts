import { afterEach, describe, expect, it, vi } from "vitest";
import { geminiSpeechAudio, geminiSpeechRequest } from "@/lib/ai/gemini-speech";

vi.mock("server-only", () => ({}));
afterEach(() => vi.useRealTimers());
const speakers = [{ name: "Alice", voice: "Achernar" }, { name: "Bob", voice: "Puck" }];

describe("Gemini 3.8 speech migration", () => {
  it("moves desktop directions, labels and emotions out of spoken dialogue", () => {
    const request = geminiSpeechRequest("Synthesize speech for the following conversation between Alice and Bob.\n\nScene: A quiet room\nNotes: Speak slowly\n\nAlice: [happy] Hello.\nA second line.\nBob: Hi!", speakers);
    expect(request.model).toBe("gemini-3.8-flash-tts");
    expect(request.input[0].content).toEqual([
      { type: "text", text: "Hello.\nA second line.", annotations: [{ type: "speech_metadata", speaker: "Alice", style: "Scene: A quiet room\nNotes: Speak slowly\nhappy" }] },
      { type: "text", text: "Hi!", annotations: [{ type: "speech_metadata", speaker: "Bob", style: "Scene: A quiet room\nNotes: Speak slowly" }] },
    ]);
    expect(request.generation_config.speech_config).toEqual({ speakers: [{ speaker: "Alice", voice: "Achernar" }, { speaker: "Bob", voice: "Puck" }] });
    expect(request.response_format).toEqual({ type: "audio", mime_type: "audio/l16", sample_rate: 24000 });
  });

  it("preserves plain voice sample text and the selected voice", () => {
    const request = geminiSpeechRequest("Hello!\nWelcome.", speakers.slice(0, 1));
    expect(request.input[0].content[0].text).toBe("Hello!\nWelcome.");
    expect(request.generation_config.speech_config).toEqual([{ voice: "Achernar" }]);
  });

  it("decodes audio output and rejects empty or text-only responses", () => {
    expect(geminiSpeechAudio({ steps: [{ type: "model_output", content: [{ type: "audio", data: Buffer.from([0, 1, 2, 3]).toString("base64") }] }] })).toEqual(Buffer.from([0, 1, 2, 3]));
    expect(geminiSpeechAudio({ steps: [{ type: "model_output", content: [{ type: "text", data: "text" }] }] })).toBeNull();
    expect(geminiSpeechAudio({ steps: [] })).toBeNull();
  });

  it("uses Google's current and scheduled audio pricing", async () => {
    const { unitPrice } = await import("@/lib/billing/unit-pricing");
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-15T00:00:00Z"));
    expect(unitPrice("google", "gemini-3.8-flash-tts", "audio_seconds")?.nanoUsdPerUnit).toBe(225_000);
    vi.setSystemTime(new Date("2027-01-01T00:00:00Z"));
    expect(unitPrice("google", "gemini-3.8-flash-tts", "audio_seconds")?.nanoUsdPerUnit).toBe(450_000);
  });
});
