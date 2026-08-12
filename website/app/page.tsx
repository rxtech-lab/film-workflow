import HeroVideo from "./hero-video";
import { ReelStage, type Reel } from "./reel-stage";
import { getLatestRelease } from "./lib/release";

const REELS: Reel[] = [
  {
    no: "01",
    slate: "Music",
    title: "Score it.",
    line: "Generate cues with Lyria. Keep every take in one reel.",
    src: "/images/projects.webp",
    alt: "The music workspace, with takes stacked in one reel",
    w: 2245,
    h: 1218,
    panel: "Music — Lyria",
    diagram: "music",
  },
  {
    no: "02",
    slate: "Narrative",
    title: "Voice it.",
    line: "Multi-speaker narration, tuned line by line.",
    src: "/images/narrative.webp",
    alt: "Multi-speaker narration being tuned line by line",
    w: 2286,
    h: 1244,
    panel: "Narrative — Voices",
    diagram: "voice",
  },
  {
    no: "03",
    slate: "Caption",
    title: "Subtitle it.",
    line: "Transcribe, translate, retime. Export VTT or SRT.",
    src: "/images/caption.webp",
    alt: "Captions being transcribed, translated and retimed",
    w: 1976,
    h: 1145,
    panel: "Caption — Transcript",
    diagram: "caption",
  },
  {
    no: "04",
    slate: "Image",
    title: "Frame it.",
    line: "Stills and reference art without leaving the app.",
    src: "/images/image.webp",
    alt: "Stills and reference art generated inside the app",
    w: 2339,
    h: 1268,
    panel: "Image — Stills",
    diagram: "image",
  },
  {
    no: "05",
    slate: "Remotion",
    title: "Render it.",
    line: "A real timeline. 4K, 60 fps, straight out of the app.",
    src: "/images/remotion.webp",
    alt: "A Remotion composition with a live 4K preview and timeline",
    w: 2306,
    h: 1260,
    panel: "Remotion — Timeline",
    diagram: "render",
  },
  {
    no: "06",
    slate: "Agent",
    title: "Direct it.",
    line: "Ask for a change. Review every edit before it lands.",
    src: "/images/agent.webp",
    alt: "The agent panel proposing caption edits for review",
    w: 1070,
    h: 1508,
    portrait: true,
    panel: "Agent — Proposals",
    diagram: "agent",
  },
];

export default async function Home() {
  const release = await getLatestRelease();

  return (
    <main className="grain relative">
      <Backdrop />
      <Rails />
      <Reel />
      <Nav release={release} />

      {/*
        ── Hero ──────────────────────────────────────────────
        A tall track with a pinned stage inside it. The title starts alone in
        the middle of the frame; scrolling opens the second line, then the
        call to action, all on the document scroll timeline.
      */}
      <section className="hero-track relative h-[340vh]">
        <div className="sticky top-0 flex h-screen flex-col items-center justify-center overflow-hidden px-6 text-center">
          {/* The trailer, playing behind the title for as long as the page moves */}
          <div aria-hidden="true" className="hero-reel absolute inset-0 -z-10">
            <HeroVideo />
            <div className="absolute inset-0 bg-ink/45" />
            <div className="absolute inset-0 bg-[radial-gradient(115%_85%_at_50%_45%,transparent_35%,rgba(4,5,6,0.85)_100%)]" />
          </div>

          <p className="rise absolute top-28 font-mono text-[11px] tracking-[0.32em] text-muted uppercase sm:top-32">
            Take 01 — Native macOS
          </p>

          <h1 className="text-5xl leading-[0.95] font-semibold tracking-[-0.04em] text-balance sm:text-7xl md:text-8xl">
            <span className="rise block">Your film studio,</span>

            {/* Collapsed to nothing until the page moves */}
            <span className="hero-open grid grid-rows-[1fr]">
              <span className="block overflow-hidden">
                <span className="hero-line-2 block pt-[0.08em] text-accent">
                  in one window.
                </span>
              </span>
            </span>
          </h1>

          <div className="hero-open-late grid w-full grid-rows-[1fr]">
            <div className="overflow-hidden">
              <div className="hero-cta flex flex-col items-center">
                <p className="mx-auto mt-8 max-w-xl text-lg text-balance text-muted sm:text-xl">
                  Score, narrate, caption, and render — with an agent sitting in
                  the director&rsquo;s chair.
                </p>

                <div className="mt-10 flex flex-col items-center gap-4">
                  <DownloadButton release={release} />
                  <p className="font-mono text-[11px] tracking-[0.14em] text-muted uppercase">
                    RxFilmStudio.dmg · {release.size} · {release.date}
                  </p>
                </div>
              </div>
            </div>
          </div>

          <div
            aria-hidden="true"
            className="scroll-hint absolute bottom-14 flex flex-col items-center gap-3"
          >
            <span className="font-mono text-[10px] tracking-[0.34em] text-muted uppercase">
              Scroll
            </span>
            <span className="h-10 w-px bg-gradient-to-b from-line to-transparent" />
          </div>
        </div>
      </section>

      <Perforation />

      {/* ── Reels — each one pins, plays, and clears the frame ── */}
      {REELS.map((reel) => (
        <ReelStage key={reel.no} reel={reel} />
      ))}

      <Perforation />

      {/* ── End card — dead centre of its own frame ──────────── */}
      <section className="flex min-h-screen flex-col items-center justify-center px-6 py-24 text-center">
        <h2 className="text-4xl font-semibold tracking-[-0.04em] text-balance sm:text-6xl">
          Roll camera.
        </h2>
        <div className="mt-10 flex flex-col items-center gap-4">
          <DownloadButton release={release} />
          <p className="font-mono text-[11px] tracking-[0.14em] text-muted uppercase">
            macOS · Apple Silicon · Free
          </p>
        </div>
      </section>

      <Footer release={release} />
    </main>
  );
}

