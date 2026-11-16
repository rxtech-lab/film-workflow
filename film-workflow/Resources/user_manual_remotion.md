# Remotion

**The Remotion tab is macOS only.** It does not appear on iPhone or iPad.

Remotion builds video from React components. Film Workflow compiles, previews and renders compositions natively with MotionSwift (Skia on Metal). Everything needed is bundled; no browser, Node, Bun, Chromium, or Studio is required. MotionSwift supports a subset of Remotion: compositions that use unsupported packages, elements or styles show an error instead of rendering.

## Create a project

Click **+** above the sidebar. The editor is split: the composition's settings on the left, the
native preview on the right.

### Basic

- **Project Name**
- **Text Overlay** — the headline text for the composition.
- **Duration**
- **Theme Color**
- **Resolution**
- **Frame Rate**

### Prompt

Tell the model what kind of video to build — style, motion, mood, structure. This is used as context
whenever the agent edits this composition, so it is worth writing properly rather than leaving
blank.

### Images

Attach images to the project. They are available to the composition as assets.

### Reference image

A single image used as a **visual style guide** when the agent edits the composition. This is
different from the images above: it is direction, not content.

### Generated images

Images the agent generates for this project appear here. They are saved under `public/generated/`
and referenced in the composition with:

```
staticFile("generated/<name>")
```

Right-click one to **Reveal in Finder** or delete it. The refresh button re-reads the folder.

### Audio

Music, sound effects, narration — anything audio. **Add Audio** copies the file into
`public/audio/`, and you reference it with:

```
staticFile("audio/<name>")
```

This is how a track generated in the Music tab, or a narration from the Narrative tab, gets into a
video.

## Build the composition

Three.js is included for 3D scenes, together with React Three Fiber, Drei, and Remotion's ThreeCanvas. The agent can use these packages immediately; no installation is needed. Ask for animated 3D objects, lighting, or camera motion just as you would describe a 2D composition.

Once the inputs are set, **Generate with AI…** builds a starting `Composition.tsx` from them and
starts the native preview. Treat it as a first draft.

Refining the composition happens in the **agent window**, not here — the agent can reach every
project, so composition editing lives there. Open it with Command-Option-0 and ask for the change
you want.

**Source** opens the project's files in an editor with syntax highlighting. Edit the code and press ⌘S to save; the previews reload. You're asked before unsaved edits are discarded, and before overwriting a file the agent changed while you were editing.

## Preview

The right-hand panel shows a live composition with native play, pause, seek and reload controls. Source and asset edits refresh the preview. Each timeline instance keeps its own playback position. Preview and export use separate sessions, so exporting does not stop the live preview.

**Edit** in the inspector opens the composition on a native canvas: select an element, drag it, and change its text and style in the inspector. Changes are saved to the composition source.

The **Elements** tab in the inspector lists the composition's editable elements, also when a Remotion clip is selected on the timeline. Choose an element to change its text and style in place. Double-click the clip on the timeline (or choose **Open Composition**) to edit the composition in place: its elements become lanes on the timeline, where you move and trim them, and the viewer becomes a canvas for moving and resizing them. Press Esc or the back button to return to the sequence. The timeline preview updates as soon as you save.

Text the code generates can be edited too. When a title comes from a variable, a list of data, or a component's props, the inspector shows each piece of text it is built from, with the line it's written on. Edit a piece and only that text changes in the code. Pieces marked **shared** are used by more than one element and change everywhere. Text that code calculates (for example a counter) can be replaced with fixed text — you're asked first, and Undo brings the code back — or opened in the Source editor with **Edit in Code…**.

Remotion clips play live in sequences and export with them, so a sequence render no longer renders them to movies first.

Maps come from `@motionswift/map` (OpenStreetMap, Apple Maps and Mapbox, with routes and markers). Mapbox styles need an access token in **Settings → Remotion**.

## Render

**Render** is in the toolbar, and is disabled until the composition has source.

The export sheet lets you set:

- **Resolution**
- **Frame Rate**
- **Save To** — the destination folder.

The sheet states the composition's own resolution and frame rate next to the output settings, so you
can see when you are scaling or resampling.

Confirm with **Render Now**. Progress is reported while the render runs.

## Deleting

Deleting a Remotion project permanently deletes its Remotion source, its assets, and its chat
history.

## Troubleshooting

- **Preview will not start.** The panel shows compilation or resource errors. Check the entrypoint and source imports, then reload. Only bundled libraries and project-local browser modules are supported.
- **An effect cannot be exported.** The native renderer reports unsupported packages, elements and styles explicitly. Use inline styles and frame-driven effects from the supported Remotion subset.
- **Render is disabled.** The composition has no source yet. Use **Generate with AI…** or ask the
  agent to write one.
- **An asset is missing in the preview.** Check that you are referencing it through `staticFile()`
  with the right subfolder — `audio/` for audio, `generated/` for agent-generated images.
