# Remotion

**The Remotion tab is macOS only.** It does not appear on iPhone or iPad.

Remotion builds video from React components. Film Workflow ships a complete Remotion runtime inside
the app, so there is nothing to install — no Node, no package manager, no terminal. Remotion Studio
runs in the app window, and rendering happens in place.

The runtime installs itself the first time you use it. The first launch is therefore slower than
later ones.

## Create a project

Click **+** above the sidebar. The editor is split: the composition's settings on the left, the
Studio preview on the right.

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

Once the inputs are set, **Generate with AI…** builds a starting `Composition.tsx` from them and
launches Studio. Treat it as a first draft.

Refining the composition happens in the **agent window**, not here — the agent can reach every
project, so composition editing lives there. Open it with Command-Option-0 and ask for the change
you want.

**View Source** in the toolbar shows the composition's TSX with syntax highlighting.

## Preview

The right-hand panel runs **Remotion Studio** against the current project. It shows *Starting
Remotion Studio…* while the runtime comes up, then the live preview.

The preview is paused while a render is in progress, and the panel says so. If the runtime fails to
start, the error is shown in the panel rather than hidden.

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

- **Studio will not start.** The error appears directly in the preview panel. The runtime is
  installed into the app's own support folder on first use; if a previous run was interrupted,
  quitting and reopening the app cleans up any leftover processes on launch.
- **Render is disabled.** The composition has no source yet. Use **Generate with AI…** or ask the
  agent to write one.
- **An asset is missing in the preview.** Check that you are referencing it through `staticFile()`
  with the right subfolder — `audio/` for audio, `generated/` for agent-generated images.
