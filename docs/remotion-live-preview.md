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

The Player compiler is shared per project directory. Generated bundles live in
temporary storage; source files and public assets remain in the film. Each web
view has its own typed playback bridge. Studio remains available to existing MCP
workflows, with separate process ownership; rendering does not stop preview
processes.

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

The bundled Player version matches Remotion. The runtime installer refreshes
dependencies when the bundled manifest changes, and the build script reconciles
the frozen dependency lock instead of skipping an existing installation.
