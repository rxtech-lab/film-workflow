import { describe, expect, it } from "vitest";
import { lyricTextAt, lyricTracks, parseLyricCaptions } from "@/lib/marketplace/lyrics";
import { allowedExtensions, itemInput } from "@/lib/marketplace/schema";

const srt = "1\n00:00:00,000 --> 00:00:01,000\nFirst line\n\n2\n00:00:01,500 --> 00:00:03,000\nSecond line";
describe("music lyrics and translations", () => {
  it("imports SRT and VTT and switches text at exact boundaries, leaving gaps empty", () => {
    const original = { language: "en", cues: parseLyricCaptions(srt) };
    const translated = { language: "zh-Hans", cues: parseLyricCaptions("\uFEFFWEBVTT\n\n00:00.000 --> 00:01.000 align:center\n第一行\n\n00:01.500 --> 00:03.000\n第二行") };
    expect(lyricTextAt(original, 0.5)).toBe("First line");
    expect(lyricTextAt(original, 1)).toBe("");
    expect(lyricTextAt(original, 1.5)).toBe("Second line");
    expect(lyricTextAt(translated, 1.5)).toBe("第二行");
    expect(lyricTextAt(undefined, 1.5)).toBe("");
    const parsed = itemInput.parse({ kind: "audio", categoryId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Song", pricePoints: 0, metadata: { lyricTracks: [original, translated] } });
    expect(parsed.metadata.lyricTracks).toEqual([original, translated]);
  });
  it("rejects malformed timings and empty, oversized or duplicate-language tracks", () => {
    for (const value of ["", "plain lyrics", "1\n00:00:02,000 --> 00:00:01,000\nBackwards", "1\n00:61:00,000 --> 00:62:00,000\nInvalid"]) expect(() => parseLyricCaptions(value)).toThrow();
    const track = { language: "en", cues: parseLyricCaptions(srt) };
    expect(lyricTracks.safeParse([track, { ...track, language: "EN" }]).success).toBe(false);
    expect(lyricTracks.safeParse([{ language: "en", cues: [] }]).success).toBe(false);
    expect(() => parseLyricCaptions("x".repeat(512_001))).toThrow();
  });
  it("permits audio excerpts only in audio and sound effect preview slots", () => {
    expect(allowedExtensions("audio", "preview-video")).toContain("mp3");
    expect(allowedExtensions("sound_effect", "preview-video")).toContain("wav");
    expect(allowedExtensions("audio", "preview-video")).toContain("mp4");
    expect(allowedExtensions("footage", "preview-video")).not.toContain("mp3");
  });
});
