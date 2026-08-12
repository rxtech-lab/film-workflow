import Image from "next/image";

/**
 * One feature, staged. Each reel pins to the frame and plays three beats on
 * its own view timeline: the screenshot, then a diagram in the language of the
 * trailer, then the whole thing is carried off. No JS — the section's own
 * scroll progress drives every step.
 */
export type Reel = {
  no: string;
  slate: string;
  title: string;
  line: string;
  src: string;
  alt: string;
  w: number;
  h: number;
  portrait?: boolean;
  panel: string;
  diagram: DiagramKind;
};

export type DiagramKind =
  | "music"
  | "voice"
  | "caption"
  | "image"
  | "render"
  | "agent";

/** Stagger classes — the diagram builds itself piece by piece as you scroll. */
const STEP = [
  "step-0",
  "step-1",
  "step-2",
  "step-3",
  "step-4",
  "step-5",
] as const;

export function ReelStage({ reel }: { reel: Reel }) {
  return (
    <section className="stage-track relative h-[300vh]">
      {/* pt clears the fixed top scrim; the picture is sized off the viewport
          height below so the whole beat always fits the frame. */}
      <div className="sticky top-0 flex h-screen items-center overflow-hidden px-6 pt-16 pb-8">
        <div className="stage-out mx-auto w-full max-w-5xl">
          <div className="flex items-baseline gap-4 sm:gap-6">
            <span className="font-mono text-sm text-accent tabular-nums">
              {reel.no}
            </span>
            <span className="font-mono text-[11px] tracking-[0.28em] text-muted uppercase">
              {reel.slate}
            </span>
            <span className="wipe h-px flex-1 bg-line" />
          </div>

          <div className="mt-4 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <h2 className="text-3xl font-semibold tracking-[-0.03em] sm:text-4xl">
              {reel.title}
            </h2>
            <p className="max-w-sm text-sm text-muted sm:text-right">
              {reel.line}
            </p>
          </div>

          {/* The picture: screenshot first, diagram second, in the same box. */}
          <div
            className="relative mx-auto mt-6"
            style={{
              maxWidth: `calc((100svh - 15rem) * ${(reel.w / reel.h).toFixed(3)})`,
            }}
          >
            <div className="stage-shot">
              <Plate src={reel.src} alt={reel.alt} w={reel.w} h={reel.h} />
            </div>

            <div
              aria-hidden="true"
              className="stage-diagram absolute inset-0 p-1.5 sm:p-2.5"
            >
              <Panel label={reel.panel} kind={reel.diagram} />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

export function Plate({
  src,
  alt,
  w,
  h,
}: {
  src: string;
  alt: string;
  w: number;
  h: number;
}) {
  return (
    <div className="relative">
      {/* Backdrop — a soft pool of light behind the window */}
      <div
        aria-hidden="true"
        className="absolute -inset-x-8 -inset-y-6 -z-10 rounded-[2rem] bg-[radial-gradient(60%_60%_at_50%_0%,rgba(255,176,32,0.10),transparent_70%),radial-gradient(70%_70%_at_50%_100%,rgba(90,130,255,0.08),transparent_70%)] blur-2xl"
      />
      <div className="rounded-2xl bg-gradient-to-b from-white/[0.07] to-white/[0.015] p-1.5 ring-1 ring-white/[0.06] sm:p-2.5">
        <div className="overflow-hidden rounded-xl border border-line/80 bg-surface shadow-[0_40px_100px_-30px_rgba(0,0,0,0.95)]">
          <Image
            src={src}
            alt={alt}
            width={w}
            height={h}
            sizes="(max-width: 768px) 100vw, 1024px"
            className="w-full"
          />
        </div>
      </div>
    </div>
  );
}

/** The diagram's housing — cut from the same stock as the trailer. */
function Panel({ label, kind }: { label: string; kind: DiagramKind }) {
  return (
    <div className="relative h-full w-full overflow-hidden rounded-xl border border-line/80 bg-[#06070a] shadow-[0_40px_100px_-30px_rgba(0,0,0,0.95)]">
      {/* Warm key from the left, cool fill from the right — the trailer's light */}
      <div className="absolute inset-0 bg-[radial-gradient(60%_75%_at_12%_40%,rgba(255,176,32,0.16),transparent_70%),radial-gradient(55%_70%_at_88%_60%,rgba(72,110,220,0.16),transparent_70%)]" />
      <div className="absolute inset-0 bg-[linear-gradient(to_right,#fff_1px,transparent_1px),linear-gradient(to_bottom,#fff_1px,transparent_1px)] bg-[size:64px_64px] opacity-[0.045]" />
      <div className="absolute inset-0 bg-[repeating-linear-gradient(to_bottom,rgba(255,255,255,0.02)_0px,rgba(255,255,255,0.02)_1px,transparent_1px,transparent_3px)]" />

      {/* Film edges */}
      <div className="sprockets absolute inset-y-0 left-[6px] w-2 opacity-70" />
      <div className="sprockets absolute inset-y-0 right-[6px] w-2 opacity-70" />

      {/* Slate */}
      <div className="absolute inset-x-8 top-3 flex items-center justify-between font-mono text-[9px] tracking-[0.26em] text-muted/70 uppercase sm:text-[10px]">
        <span>{label}</span>
        <span className="tabular-nums">00:00:0{label.length % 8}:12</span>
      </div>
      <div className="absolute inset-x-8 bottom-3 flex items-center justify-between font-mono text-[9px] tracking-[0.26em] text-muted/45 uppercase">
        <span>Reel</span>
        <span className="tabular-nums">3840 × 2160 · 60 FPS</span>
      </div>

      <div className="absolute inset-x-8 top-10 bottom-10">
        <Diagram kind={kind} />
      </div>
    </div>
  );
}

function Diagram({ kind }: { kind: DiagramKind }) {
  switch (kind) {
    case "music":
      return <MusicDiagram />;
    case "voice":
      return <VoiceDiagram />;
    case "caption":
      return <CaptionDiagram />;
    case "image":
      return <ImageDiagram />;
    case "render":
      return <RenderDiagram />;
    case "agent":
      return <AgentDiagram />;
  }
}

/* ── Diagrams ───────────────────────────────────────────── */

const CUES = [
  { label: "Intro", h: 24 },
  { label: "Build", h: 48 },
  { label: "Verse", h: 60 },
  { label: "Chorus", h: 88 },
  { label: "Outro", h: 30 },
];

function MusicDiagram() {
  return (
    <div className="flex h-full flex-col justify-end gap-4">
      <div className="flex flex-1 items-end gap-2 sm:gap-4">
        {CUES.map((cue, i) => (
          <div key={cue.label} className="flex h-full flex-1 flex-col justify-end gap-2">
            <div
              className={`d-grow ${STEP[i]} w-full rounded-md bg-gradient-to-t from-accent/25 to-accent/80 ring-1 ring-accent/30`}
              style={{ height: `${cue.h}%` }}
            />
            <span className="text-center font-mono text-[8px] tracking-[0.2em] text-muted uppercase sm:text-[9px]">
              {cue.label}
            </span>
          </div>
        ))}
      </div>

      {/* The take, drawn as it renders */}
      <div className="relative h-8">
        <div className="d-sweep absolute inset-0">
          <span className="absolute inset-y-0 left-0 w-px bg-accent/80" />
        </div>
        <div className="flex h-full items-end gap-[3px]">
          {WAVE.map((v, i) => (
            <span
              key={i}
              className={`d-grow ${STEP[i % 6]} flex-1 rounded-[1px] bg-accent/45`}
              style={{ height: `${v}%` }}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

const WAVE = [
  18, 34, 52, 78, 96, 70, 44, 30, 22, 38, 62, 88, 74, 50, 36, 26, 20, 32, 48,
  66, 84, 60, 42, 28,
];

const SPEAKERS = [
  { name: "Narrator", tone: "accent" },
  { name: "Guest 01", tone: "cool" },
  { name: "Guest 02", tone: "muted" },
];

function VoiceDiagram() {
  return (
    <div className="flex h-full flex-col justify-center gap-5">
      {SPEAKERS.map((speaker, i) => (
        <div key={speaker.name} className={`d-rise ${STEP[i]} flex items-center gap-4`}>
          <span className="w-20 shrink-0 font-mono text-[9px] tracking-[0.2em] text-muted uppercase sm:text-[10px]">
            {speaker.name}
          </span>
          <span
            className={`h-1.5 w-1.5 shrink-0 rounded-full ${
              speaker.tone === "accent"
                ? "bg-accent"
                : speaker.tone === "cool"
                  ? "bg-[#6f92ff]"
                  : "bg-muted"
            }`}
          />
          <div className="flex h-7 flex-1 items-center gap-[3px]">
            {WAVE.slice(0, 20).map((v, j) => (
              <span
                key={j}
                className={`flex-1 rounded-[1px] ${
                  speaker.tone === "accent"
                    ? "bg-accent/60"
                    : speaker.tone === "cool"
                      ? "bg-[#6f92ff]/55"
                      : "bg-muted/40"
                }`}
                style={{ height: `${((v + j * 7) % 80) + 15}%` }}
              />
            ))}
          </div>
          <span className="font-mono text-[9px] text-muted/60 tabular-nums">
            0{i + 1}:{i * 7 + 12}
          </span>
        </div>
      ))}
    </div>
  );
}

const LINES = [
  { tc: "00:00:02:04", en: "We open on a quiet room.", xx: "我们从一个安静的房间开始。" },
  { tc: "00:00:05:16", en: "The reel is already running.", xx: "胶片已经在转动。" },
  { tc: "00:00:09:02", en: "Nothing leaves this window.", xx: "一切都在这一个窗口里。" },
];

function CaptionDiagram() {
  return (
    <div className="flex h-full flex-col justify-center gap-4">
      {LINES.map((line, i) => (
        <div key={line.tc} className={`d-rise ${STEP[i]} flex items-start gap-4`}>
          <span className="shrink-0 pt-[3px] font-mono text-[9px] text-accent/80 tabular-nums sm:text-[10px]">
            {line.tc}
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-xs text-fg/85 sm:text-sm">{line.en}</p>
            <p className={`d-rise ${STEP[i + 2]} truncate text-[10px] text-muted sm:text-xs`}>
              {line.xx}
            </p>
          </div>
          <span className="shrink-0 rounded-full border border-line px-2 py-[2px] font-mono text-[8px] tracking-[0.18em] text-muted uppercase">
            {i === 2 ? "SRT" : "VTT"}
          </span>
        </div>
      ))}
    </div>
  );
}

function ImageDiagram() {
  return (
    <div className="grid h-full grid-cols-3 grid-rows-2 gap-3">
      {[0, 1, 2, 3, 4, 5].map((i) => (
        <div
          key={i}
          className={`d-resolve ${STEP[i]} relative overflow-hidden rounded-lg border border-line/70`}
        >
          <div
            className={`absolute inset-0 ${
              i % 3 === 0
                ? "bg-[radial-gradient(80%_80%_at_30%_20%,rgba(255,176,32,0.35),transparent_70%)]"
                : i % 3 === 1
                  ? "bg-[radial-gradient(80%_80%_at_70%_30%,rgba(111,146,255,0.32),transparent_70%)]"
                  : "bg-[radial-gradient(80%_80%_at_50%_80%,rgba(255,255,255,0.14),transparent_70%)]"
            }`}
          />
          <span className="absolute bottom-1.5 left-2 font-mono text-[8px] tracking-[0.2em] text-muted/70 uppercase">
            0{i + 1}
          </span>
        </div>
      ))}
    </div>
  );
}

const TRACKS = [
  { name: "Video", clips: [30, 44, 22], tone: "bg-accent/45" },
  { name: "Voice", clips: [22, 30, 42], tone: "bg-[#6f92ff]/45" },
  { name: "Score", clips: [52, 24, 20], tone: "bg-white/15" },
];

function RenderDiagram() {
  return (
    <div className="relative flex h-full flex-col justify-center gap-3">
      {TRACKS.map((track, i) => (
        <div key={track.name} className={`d-rise ${STEP[i]} flex items-center gap-4`}>
          <span className="w-14 shrink-0 font-mono text-[9px] tracking-[0.2em] text-muted uppercase sm:text-[10px]">
            {track.name}
          </span>
          <div className="flex h-8 flex-1 gap-2">
            {track.clips.map((width, j) => (
              <span
                key={j}
                className={`rounded-md ring-1 ring-white/10 ${track.tone}`}
                style={{ width: `${width}%` }}
              />
            ))}
          </div>
        </div>
      ))}

      {/* Playhead, running the length of the timeline */}
      <div className="pointer-events-none absolute inset-y-0 right-0 left-[76px]">
        <div className="d-sweep absolute inset-0">
          <span className="absolute inset-y-0 left-0 w-px bg-accent shadow-[0_0_12px_rgba(255,176,32,0.8)]" />
        </div>
      </div>
    </div>
  );
}

const EDITS = [
  { file: "Scene01.tsx", change: "+ fade in on the wide" },
  { file: "captions.vtt", change: "~ retime 14 lines" },
  { file: "score.mp3", change: "+ swap chorus take" },
];

function AgentDiagram() {
  return (
    <div className="flex h-full flex-col justify-center gap-3">
      {EDITS.map((edit, i) => (
        <div
          key={edit.file}
          className={`d-rise ${STEP[i]} flex items-center gap-3 rounded-lg border border-line/70 bg-white/[0.02] px-3 py-2.5`}
        >
          <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
          <span className="shrink-0 font-mono text-[9px] tracking-[0.14em] text-fg/80 sm:text-[10px]">
            {edit.file}
          </span>
          <span className="min-w-0 flex-1 truncate font-mono text-[9px] text-muted sm:text-[10px]">
            {edit.change}
          </span>
          <span
            className={`d-rise ${STEP[i + 3]} shrink-0 rounded-full border border-accent/40 px-2 py-[2px] font-mono text-[8px] tracking-[0.18em] text-accent uppercase`}
          >
            Review
          </span>
        </div>
      ))}
    </div>
  );
}
