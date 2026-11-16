# Sequences rendered by MotionSwift

Every picture in the app — sequences, library footage, the simple-mode preview and exports — is drawn by
MotionSwift. There is no AVFoundation compositor fallback; AVFoundation only keeps the clock and plays file audio.
The timeline model, editing operations and undo stay in `VideoEditorCore`; only drawing moved.

## How a sequence becomes a film

`MotionSequenceComposer` (in `VideoEditorCore`) turns a `Timeline` into a generated
Remotion-style TSX film (`index.tsx`, composition `Sequence`):

| Timeline | MotionSwift |
|---|---|
| Video clip | `<OffthreadVideo>` in a `<Sequence>`: `trimBefore` from the in point, `playbackRate` from speed, `volume`/`muted` from the clip and lane, placed with the clip transform (fit/fill/stretch, scale, offset) |
| Reversed clip | `<OffthreadVideo reverse>` for the picture, and the reversed audio copy (`ReversedAudioCache`) played forwards |
| Still | `<Img>` placed like video |
| Audio clip | `<Audio>` with trim, speed and volume |
| Remotion clip | Its project's `src/` compiled into the film and rendered as a nested composition: own size, frame rate and clock (in point, speed, reverse), `useVideoConfig()` of its own, and `staticFile()` resolved against its own `public/` folder through `<StaticFileRoot>` |
| Opacity | CSS `opacity` |
| Cross Dissolve, Directional Wipe, Fade through Color | Per-frame CSS opacity, `clipPath` and a color layer, matching the compositor |
| Installed (marketplace) transitions | A cross dissolve over the same range; the viewer notes the approximation |
| Pair transition past the media | Held first/last frame through `<Freeze>` |
| Effects, screen-recording presentation, captions, missing-media slates | Drawn by the host processor (below) |

Disabled clips and lanes leave gaps, as before. Captions follow the export's caption delivery:
burned in, or left out of the picture for embedded tracks and sidecar files.

### Host processor

MotionSwift's `MediaProcessing` hook passes decoded pixels of elements with a `process` key to
`MotionSequenceProcessor`, which reuses the compositor's Core Image code: the effect stack,
clip placement, `RecordingRenderer` (zoom, camera, cursor) and `TextRenderer` captions. Preview
and export therefore draw these exactly as the compositor did. Each film registers its
processor by token while it is in use.

## Preview

`MotionSequenceStage` shows the film with a `MotionPlayer`. `TimelinePlayerController` stays the
clock and plays file audio through AVFoundation (`audioOnly`), so playback, scrubbing, the level
meter and mute behave as before; MotionSwift adds only sound from inside nested compositions.
Edits recompile the film after 250 ms and hot-reload it in place.

## Export

`SequenceRenderService` exports with `MotionSequenceEngine.export`: Metal workers, H.264 or
HEVC through `MotionSwiftMovieWriter`, the frame voices mixed by `MotionSwiftAudioMix`, then the
usual subtitle muxing and caption files. Remotion clips are no longer rendered to movie files
first. Audio-only exports write the mix as M4A.

## Library footage

The footage viewer plays video, Remotion, caption and screen-recording footage as a one-clip film
through the same `MotionSequenceStage`. A saved Remotion render version plays that version's
movie; the live item plays the composition itself.

## Editing Remotion clips

Double-click a Remotion clip on the timeline (or choose **Open Composition** from its context menu,
the Remotion inspector's **Edit** button, or the Elements tab) to open its composition in place:

- The timeline panel shows a path back to the sequence (**Esc** returns) and the composition's
  elements as lanes on the app's own timeline. Moving or trimming a span rewrites that element's
  `from`/`durationInFrames`; undo and redo act on the composition source.
- The viewer shows MotionSwift's canvas, where elements are selected, moved and resized.
- The inspector shows the selected element's properties, edited in dedicated sheets.
- Text that the code generates is still editable. MotionSwift traces it back to the strings it is
  built from — a `const`, a row of a data array read by `.map`, a component prop at its usage, a
  template literal — and the inspector lists each as its own field. Editing a field rewrites only
  that string; fields marked *shared* change every element that reads them. A single traced string
  also edits in place on the canvas (double-click).
- Text that can't be traced (calculations) offers **Replace with Fixed Text…** (asks first; Undo
  restores the code) and **Edit in Code…**, which opens the Source editor at that line.
- The **Source** sheet is an editor: ⌘S saves, unsaved edits are confirmed before switching files or
  closing, and a file the agent or canvas changed meanwhile is never overwritten without asking.

Edits are written to `src/Composition.tsx`, copied into the document, and every preview reloads.

## Limits

- Clip volume above 100% is capped at 100% (MotionSwift volumes are 0…1).
- Effects on Remotion clips are not drawn (the host processor only sees decoded media).
- Installed Core Image transitions preview and export as a cross dissolve.
- A nested composition's volume follows its lane mute and a zero clip volume only.
- Video frames are decoded per frame by MotionSwift; very long, high-resolution timelines
  preview more slowly than AVPlayer did.
