# Remotion footage playback and rendering

Remotion compositions are compiled, previewed, edited and rendered natively with
[MotionSwift](https://github.com/rxtech-lab/MotionSwift) (Skia on Metal). There is no
WebView, browser, Node, Bun or Studio process. The app links MotionSwift as a local
Swift package at `../MotionSwift` (a checkout beside this repository, bootstrapped with
`make bootstrap` so its native Skia archive and compiler resources exist).

## Project layout

`RemotionRuntime.scaffold(at:)` writes `src/index.ts`, `src/Root.tsx` (one `Main`
composition sized by the `COMPOSITION_*` exports of `src/Composition.tsx`),
`tsconfig.json` and `public/` for `staticFile()` assets. Missing scaffold files are added
whenever a project is compiled; existing files are never overwritten.

## Viewer and timeline

Selecting Remotion footage opens a player with native play/pause, frame stepping,
timecode and scrubbing. Source playback has its own clock and does not move the
sequence playhead.

Drag a Remotion project onto a video or audio track, then move, trim, split, or
change its speed with the existing timeline tools. Sequences containing Remotion use a
layered stage; each Remotion layer is a `MotionLivePreviewView` that compiles the
project (`MotionSwiftEngine.prepare`, cached per project) and follows the sequence
clock through `LivePreviewPlayback` commands. Track order, placement, opacity, source
in-points, volume and mute follow the timeline. At 1× the layer plays on its own
clock with drift correction; other speeds follow the editor frame by frame. The
composition's `<Audio>` and `<Video>` sound plays through MotionSwift's media preview.

`RemotionProjectWatcher` polls the sources of every project on screen once a second
and posts `.remotionPreviewChanged`, so edits from agents, the Source sheet or an
external editor reload viewers, filmstrips and thumbnails.

When a clip exceeds the live preview's speed or volume range, the app renders an
alpha-preserving ProRes source into the app cache and plays that instead. These
temporary previews do not add render versions.

## Editing elements

**Edit** in the Remotion inspector opens `MotionElementEditorSheet`, MotionSwift's
`MotionEditorView`: select elements on the canvas, drag them, change text and styles in
the inspector, and scrub the element timeline. Edits are written back to the TSX as they
are committed; closing the sheet copies `src/Composition.tsx` into the document and
reloads previews.

## Rendering

`MotionSwiftMovieRenderer` renders on Metal workers and encodes with AVFoundation:
H.264 from shared IOSurface frames, or ProRes 4444 with alpha from CPU readbacks.
`MotionSwiftAudioMix` mixes the per-frame `<Audio>`/`<Video>` voices with AVFoundation
into AAC and muxes them without re-encoding the picture (MotionSwift's own mixer needs
ffmpeg, which the app does not ship). Stills and library thumbnails use the same
compiled project. Frame pipelines run one at a time because MotionSwift's render
threads resolve `staticFile()` through a process-wide public directory.

Final sequence exports use alpha-preserving Remotion intermediates at the
composition's frame rate, followed by the sequence compositor's output sampling.

A composition with **Transparent Background** on paints no background fill. Timeline
renders keep alpha either way. Export to Disk writes such a composition as a ProRes 4444
`.mov` with alpha.

## Compatibility

MotionSwift supports a defined subset of Remotion (see its `docs/compatibility.md`).
Compositions outside it fail to compile or render, with the compiler or JavaScript
error shown in the alert or returned to the agent. There is no WebKit fallback. The
agent authoring instructions (`RemotionMCPHandlers.authoringInstructions`) describe the
subset: bundled packages are react, remotion, `@remotion/paths`, `@remotion/shapes`,
`@remotion/transitions`, `@remotion/three`, `@react-three/fiber`, three (plus the USD
loader) and `@motionswift/map`. Inline styles only; no canvas, iframe or svg text;
orthographic `ThreeCanvas` cameras, textures and shadows are not supported yet.

Known MotionSwift limitation: the element editor's portable compiler does not see later
names in a comma-separated export (`export const A = 1, B = 2`). The default templates
declare each export on its own line, and agents are told to do the same.

MCP `footage_create` for `kind: "remotion"` returns `preview: {status}` — `ready` when
the seeded composition compiles, or the failure. Use the still tools to look at frames.

Render cache fingerprints include `MotionSwiftEngine.fingerprint` (the MotionSwift
vendor graph), source/assets and render settings, so renders from the previous
WebKit runtime show as out of date and render again.