/* ── Pieces ─────────────────────────────────────────────── */

/*
 * The top bar is a scrim rather than a plate — a hard bottom edge would cut a
 * line straight across the trailer while it plays full-bleed.
 */
function Nav({ release }: { release: Awaited<ReturnType<typeof getLatestRelease>> }) {
  return (
    <header className="nav-reveal fixed inset-x-0 top-0 z-50 bg-gradient-to-b from-ink/95 via-ink/70 to-transparent pb-6">
      <nav className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
        <a href="#" className="flex items-center gap-3">
          <Mark />
          <span className="font-mono text-[11px] tracking-[0.26em] uppercase">
            RxFilm<span className="text-muted">Studio</span>
          </span>
        </a>

        <div className="flex items-center gap-3 sm:gap-5">
          <a
            href={release.url}
            target="_blank"
            rel="noreferrer"
            className="rounded-full border border-line px-3 py-1 font-mono text-[11px] tracking-[0.14em] text-muted transition-colors hover:border-accent hover:text-accent"
          >
            v{release.version}
          </a>
          <a
            href={release.dmgUrl}
            className="rounded-full bg-fg px-4 py-1.5 text-sm font-medium text-ink transition-opacity hover:opacity-80"
          >
            Download
          </a>
        </div>
      </nav>

      {/* Scroll gauge — driven entirely by the document scroll timeline. */}
      <div
        aria-hidden="true"
        className="progress-bar absolute inset-x-0 bottom-6 h-px bg-accent"
      />
    </header>
  );
}

function DownloadButton({
  release,
}: {
  release: Awaited<ReturnType<typeof getLatestRelease>>;
}) {
  return (
    <a
      href={release.dmgUrl}
      className="group inline-flex items-center gap-3 rounded-full bg-accent px-7 py-3.5 text-base font-medium text-ink transition-transform hover:scale-[1.03] active:scale-100"
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 16 16"
        fill="none"
        aria-hidden="true"
      >
        <path
          d="M8 1v9m0 0 3.5-3.5M8 10 4.5 6.5M2 12.5v1A1.5 1.5 0 0 0 3.5 15h9a1.5 1.5 0 0 0 1.5-1.5v-1"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
      Download for macOS
      <span className="font-mono text-xs opacity-60">v{release.version}</span>
    </a>
  );
}

function Perforation() {
  return (
    <div
      aria-hidden="true"
      className="mx-auto flex h-8 max-w-6xl items-center gap-3 px-6 opacity-40"
    >
      <span className="h-px flex-1 bg-line" />
      {[0, 1, 2].map((i) => (
        <span key={i} className="h-1.5 w-3 rounded-[2px] bg-line" />
      ))}
      <span className="h-px flex-1 bg-line" />
    </div>
  );
}

/**
 * Page backdrop — a lit projection room. Every layer is decorative and driven
 * by the document scroll timeline, so it moves without a single line of JS.
 */
