# Remotion

**The Remotion tab is macOS only.** It does not appear on iPhone or iPad.

Remotion builds video from React components. Film Workflow uses the RxRemotion Swift package and the system WebView for preview and native movie export. Everything needed is bundled; no runtime installation, Node, Bun, Chromium, or Studio is required.

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

**View Source** in the toolbar shows the composition's TSX with syntax highlighting.

## Preview

The right-hand panel shows a live composition with native play, pause, seek and reload controls. Source and asset edits refresh the preview. Each timeline instance keeps its own playback position. Preview and export use separate sessions, so exporting does not stop the live preview.

`MapKitMap` and `OpenStreetMap` are available from `@rxlab/remotion-maps`. Apple Maps needs no web SDK credentials. For OpenStreetMap, configure your licensed tile URL, attribution, zoom limits and credentials in **Settings → Remotion**, and confirm that the provider permits movie exports. Public OSM tiles are not used for automated rendering.

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
- **An effect cannot be exported.** The renderer reports unsupported effects explicitly. Use frame-driven 2D effects; check the package compatibility guide for WebKit capture limits.
- **Render is disabled.** The composition has no source yet. Use **Generate with AI…** or ask the
  agent to write one.
- **An asset is missing in the preview.** Check that you are referencing it through `staticFile()`
  with the right subfolder — `audio/` for audio, `generated/` for agent-generated images.
