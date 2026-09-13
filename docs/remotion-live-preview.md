# Remotion footage playback

Selecting Remotion footage opens a player with native play/pause, frame stepping,
timecode, scrubbing, and reload controls. The viewer does not show a Studio picker.
Source playback has its own clock and does not move the sequence playhead.

Drag a Remotion project onto a video or audio track, then move, trim, split, or
change its speed with the existing timeline tools. Selecting or scrubbing a
timeline clip activates the sequence viewer. Remotion clips remain linked to the
composition; edits to source or public assets refresh their previews.

Sequences containing Remotion use a layered stage with native video, images,
captions, and live web players. Track order, placement, opacity, source in-points,
speed, volume, and mute follow the timeline. All surfaces follow the native
sequence clock, including pausing together while an active surface buffers.
Multiple instances of one composition keep independent playback positions.

`Packages/RxRemotion` owns compilation, the scoped Swift resource server and native exports. The bundled esbuild Web Worker compiles editable source without Bun, Node, Chromium, Studio or external renderer processes. Compiled resources are shared per project; each WebView has an independent playback bridge. Browser modules, CSS and assets remain in the film. Native source watching refreshes previews.

MCP `footage_create` for `kind: "remotion"` now returns `preview: {status, url}`. The URL is a native-hosted Player page, retained until the film closes or map settings change; it is not a Studio editing interface. Existing screenshot and file-editing tool names and arguments are unchanged. Edit files with those tools and watch the preview reload. `@rxlab/remotion-maps` exports `MapKitMap` and `OpenStreetMap`; configure an export-permitted tile provider in Settings → Maps before using OpenStreetMap.

When a web player cannot decode its media, or the clip exceeds its supported
speed or volume range, the app prepares an alpha-preserving ProRes source in the
app cache and switches that source to native playback. These temporary previews
do not add render versions. Source revision and canvas settings key the cache,
so cuts and speed edits can reuse the same file. Cancellation releases the
consumer and stops a render when no remaining viewer needs it.

Final sequence exports use alpha-preserving Remotion intermediates at the
composition's frame rate, followed by the sequence compositor's output sampling.
Changing the sequence frame rate therefore does not change composition duration.
Ordinary footage-only sequences continue using the existing native compositor.

New cache fingerprints include the engine/dependency manifest, map configuration, source/assets and render settings. Existing render history remains intact, but old-runtime renders are not reused as current results. The old runtime installation is no longer packaged, started, signed or refreshed. Existing files left by older app builds are not deleted from user storage.

See [package compatibility](../Packages/RxRemotion/Compatibility.md) and [validation](../Packages/RxRemotion/Validation.md) for capture boundaries and release checks.
