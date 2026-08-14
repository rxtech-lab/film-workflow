# Video Conversion (FFmpeg) — Design Plan

## Context

`film-workflow` can generate music, narration, images, captions, and Remotion compositions, but its only
video output is a single `video.mp4` from `RemotionRenderer.render(...)` at one fixed size (`views/remotion/RemotionTabView.swift:407`).
There is no way to bring an arbitrary video into the app, no way to produce several deliverables from one
source (YouTube master + vertical Reel + ProRes), and — despite a full caption pipeline with word timings and
per-language translations (`models/CaptionSegment.swift`, `models/CaptionTranslation.swift`) — **no path from a caption
project onto a video**. `grep` for `subtitles`/`overlay` in `views/remotion/` finds only `.font(.caption)`.

This adds a **Convert** workflow: import videos, define multiple output presets per project, enqueue the
cross-product, and write the results to a chosen folder — optionally burning in or muxing captions (with
translations) picked from an existing Caption project, encoded through VideoToolbox.

### Decisions already locked in

1. **Bundle our own ffmpeg.** Remotion's embedded ffmpeg (`RemotionRuntime/template/node_modules/@remotion/compositor-darwin-arm64/ffmpeg`)
   is built `--disable-filters --disable-encoders --disable-muxers` with a narrow allowlist: *no* `ass`/`subtitles`/`overlay`/`drawtext`
   filter, *no* subtitle encoder, *no* subtitle demuxer. It can neither burn in nor mux subtitles, so it is
   unusable here even though it is already on disk. We ship a second, full binary.
2. **VideoToolbox + permissively-licensed encoders only** — no `libx264`/`libx265`, therefore no GPL obligation.
   `h264_videotoolbox` / `hevc_videotoolbox` / `prores_videotoolbox` cover the hardware requirement; `libvpx`,
   `libaom`, `libdav1d`, `libopus`, `libmp3lame`, and AudioToolbox AAC cover the rest. Consequence: *no CRF* —
   rate control is bitrate or VideoToolbox's `-q:v` quality scale.
3. **A new `Convert` tab with its own `GroupableProject`**, mirroring the five existing tabs exactly
   (`views/music/MusicTabView.swift` is the cleanest reference). macOS-only, like Remotion.
4. **One app-wide serial queue, persisted in SwiftData.** Survives relaunch, one ffmpeg at a time, cancel/retry per job.
5. **Videos are referenced, never copied.** Everything else in the app is copied into Application Support
   (`utils/FileStorage.swift`), but a 4K master is 20 GB. Inputs store a security-scoped bookmark plus a path.

### Architecture

```
 ┌──────────────────────── views/convert/ ────────────────────────┐
 │ ConvertTabView  ─ Inputs │ Presets │ Subtitles │ Output        │
 │                                    ConvertQueueView (sheet)    │
 └──────────────┬─────────────────────────────────┬───────────────┘
                │ enqueue                         │ observes
   ┌────────────▼──────────────┐      ┌───────────▼──────────────┐
   │ ConversionJobPlanner      │      │ ConversionQueue.shared   │
   │ inputs × presets × langs  │─────▶│ @Observable, serial pump │
   │ → [ConversionJob] (pure)  │      │ persists state each step │
   └───────────────────────────┘      └───────────┬──────────────┘
                                                  │ one at a time
   ┌──────────────────────────────────────────────▼──────────────┐
   │ ConversionRunner                                            │
   │  1. FFprobe.probe(input)                → MediaInfo         │
   │  2. CaptionAssRenderer / CaptionExporter → .ass / .srt      │
   │  3. FFmpegCommandBuilder.args(job:)      → [String]  (pure) │
   │  4. FFmpegProcess.run(...)  -progress pipe:1 → fraction     │
   └──────────────────────────────┬──────────────────────────────┘
                                  │ Process
   ┌──────────────────────────────▼──────────────────────────────┐
   │ film-workflow.app/Contents/Resources/FFmpegRuntime/         │
   │   ffmpeg  ffprobe   (universal, LGPL, VideoToolbox+libass)  │
   └─────────────────────────────────────────────────────────────┘
```

---

# Part 1 — The embedded ffmpeg runtime

## 1.1 Building the binary

No trustworthy prebuilt macOS ffmpeg exists that is *both* LGPL and has libass, so we build it once and pin it.