function Backdrop() {
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none fixed inset-0 -z-10 overflow-hidden"
    >
      {/* Projector shafts raking across the room */}
      <div className="bg-beam absolute -top-[30%] left-[8%] h-[170vh] w-[26vw] -skew-x-12 bg-[linear-gradient(to_bottom,rgba(255,176,32,0.22),rgba(255,176,32,0.06)_45%,transparent_80%)] blur-3xl" />
      <div className="bg-beam-2 absolute -top-[30%] right-[6%] h-[170vh] w-[18vw] skew-x-12 bg-[linear-gradient(to_bottom,rgba(120,150,255,0.20),rgba(120,150,255,0.05)_50%,transparent_82%)] blur-3xl" />

      {/* Two pools of colour drifting against each other */}
      <div className="bg-glow-a absolute -left-[15%] top-[6%] h-[75vh] w-[75vw] rounded-full bg-[radial-gradient(circle,rgba(255,176,32,0.28),transparent_62%)] blur-3xl" />
      <div className="bg-glow-b absolute -right-[12%] top-[38%] h-[70vh] w-[65vw] rounded-full bg-[radial-gradient(circle,rgba(72,110,220,0.26),transparent_62%)] blur-3xl" />

      {/* Frame grid, panning slowly */}
      <div className="bg-grid absolute inset-x-0 -inset-y-1/3 opacity-[0.06] bg-[linear-gradient(to_right,#fff_1px,transparent_1px),linear-gradient(to_bottom,#fff_1px,transparent_1px)] bg-[size:110px_110px] [mask-image:radial-gradient(95%_75%_at_50%_35%,#000,transparent_78%)]" />

      {/* Loose frames tumbling through the room */}
      <div className="bg-frames absolute inset-0 hidden lg:block">
        <span className="absolute left-[6%] top-[14%] block h-24 w-40 rounded-md border border-white/[0.07]" />
        <span className="absolute left-[78%] top-[8%] block h-20 w-32 rotate-12 rounded-md border border-accent/[0.14]" />
        <span className="absolute left-[86%] top-[62%] block h-28 w-44 -rotate-6 rounded-md border border-white/[0.06]" />
        <span className="absolute left-[12%] top-[72%] block h-16 w-28 rotate-6 rounded-md border border-accent/[0.10]" />
        <span className="absolute left-[46%] top-[86%] block h-20 w-32 -rotate-12 rounded-md border border-white/[0.05]" />
      </div>

      {/* Dust in the beam */}
      <div className="bg-dust absolute inset-x-0 -inset-y-1/2 opacity-40 bg-[radial-gradient(1.5px_1.5px_at_18%_12%,rgba(255,255,255,0.8),transparent),radial-gradient(1.5px_1.5px_at_72%_28%,rgba(255,255,255,0.6),transparent),radial-gradient(1px_1px_at_38%_62%,rgba(255,255,255,0.7),transparent),radial-gradient(1.5px_1.5px_at_88%_74%,rgba(255,255,255,0.5),transparent),radial-gradient(1px_1px_at_8%_84%,rgba(255,255,255,0.6),transparent),radial-gradient(1px_1px_at_57%_92%,rgba(255,255,255,0.5),transparent)] bg-[size:460px_460px]" />

      {/* Scan lines + vignette hold everything down */}
      <div className="absolute inset-0 bg-[repeating-linear-gradient(to_bottom,rgba(255,255,255,0.02)_0px,rgba(255,255,255,0.02)_1px,transparent_1px,transparent_4px)]" />
      <div className="absolute inset-0 bg-[radial-gradient(125%_95%_at_50%_45%,transparent_40%,rgba(4,5,6,0.85)_100%)]" />
    </div>
  );
}

/** Film strips running down both page edges — they travel as you scroll. */
function Rails() {
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none fixed inset-y-0 z-0 hidden w-full lg:block"
    >
      <div className="absolute inset-y-0 left-5 w-7 border-x border-line/50 bg-white/[0.012]">
        <div className="sprockets sprockets-run absolute inset-y-0 left-1/2 w-3 -translate-x-1/2" />
      </div>
      <div className="absolute inset-y-0 right-5 w-7 border-x border-line/50 bg-white/[0.012]">
        <div className="sprockets sprockets-run absolute inset-y-0 left-1/2 w-3 -translate-x-1/2" />
      </div>
    </div>
  );
}

/** Projector reel in the corner — it turns as the film runs. */
function Reel() {
  const holes = [0, 72, 144, 216, 288];
  return (
    <div className="pointer-events-none fixed bottom-8 left-14 z-40 hidden lg:block">
      <svg
        viewBox="0 0 48 48"
        className="reel-spin h-10 w-10 text-muted/50"
        aria-hidden="true"
      >
        <circle
          cx="24"
          cy="24"
          r="21"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
        />
        <circle cx="24" cy="24" r="3.4" fill="currentColor" />
        {holes.map((deg) => (
          <circle
            key={deg}
            cx="24"
            cy="10.5"
            r="4.6"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.4"
            transform={`rotate(${deg} 24 24)`}
          />
        ))}
      </svg>
    </div>
  );
}

function Mark() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <rect
        x="1"
        y="1"
        width="16"
        height="16"
        rx="3.5"
        stroke="currentColor"
        strokeWidth="1.4"
        fill="none"
      />
      <rect x="4" y="4.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="4" y="11.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="12" y="4.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="12" y="11.5" width="2" height="2" rx="0.5" fill="#ffb020" />
      <rect x="7.5" y="7.5" width="3" height="3" rx="0.5" fill="currentColor" />
    </svg>
  );
}

function Footer({
  release,
}: {
  release: Awaited<ReturnType<typeof getLatestRelease>>;
}) {
  return (
    <footer className="border-t border-line px-6 py-10">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-5 font-mono text-[11px] tracking-[0.14em] text-muted uppercase sm:flex-row">
        <div className="flex items-center gap-3">
          <Mark />
          <span>RxFilmStudio</span>
        </div>
        <div className="flex items-center gap-6">
          <a
            href="https://github.com/rxtech-lab/film-workflow"
            target="_blank"
            rel="noreferrer"
            className="transition-colors hover:text-fg"
          >
            GitHub
          </a>
          <a
            href={release.url}
            target="_blank"
            rel="noreferrer"
            className="transition-colors hover:text-fg"
          >
            Releases
          </a>
          <span>RxLab</span>
        </div>
      </div>
    </footer>
  );
}
