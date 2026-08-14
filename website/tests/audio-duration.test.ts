import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

// One MPEG-1 Layer III frame header: sync + 192 kbps + 44.1 kHz stereo, matching Lyria's output.
function mp3Frame(payloadBytes: number) {
  const header = Buffer.from([0xff, 0xfb, 0xb0, 0x44]);
  return Buffer.concat([header, Buffer.alloc(payloadBytes)]);
}

// ID3v2 tag with a syncsafe size, as Lyria prepends for its C2PA manifest.
function id3Tag(bodyBytes: number) {
  const tag = Buffer.alloc(10 + bodyBytes);
  tag.write("ID3", 0, "ascii");
  tag[3] = 3;
  tag[6] = (bodyBytes >> 21) & 0x7f;
  tag[7] = (bodyBytes >> 14) & 0x7f;
  tag[8] = (bodyBytes >> 7) & 0x7f;
  tag[9] = bodyBytes & 0x7f;
  return tag;
}

describe("measuredAudioDurationSeconds", () => {
  it("measures MP3 whose frame sync sets the high bit", async () => {
    const { measuredAudioDurationSeconds } = await import("@/lib/ai/audio-duration");
    // 192 kbps = 24000 bytes/second.
    expect(measuredAudioDurationSeconds(mp3Frame(23_996), "audio/mpeg")).toBeCloseTo(1, 5);
  });

  it("skips the ID3v2 tag before measuring", async () => {
    const { measuredAudioDurationSeconds } = await import("@/lib/ai/audio-duration");
    const audio = Buffer.concat([id3Tag(6_066), mp3Frame(23_996)]);
    expect(measuredAudioDurationSeconds(audio, "audio/mpeg")).toBeCloseTo(1, 5);
  });

  it("throws rather than billing zero when no container is recognized", async () => {
    const { measuredAudioDurationSeconds } = await import("@/lib/ai/audio-duration");
    expect(() => measuredAudioDurationSeconds(Buffer.alloc(4_096), "audio/mpeg")).toThrow(/AUDIO_DURATION_UNAVAILABLE/);
  });
});