| File | Type |
|---|---|
| `.github/workflows/build-ffmpeg.yaml` | Manually-triggered workflow: builds ffmpeg + deps for `arm64` and `x86_64`, `lipo`s them into universal `ffmpeg`/`ffprobe`, tars them, and publishes as a release asset tagged `ffmpeg-runtime-vN` with a `SHA256SUMS` file. Runs only when the pin is bumped — not per-PR. |
| `scripts/build-ffmpeg-runtime.sh` | Mirrors `scripts/build-remotion-runtime.sh` line for line: pinned `FFMPEG_RUNTIME_VERSION`, idempotent (no-op when `FFmpegRuntime/ffmpeg -version` already matches), `curl -fL --retry 3` the release asset, verify sha256, unpack to `FFmpegRuntime/`, `chmod +x`. Honors `SKIP_FFMPEG_RUNTIME_BUILD=1` and skips when `PLATFORM_NAME != macosx`. |

Configure flags (LGPL — note the absence of `--enable-gpl` and `--enable-nonfree`):

```
--disable-everything --disable-doc --disable-debug --disable-network --disable-ffplay
--enable-videotoolbox --enable-audiotoolbox
--enable-libass --enable-libfreetype --enable-libharfbuzz --enable-libfribidi --disable-fontconfig
--enable-libopus --enable-libmp3lame --enable-libvpx --enable-libaom --enable-libdav1d
--enable-decoder=... --enable-encoder=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox,aac_at,aac,...
--enable-muxer=mp4,mov,matroska,webm,gif,mp3,ipod,image2  --enable-demuxer=...,srt,webvtt,ass
--enable-encoder=mov_text,srt,webvtt,ass  --enable-filter=scale,ass,subtitles,format,fps,crop,pad,overlay,palettegen,paletteuse,volume,aresample,atrim,trim
--pkg-config-flags=--static
```

`--disable-fontconfig` is deliberate: libass then uses its **CoreText** font provider, so `\fn Helvetica Neue`
resolves against installed macOS fonts with no font cache to ship or warm.

## 1.2 Bundling and signing

`FFmpegRuntime/` is added to the Xcode target as a **folder reference** in *Copy Bundle Resources*, exactly like
`RemotionRuntime` (`film-workflow.xcodeproj/project.pbxproj:41,248`). Two build-phase changes:

- Pre-build phase: append `bash "$SRCROOT/scripts/build-ffmpeg-runtime.sh"` next to the existing Remotion runtime phase.
- **Generalize `scripts/sign-remotion-runtime.sh` to take the runtime directory as `$1`** (default preserved for
  back-compat) and rename the phase to *"Sign Embedded Runtimes"*, invoking it twice — once per runtime. The
  existing script already does exactly the right thing: Mach-O magic-byte detection, `codesign --force --options runtime`,
  entitlements only for executables, `--timestamp=none` in Debug. ffmpeg/ffprobe are plain executables and need
  **no** entitlements file (unlike Bun, they don't JIT), so pass an empty entitlements argument.
- `.gitignore` gets `FFmpegRuntime/` (the Remotion runtime is likewise not committed).

No entitlement work: `film-workflow/film-workflow.entitlements` already sets `com.apple.security.app-sandbox = false`
on macOS with `disable-library-validation`, which is why spawning Bun works today.

## 1.3 Swift wrappers

Unlike Bun, ffmpeg is a static binary that never writes beside itself, so it **runs in place from the app bundle** —
no copy-out step like `RemotionRuntime.ensureRuntimeInstalled()`.

| File | Type |
|---|---|
| `clients/ffmpeg/FFmpegRuntime.swift` | `enum FFmpegRuntime { static var ffmpegURL: URL?; static var ffprobeURL: URL?; static func ensureAvailable() throws }` — resolves `Bundle.main.resourceURL/FFmpegRuntime/…`, `isExecutableFile` check, throws a `LocalizedError` naming the missing binary. |
| `clients/ffmpeg/MediaInfo.swift` | `nonisolated struct MediaInfo: Sendable` — `durationMs`, `width`, `height`, `fps: Double`, `rotationDegrees`, `videoCodec`, `pixelFormat`, `bitRate`, `hasAlpha`, `audioTracks: [AudioTrackInfo]`, `subtitleTracks: [SubtitleTrackInfo]`, plus `displaySize` applying rotation. |
| `clients/ffmpeg/FFprobe.swift` | `@concurrent static func probe(_ url: URL) async throws -> MediaInfo` — `-v quiet -print_format json -show_format -show_streams`, `Codable` decode, `r_frame_rate` `"30000/1001"` → 29.97. |
| `clients/ffmpeg/FFmpegProcess.swift` | Generic runner: launches ffmpeg with `-progress pipe:1 -nostats`, parses `out_time_us=`/`speed=`/`progress=end`, streams `ConversionProgress` through an `onProgress: @MainActor` closure, tees stderr to a per-job log, returns/throws on exit status with `tail(of:lines:40)`. |
| `clients/process/CancellableProcess.swift` | **Refactor, not new code.** `CancellableProcess` and `LineBuffer` are currently `private` inside `clients/RemotionRenderer.swift:138,313`. Move both here unchanged (drop `private`) and have `RemotionRenderer` use them. Their launch/cancel-race and SIGTERM→SIGKILL escalation logic is exactly what ffmpeg needs, and `ProcessTreeKiller` (same file) already stays where it is. |

`ConversionProgress` follows the house shape of `RenderProgress`/`CaptionProgress`:

```swift
nonisolated struct ConversionProgress: Sendable, Equatable {
    enum Stage: String { case preparing, probing, renderingSubtitles, encoding, muxing, finalizing }
    var stage: Stage
    var fraction: Double?      // out_time_us / duration_us; nil ⇒ indeterminate
    var speed: Double?         // ffmpeg's `speed=1.8x`
    var etaSeconds: Int?
    var detail: String?
}
```

---

# Part 2 — Data model

All three models are added to the `Schema` array in `film_workflowApp.swift:7-20` and to the `#Preview` list in
`ContentView.swift`. Every stored property carries a default value — the repo has no migration plan and relies on
additive migration. Cross-entity links to caption data are plain `UUID?`, never `@Relationship`, matching
`GeneratedNarrative.captionProjectID` (`models/GeneratedNarrative.swift`); deleting a caption project must not
cascade into conversion projects. Enums are stored as `String` with computed `…Enum` accessors, per house style.

## 2.1 `models/VideoConvertProject.swift`

```swift
@Model final class VideoConvertProject: GroupableProject {
    var name: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var groupID: UUID? = nil
    var projectUUID: UUID = UUID()

    // Output
    var outputDirectoryPath: String = ""        // absolute; app is unsandboxed on macOS
    var outputDirectoryBookmark: Data? = nil    // resolved first; survives folder moves
    var outputNameTemplate: String = "{input}-{preset}{-lang}"
    var conflictPolicy: String = ConversionConflictPolicy.uniquify.rawValue

    // Presets are value types, like SongStructureEntry / NarrativeSpeaker
    var presets: [ConversionPreset] = []

    // Project-level subtitle defaults; each input may override
    var defaultCaptionProjectUUID: UUID? = nil

    @Relationship(deleteRule: .cascade, inverse: \ConversionInput.project) var inputs: [ConversionInput] = []
    @Relationship(deleteRule: .cascade, inverse: \ConversionJob.project)   var jobs:   [ConversionJob]   = []
}
```

## 2.2 `models/ConversionInput.swift`

One imported video. `sourceBookmark` is resolved first and refreshed when stale, falling back to `sourcePath`;
this is the app's first use of `bookmarkData` (`grep` confirms zero today) and is what lets a multi-GB file stay put.

Fields: `id`, `orderIndex`, `sourcePath`, `sourceBookmark`, `displayName`, `addedAt`, cached probe results
(`durationMs`, `width`, `height`, `fps`, `videoCodec`, `audioCodec`, `fileSizeBytes`, `probedAt`),
`thumbnailPath: String?` (relative, under a new `FileStorage.videoThumbnailsDir`), and the subtitle binding:
`captionProjectUUID: UUID?`, `captionVersionID: UUID?`, `subtitleOffsetMs: Int = 0`.

## 2.3 `models/ConversionPreset.swift` — embedded `Codable` value type

```swift
nonisolated struct ConversionPreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New preset"
    var isEnabled: Bool = true

    var container: ConversionContainer = .mp4          // mp4 mov mkv webm gif m4a
    var videoCodec: ConversionVideoCodec = .h264VideoToolbox  // + hevcVT, proresVT, vp9, av1, copy, none
    var rateControl: ConversionRateControl = .quality  // quality (-q:v) | bitrate (-b:v)
    var quality: Int = 65                              // VideoToolbox 1…100
    var videoBitrateKbps: Int = 8_000
    var maxWidth: Int = 0                              // 0 ⇒ keep source
    var maxHeight: Int = 1080
    var scaleMode: ConversionScaleMode = .fit          // fit | fill (crop) | pad
    var fpsOverride: Double = 0
    var tenBit: Bool = false

    var audioCodec: ConversionAudioCodec = .aac        // aac opus mp3 copy none
    var audioBitrateKbps: Int = 192
    var channels: Int = 2
    var sampleRate: Int = 48_000

    var subtitleMode: ConversionSubtitleMode = .none   // none | burnIn | softMux | sidecar
    var subtitleLanguages: [String] = []               // BCP-47; empty ⇒ source language only
    var subtitleTranslationMode: String = CaptionExportOptions.TranslationMode.originalOnly.rawValue
    var subtitleStyle: SubtitleBurnStyle = .init()

    var trimStartMs: Int = 0
    var trimEndMs: Int = 0                             // 0 ⇒ to end
    var faststart: Bool = true
    var hardwareAcceleration: ConversionHardwareMode = .auto  // auto | encodeOnly | off
    var extraArgs: String = ""                         // advanced escape hatch, shell-split
}
```

`clients/ffmpeg/ConversionPresetLibrary.swift` supplies the built-in templates offered from an "Add preset ▾" menu:
**YouTube 1080p (H.264)**, **Vertical Reel 1080×1920**, **HEVC 4K (small)**, **ProRes 422 master**, **WebM VP9**,
**Audio only (M4A)**, **GIF preview**.

`SubtitleBurnStyle` (embedded `Codable`): `fontName`, `fontSizePercent` (of output height, so a style is
resolution-independent), `primaryColorHex`, `outlineColorHex`, `outlineWidth`, `shadow`, `backgroundOpacity`,
`alignment` (ASS `\an1…9`), `marginVPercent`, `bold`, `maxRunesPerLine` (feeds the existing rewrap), plus an
optional `secondaryFontSizePercent` for the translation line in bilingual mode.

## 2.4 `models/ConversionJob.swift` — the persisted queue row

`id`, `orderIndex`, `state` (`queued|running|succeeded|failed|cancelled`), `createdAt/startedAt/finishedAt`,
`inputID`, `inputName`, `presetID`, `presetName`, `languageCode`, `outputPath`, `progressFraction`, `speed`,
`etaSeconds`, `errorMessage`, `logTail`, `project`. Names are denormalised so a completed job still reads
correctly after its input or preset is deleted.

## 2.5 Fan-out rule (`clients/services/ConversionJobPlanner.swift`, pure + unit-tested)

```
jobs = inputs × enabledPresets × languageFanOut(preset)

languageFanOut(.burnIn)  = preset.subtitleLanguages (or [""] when empty)   // one language per rendered pixel
languageFanOut(.softMux) = [""]                                            // all languages in one container
languageFanOut(.sidecar) = [""]                                            // all languages as N files beside it
languageFanOut(.none)    = [""]
```

Filenames come from `outputNameTemplate` with `{input}`, `{preset}`, `{lang}`, `{-lang}` (omitted when empty),
`{width}`, `{height}`, `{date}`; collisions resolve per `conflictPolicy`.

---

# Part 3 — Captions onto video

## 3.1 Reuse

`CaptionExporter.render(_:options:)` (`clients/captions/CaptionExporter.swift:139`) already produces SRT/VTT from a
`CaptionTranscriptSnapshot`, honouring `TranslationMode.bilingual`, speaker styles, and `maxRunesPerCue` rewrapping.
It is used **unchanged** for soft-mux and sidecar output. The snapshot is built on the main actor from the caption
project's `activeSegments` — the same hand-off the export sheet performs (`views/caption/CaptionExportSheet.swift`).

## 3.2 New: `clients/captions/CaptionAssRenderer.swift`

Burn-in needs ASS, which the exporter does not emit. This renderer calls
`CaptionExporter.cues(from:options:)` — so rewrapping, speaker prefixes, and translation modes behave *identically*
to every other export path — and then writes:

- `[Script Info]` with `ScriptType: v4.00+`, `WrapStyle: 2`, and `PlayResX/PlayResY` set to the **output**
  resolution, so `fontSizePercent` maps to a real pixel size.
- `[V4+ Styles]` — one `Style:` from `SubtitleBurnStyle`, colours converted to ASS `&HAABBGGRR`.
- `[Events]` — `Dialogue: 0,H:MM:SS.cc,...` (centiseconds, rounded), `\N` between the original and translated line
  in bilingual mode, `{\rSecondary}` sizing for the second line, and escaping of `{`, `}`, `\` and leading spaces.
- `subtitleOffsetMs` applied to every timestamp, clamped at 0.

The `.ass` file is written to `FileStorage.temporaryFileURL(extension: "ass")` per job and deleted afterwards.

## 3.3 ffmpeg wiring (`clients/ffmpeg/FFmpegCommandBuilder.swift`, pure + unit-tested)

**Burn-in** — filter order matters; `scale` must precede `ass` so text is burnt at final resolution and is never resampled:

```
ffmpeg -hide_banner -nostdin -hwaccel videotoolbox -ss <trim> -i <input> -t <dur>
  -map 0:v:0 -map 0:a:0?
  -vf "scale=-2:1080:flags=lanczos,ass='/tmp/…​.ass'"
  -c:v h264_videotoolbox -q:v 65 -profile:v high -tag:v avc1 -allow_sw 1 -pix_fmt yuv420p
  -c:a aac -b:a 192k -ac 2 -ar 48000
  -movflags +faststart -progress pipe:1 -nostats -y <output>
```

**Soft mux** — one subtitle stream per selected language, tagged and dispositioned:

```
-i <input> -i sub.en.srt -i sub.zh.srt
  -map 0:v -map 0:a? -map 1 -map 2
  -c:s mov_text                       # mp4/mov;  srt for mkv;  webvtt for webm
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=zho
  -disposition:s:0 default
```

**Sidecar** — no ffmpeg involvement: `CaptionExporter` writes `<output-basename>.<lang>.srt` beside the video.

**Hardware acceleration.** `-hwaccel videotoolbox` is passed for decode in `.auto`; ffmpeg downloads frames
automatically when a filter needs system memory. `.encodeOnly` drops the decode flag (safer for exotic sources),
`.off` also swaps VideoToolbox encoders for their software equivalents where one exists. `-allow_sw 1` is always
passed to the VT encoders so an unsupported configuration degrades instead of failing. Dimensions are rounded to
even numbers (`scale=-2:…` does this for the free axis); `prores_videotoolbox` is offered only when
`VTIsHardwareDecodeSupported`-style probing succeeds, otherwise the UI marks the preset as software.

**Sanity guard.** When an input's `durationMs` differs from the bound caption project's `audioDurationMs` by more
than 1 s, the Subtitles pane shows an inline warning (the pattern `CaptionProject.warning` already uses) — captions
made from a different cut are the most likely user error, and `subtitleOffsetMs` is the fix.

---

# Part 4 — Queue and UI

## 4.1 `clients/services/ConversionQueue.swift`

`@MainActor @Observable final class ConversionQueue { static let shared }` — same singleton shape as
`RemotionRuntime.shared` / `MCPServer.shared`, bootstrapped from `film_workflowApp`'s `.task` alongside
`MCPServer.shared.bootstrap(container:)`.

- Serial pump: fetch the oldest `queued` job, mark `running`, run `ConversionRunner`, write terminal state back.
- Progress is throttled to ~4 writes/sec and held in memory (`currentProgress`), persisting only on state change —
  SwiftData writes at 30 fps would be pathological.
- **Crash recovery:** on bootstrap, any job still `running` is reset to `queued` and its partial output deleted.
- Cancel current → `Task.cancel()` (the `CancellableProcess` machinery kills the tree); cancel queued → state `cancelled`.
- Holds `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled])` while non-empty
  so a long batch is not throttled or interrupted by sleep.
- `ConversionRunner` (`clients/services/ConversionRunner.swift`) is a `@MainActor enum` façade with a
  `onProgress:` closure — the same signature style as `CaptionTranscriptionService.transcribe(...)` — so the MCP
  server can drive it later without touching views.

## 4.2 Views — `film-workflow/views/convert/`

Structure copied from `views/caption/CaptionTabView.swift`: `NavigationSplitView`, `@Query(sort: \VideoConvertProject.updatedAt, order: .reverse)`,
sidebar via the generic `GroupedProjectSections` + `.projectGroupDialogs(...)` from `views/components/ProjectGroupViews.swift`,
`.publishesAgentTarget(kind:projectUUID:)`, `Form { Section }.formStyle(.grouped)` detail panes.

| File | Type |
|---|---|
| `ConvertTabView.swift` | Split view, pane picker (Inputs / Presets / Subtitles / Output), toolbar: *Add Video…*, *Convert All*, *Queue*. |
| `ConvertInputsView.swift` | `.fileImporter(allowedContentTypes: [.movie, .audiovisualContent])` + `.onDrop(of: [.fileURL])`; rows show an `AVAssetImageGenerator` thumbnail (the app's first video use — audio-only today per `utils/AudioProbe.swift`) with resolution/duration/codec from the cached probe. |
| `ConvertPresetListView.swift` / `ConvertPresetEditorView.swift` | Preset list with enable toggles and an *Add from template ▾* menu; editor Form with container/codec/rate-control/scale/audio sections. Disabled combinations are greyed with an explanation (e.g. ProRes is mov-only; VP9 is webm/mkv-only). |
| `ConvertSubtitleSettingsView.swift` | `@Query` over `CaptionProject` to pick the source; version picker; multi-select of `translatedLanguages`; mode (Off / Burn in / Embed as track / Sidecar file); `CaptionExportOptions.TranslationMode` reuse; style controls with a live ASS-rendered preview frame produced by `ffmpeg -ss … -frames:v 1` into a PNG. |
| `ConvertOutputSettingsView.swift` | Output folder via `NSOpenPanel` — reuse the pattern in `CaptionExportSheet.chooseExportDirectory()` (`:421`) — filename template with a live example, conflict policy. |
| `ConvertQueueView.swift` | Global queue sheet: per-row `ProgressView(value:)`, speed/ETA, Cancel, Retry, *Reveal in Finder*, *Clear finished*. |

`config/Tabs.swift` gains `case Convert` (`systemImage: "film.stack.fill"`, display name "Convert") after `.Remotion`;
`ContentView.swift` gains the matching `Tab` inside the existing `#if os(macOS)` branch. `models/AgentTarget.swift`
gains a `.convert` kind so the agent can be pointed at a conversion project.

