# Effects and transitions

Use the sidebar button in the timeline header to show or hide the **Effects &
Transitions** browser. Its title aligns to the left in a full-width header, and
the two catalog tabs fill the panel. Drag its divider to resize it. Visibility and width are saved with the project.
Opening and closing slides the browser smoothly while retaining the timeline's
scroll position, editing tool, selection and loaded thumbnails. The browser also
keeps its search and selected tab. Reduce Motion disables the slide animation.
The browser has searchable tabs, thumbnails, descriptions in tooltips, and
animated previews on hover. Click an item to inspect its explanation and defaults.

Drag an effect onto a video, image or Remotion clip on a picture track. Every drop
adds a separate instance. Click the clip's **FX** badge or **Effects** inspector
tab to change parameters, move an effect up/down, bypass it, or remove it.

Drag a transition onto one of the highlighted targets:

| Target | Result |
| --- | --- |
| In, in the first half of a clip | A transition inside its start |
| Out, in the second half of a clip | A transition inside its end |
| Join, at the shared edge of touching clips on one track | A transition centered on the existing cut |

The Join zone extends up to 40 points on either side of the cut, limited to a
fifth of the shorter clip, so a drop near the edge joins both clips instead of
landing as an In or Out on only one of them. The highlight label always names
the target that a drop would create.

Transition regions match the clip height. They initially last one second, shortened when necessary to fit. Drag
either handle of a joined transition to resize around its cut. Single-clip
transitions have one inward handle. Lengths snap to frames and cannot overlap
another transition on those clips. Click a transition label for its inspector,
where duration, enabled state, parameters and removal are also available.

A join links clips for movement, including chains of joins. The clips stay
individually selectable, and removing the join breaks the link. Creating or
resizing a transition preserves the cut, clip positions and sequence length.
Trims, speed changes and other edits that would break a join are rejected.
Deleting a clip removes its attached transitions and retains neighboring clips.
Splitting outside a transition clones the effect stack and retains transitions
on the outer pieces; splitting inside a transition is rejected.

Each drop, parameter gesture, resize, reorder or removal is one undo step.
Inspecting an effect or transition temporarily overrides the remembered footage
tab. Selecting ordinary footage returns to that preference.

## Rendering and persistence

`RxVideoEffects` supplies definitions and reusable controls. `RxVideoEditor`
owns timeline instances, attachments and atomic operations. Clip effects are
ordered arrays; transitions are timeline instances that reference clip IDs.
Older documents decode both collections as empty. Unrecognized definitions and
their parameters survive saving. Their inspector identifies them as unavailable;
disable or remove them before export.

Preview and export use the same Core Image compositor: effect stack, clip
placement/opacity, transitions, then picture-track compositing. Dissolves and
wipes at single edges reveal lower layers; Fade through Color uses its chosen
RGB color. Pair transitions use unused frames beyond trimmed edges, accounting
for speed, and hold the nearest valid frame after source footage is exhausted.
Separate AVFoundation tracks make simultaneous transition inputs available.

Sequences with active effects/transitions and Remotion prepare cached rendered
Remotion sources before loading the shared compositor. Preview captures are capped
at 960 pixels on their longest edge while keeping the logical composition size,
frame rate, every animation frame, audio and alpha. Exports retain full resolution.
Edits can rejoin a source render already in progress; unclaimed work is cancelled
after a two-second grace period. The viewer shows progress and offers Retry on
failure. Sequences without active modifiers retain live Remotion playback.

The shared compositor applies AVFoundation's render transform when writing smaller
preview buffers, keeping the same framing as full-resolution output when a
transition changes a sequence from live playback to the shared compositor.

Audio, captions, source-library effects, compound clips and runtime plugin
installation are outside this version.

## Validation

The effects package tests cover definition rendering and stack order. The editor
tests cover persistence, legacy decoding, linked edits, protected joins,
splitting/deletion, duration limits, drop targets at several zoom levels, and
actual exported frames compared with preview frames. Application tests cover
temporary inspector selection, undo/redo, reopening and panel restoration.
Player-output tests compare video corners before and during transitions at full,
half and quarter resolution. Remotion tests verify scaled captures preserve layout,
alpha, timing and audio; application tests cover render reuse, cancellation and retry.
CI runs both package suites and the macOS build.
