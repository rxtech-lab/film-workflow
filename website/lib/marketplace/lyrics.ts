import { z } from "zod";

export const lyricCue = z.object({
  start: z.number().finite().min(0).max(86_400),
  end: z.number().finite().positive().max(86_400),
  text: z.string().trim().min(1).max(2000),
}).refine((cue) => cue.end > cue.start, "A caption must end after it starts.");

export const lyricTrack = z.object({
  language: z.string().trim().regex(/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/, "Use a language code such as en or zh-Hans."),
  cues: z.array(lyricCue).min(1).max(2000),
});
export type LyricTrack = z.infer<typeof lyricTrack>;

export const lyricTracks = z.array(lyricTrack).max(12)
  .refine((tracks) => new Set(tracks.map((track) => track.language.toLowerCase())).size === tracks.length, "Use one caption track per language.")
  .refine((tracks) => new TextEncoder().encode(JSON.stringify(tracks)).length <= 512_000, "Lyrics and translations must be under 500 KB.");

/** SRT and WebVTT use the music file's clock, including for translated tracks. */
export function parseLyricCaptions(source: string): LyricTrack["cues"] {
  if (new TextEncoder().encode(source).length > 512_000) throw new Error("Caption files must be under 500 KB.");
  const blocks = source.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n").trim().split(/\n[ \t]*\n/);
  const cues: LyricTrack["cues"] = [];
  const timestamp = (value: string) => {
    if (!/^(?:\d{2,}:)?\d{2}:\d{2}[.,]\d{3}$/.test(value)) throw new Error("Invalid caption timestamp.");
    const parts = value.replace(",", ".").split(":").map(Number);
    const seconds = parts.pop()!;
    const minutes = parts.pop()!;
    if (minutes >= 60 || seconds >= 60) throw new Error("Invalid caption timestamp.");
    return (parts[0] ?? 0) * 3600 + minutes * 60 + seconds;
  };
  for (const block of blocks) {
    const lines = block.split("\n");
    if (/^(WEBVTT(?:\s|$)|NOTE(?:\s|$)|STYLE$|REGION$)/.test(lines[0])) continue;
    const index = lines[0]?.includes("-->") ? 0 : 1;
    const match = lines[index]?.match(/^(\S+)\s+-->\s+(\S+)(?:\s+.*)?$/);
    if (!match) throw new Error("Use an SRT or VTT file with timed captions.");
    const cue = lyricCue.parse({ start: timestamp(match[1]), end: timestamp(match[2]), text: lines.slice(index + 1).join("\n").replace(/<[^>]*>/g, "") });
    cues.push(cue);
  }
  return z.array(lyricCue).min(1, "No timed captions found.").max(2000).parse(cues).sort((a, b) => a.start - b.start);
}

export function lyricTextAt(track: LyricTrack | undefined, time: number): string {
  return track?.cues.filter((cue) => cue.start <= time && time < cue.end).map((cue) => cue.text).join("\n") ?? "";
}