## 4.3 Settings

New `config/ConvertSettings.swift` — `@MainActor @Observable final class ConvertSettings { static let shared }` with
the `didSet` + `private enum Keys` UserDefaults idiom used by `config/CaptionSettings.swift`: default output folder,
default preset template set, default hardware mode, auto-start queue on enqueue, reveal-in-Finder on completion.
Surfaced as a fifth pane in `views/settings/SettingsView.swift` via a new `AppNavigation.SettingsSection.convert`.
The same pane hosts a **Third-party licenses** disclosure listing FFmpeg (LGPL-2.1), libass (ISC), FreeType, HarfBuzz,
FriBidi, and a link to the build workflow that produced the binary.

---

# Part 5 — Phasing

1. **Runtime.** `build-ffmpeg.yaml`, `build-ffmpeg-runtime.sh`, generalized signing script, Xcode phases,
   `FFmpegRuntime` + `FFprobe` + `MediaInfo`, `CancellableProcess` extraction. *Done when a debug menu item probes a
   file and prints `MediaInfo`, and a signed archive notarizes.*
2. **Model + planner.** Three `@Model`s, `ConversionPreset`, `ConversionPresetLibrary`, `FFmpegCommandBuilder`,
   `ConversionJobPlanner`, and their tests. No UI.
