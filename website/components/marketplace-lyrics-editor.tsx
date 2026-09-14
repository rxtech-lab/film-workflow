"use client";

import { useEffect, useRef, useState } from "react";
import { ZodError } from "zod";
import { lyricTextAt, lyricTrack, lyricTracks, parseLyricCaptions, type LyricTrack } from "@/lib/marketplace/lyrics";

export function MarketplaceLyricsEditor({ tracks, onChange, disabled, itemId, previewUrl, previewStart = 0, stagedAudio }: {
  tracks: LyricTrack[];
  onChange: (tracks: LyricTrack[]) => void;
  disabled: boolean;
  itemId?: string;
  previewUrl?: string | null;
  previewStart?: number;
  stagedAudio?: File;
}) {
  const [language, setLanguage] = useState("en");
  const [selected, setSelected] = useState("");
  const [error, setError] = useState("");
  const [time, setTime] = useState(0);
  const [audioUrl, setAudioUrl] = useState<string>();
  const [loading, setLoading] = useState(false);
  const audio = useRef<HTMLAudioElement>(null);
  const selection = selected || tracks[0]?.language || "off";
  const selectedTrack = tracks.find((track) => track.language === selection);

  async function importFile(file: File | undefined) {
    if (!file) return;
    try {
      if (file.size > 512_000) throw new Error("Caption files must be under 500 KB.");
      if (!/\.(srt|vtt)$/i.test(file.name)) throw new Error("Choose an SRT or VTT file.");
      const track = lyricTrack.parse({ language: language.trim(), cues: parseLyricCaptions(await file.text()) });
      const previous = tracks.findIndex((candidate) => candidate.language.toLowerCase() === track.language.toLowerCase());
      const updated = [...tracks];
      if (previous >= 0) updated[previous] = track; else updated.push(track);
      onChange(lyricTracks.parse(updated)); setError("");
    } catch (cause) {
      setError(cause instanceof ZodError ? cause.issues[0]?.message ?? "Invalid captions." : cause instanceof Error ? cause.message : "Could not read captions.");
    }
  }

  async function prepareAudio() {
    setLoading(true); setError("");
    try {
      let url = previewUrl || undefined;
      if (stagedAudio) url = URL.createObjectURL(stagedAudio);
      if (!url && itemId) {
        const response = await fetch(`/api/v1/admin/marketplace/items/${encodeURIComponent(itemId)}`);
        if (!response.ok) throw new Error("Could not load the music preview. Try again.");
        const item = await response.json();
        url = item.content_download_url;
      }
      if (!url) throw new Error("Choose or upload the music file first.");
      if (audioUrl?.startsWith("blob:")) URL.revokeObjectURL(audioUrl);
      setAudioUrl(url);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not play music."); }
    finally { setLoading(false); }
  }

  useEffect(() => () => { if (audioUrl?.startsWith("blob:")) URL.revokeObjectURL(audioUrl); }, [audioUrl]);

  const style = "rounded-xl border border-line bg-elevated px-3 py-2 text-sm";
  return <section className="space-y-4 rounded-2xl border border-line bg-surface p-6">
    <h2 className="text-lg font-semibold">Optional lyrics captions</h2>
    <p className="text-sm text-muted">Import SRT or VTT captions timed to the full song. Add another language to offer a translation during playback. Save the draft to keep your changes.</p>
    {tracks.map((track) => <div key={track.language} className="flex items-center gap-3 text-sm">
      <span>{track.language} · {track.cues.length} captions</span>
      <button type="button" disabled={disabled} className="text-muted hover:text-red-400" onClick={() => { onChange(tracks.filter((candidate) => candidate !== track)); if (selected === track.language) setSelected(""); }}>Remove</button>
    </div>)}
    <div className="flex flex-wrap items-center gap-3">
      <label className="text-sm">Language code <input aria-label="Caption language code" className={style} placeholder="en or zh-Hans" value={language} onChange={(event) => setLanguage(event.target.value)} disabled={disabled} /></label>
      <label className={`${style} cursor-pointer`}>Import captions…<input aria-label="Import lyrics captions" type="file" accept=".srt,.vtt" className="sr-only" disabled={disabled} onChange={(event) => { void importFile(event.target.files?.[0]); event.target.value = ""; }} /></label>
    </div>
    {tracks.length > 0 ? <label className="block text-sm">Lyrics language <select aria-label="Lyrics language" className={style} value={selection} onChange={(event) => setSelected(event.target.value)}>
      <option value="off">Off</option>{tracks.map((track) => <option key={track.language} value={track.language}>{track.language}</option>)}
    </select></label> : null}
    <div className="rounded-xl bg-elevated p-4">
      <p className="min-h-12 whitespace-pre-line text-center text-lg" data-testid="music-caption">{lyricTextAt(selectedTrack, time + (previewUrl && !stagedAudio ? previewStart : 0))}</p>
      {audioUrl ? <audio ref={audio} key={audioUrl} src={audioUrl} controls autoPlay className="mt-3 w-full" onTimeUpdate={(event) => setTime(event.currentTarget.currentTime)} onSeeked={(event) => setTime(event.currentTarget.currentTime)} onError={() => { setError("Could not play this audio. Load it again to retry."); setAudioUrl(undefined); }} /> : null}
      <button type="button" className={`${style} mt-3`} disabled={loading || (!itemId && !stagedAudio && !previewUrl)} onClick={() => void prepareAudio()}>{loading ? "Loading…" : audioUrl ? "Reload audio" : "Play music preview"}</button>
    </div>
    {error ? <p role="alert" className="text-sm text-red-400">{error}</p> : null}
  </section>;
}