3. **Convert without subtitles.** `ConvertTabView` (Inputs/Presets/Output), `ConversionQueue`, `ConversionRunner`,
   `ConvertQueueView`. *Done when one video → three presets → three files in a chosen folder, cancellable.*
4. **Subtitles.** `CaptionAssRenderer`, burn-in / soft-mux / sidecar paths, translation and style UI, offset,
   duration-mismatch warning.
5. **Polish.** Thumbnails, style preview frame, settings pane + licenses, MCP handlers
   (`convert_add_input`, `convert_set_preset`, `convert_enqueue`, `convert_queue_status` in
   `clients/mcp/handlers/MCPConvertHandlers.swift`), `Localizable.xcstrings` entries incl. `zh-Hans`.

---

# Part 6 — Verification

**Unit tests** (`film-workflowTests/`, Swift Testing `@Suite`, golden-string style of `CaptionExporterTests.swift`):

- `FFmpegCommandBuilderTests` — burn-in puts `scale` before `ass`; soft-mux emits one `-map`/`-metadata:s:s:N language=`
  per language with correct ISO-639-2 codes; `copy` passthrough emits no `-b:v`; quality vs bitrate mutually exclusive;
  trim placement (`-ss` before `-i`, `-t` after); gif path emits `palettegen`/`paletteuse`; `extraArgs` splitting.
- `CaptionAssRendererTests` — header `PlayResX/Y` follows output size; centisecond rounding; `\N` bilingual joining;
  `{`/`}`/`\` escaping; offset clamping; colour → `&HAABBGGRR`.
- `ConversionJobPlannerTests` — fan-out matrix, name templating incl. `{-lang}` elision, collision uniquifying.
- `FFprobeParserTests` — fixture JSON → `MediaInfo`, `"30000/1001"` → 29.97, rotation metadata.
- `ConversionQueueTests` — in-memory `ModelContainer`; `running` rows reset to `queued` on bootstrap; cancel
  transitions; serial ordering.

**Manual end-to-end** (macOS, `xcodebuild -scheme film-workflow -destination 'platform=macOS' build`, then run):

1. Create a Convert project, drop in a 1080p mp4 → thumbnail, duration, and codec appear.
2. Add *YouTube 1080p* + *Vertical Reel* + *ProRes master*; Convert All → three files; confirm with
   `ffprobe` that codecs are `h264`/`h264`/`prores` and that Activity Monitor shows low CPU (VideoToolbox is doing the work).
3. Bind a Caption project with a `zh-Hans` translation, mode *Burn in*, languages `[en, zh-Hans]`, bilingual →
   two files, `-en` and `-zh-Hans`, with visibly styled subtitles at the right times.
4. Switch to *Embed as track* → one file; `ffprobe -show_streams` lists two `mov_text` streams with `language=eng`/`zho`;
   QuickTime shows both in its subtitle menu.
5. Enqueue ~6 jobs, quit mid-run, relaunch → the interrupted job is back in `queued` and the queue resumes; its
   partial output is gone.
6. Cancel a running job → ffmpeg dies within the 3 s SIGTERM grace (`pgrep ffmpeg` empty) and the partial file is removed.
7. Archive + notarize → no *"must be rebuilt with support for the Hardened Runtime"* rejection for `ffmpeg`/`ffprobe`.

---

# Part 7 — Risks and open issues

- **No CRF.** VideoToolbox has no constant-quality mode comparable to x264 CRF; `-q:v` is chip-dependent and
  ignored for bitrate-mode encodes. The preset UI must say "Quality (hardware)" rather than imply CRF parity. If
  users push back on quality at low bitrates, the escape hatch is switching decision 2 to a GPL build.
- **App size.** +~45–60 MB on top of Bun's 59 MB, which inflates every Sparkle full update. Consider whether the
  appcast should move to delta updates (`scripts/ci/`) before shipping.
- **LGPL obligations.** We must publish the exact build recipe and pinned source versions (the workflow file does
  this) and surface the license notice in Settings. Do not add `--enable-gpl`/`--enable-nonfree` without revisiting.
- **ProRes on Intel.** `prores_videotoolbox` is Apple-silicon-only in practice; the ProRes preset must probe and
  fall back to `prores_ks` (permissively licensed, software) with a UI note.
- **Caption ↔ video drift.** Captions are timed to an audio file, not necessarily to the imported cut. The duration
  guard plus `subtitleOffsetMs` mitigate; a future frame-accurate re-align is out of scope.
- **Security-scoped bookmarks are new to this codebase.** macOS is unsandboxed so plain paths work today, but if the
  app is ever sandboxed (App Store), bookmark handling is the piece most likely to be wrong — write it correctly now.
- **Deliberately out of scope:** concatenating multiple inputs, per-clip trimming timelines, watermarks/overlays,
  HDR tone-mapping presets, and iOS support (the whole tab is `#if os(macOS)`, like Remotion).
