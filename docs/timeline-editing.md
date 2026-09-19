# Timeline editing

Footage models opt into editing with `TimelineDraggable`,
`TimelineDurationChangeable`, `TimelineCuttable`, `TimelineReversible`, and
`TimelineSpeedChangeable`. Each protocol has a Boolean capability requirement
with a default of `true`. Mixed media models can override it per item.
The drag payload copies these capabilities into `ClipSource.capabilities`;
controls and editing operations both check that stored set.

| Footage | Trim | Cut | Reverse | Speed | Drag |
| --- | --- | --- | --- | --- | --- |
| Generated music, narration, imported audio | Yes | Yes | Yes | Yes | Yes |
| Generated/imported video, Remotion | Yes | Yes | No | Yes | Yes |
| Stills, captions | Yes | Yes | No | No | Yes |
| Screen recording zooms | Yes | Yes | No | No | Yes |

Lanes are video, audio, overlay, caption, or zoom. A zoom lane belongs to the
screen recording that made it and takes nothing else: its clips supply no
picture and no sound, only the zoom each one's range applies to its recording.
Add Track does not offer one, and neither does `sequence_add_track`.

The compact toolbar combines Add Track, Select (A), Cut (B), Skim (S), Speed,
Reverse, timecode and zoom in one row. Narrow panels use icons with tooltips.
Escape returns to Select. With Skim on, moving the pointer across the lanes
previews the frame under it in the viewer while the playhead stays where it
was; the viewer returns to the playhead when the pointer leaves, and a click
still moves the playhead. Skimming never interrupts playback or a drag. The
setting is remembered per user (`timeline.skim` in user defaults). The footage
browser skims regardless of the switch: moving the pointer across a video or
audio cell plays that take in the viewer at the pointer's position, and the
viewer returns to the selection when the pointer leaves. Blade clicks split at the pointer's frame. Speed and
Reverse are disabled without a compatible selection. Speed accepts a positive
percentage, including `120%`, or a target duration in seconds. Edits that would
overlap another clip are rejected without changing the timeline.

Command-Z undoes an editor change; Shift-Command-Z redoes it. The same actions
are available in the native Edit menu. History covers clip insertion, deletion,
movement, trimming, cuts, speed and reverse, track changes, clip properties,
and sequence settings. A drag or trim commits as one undo step. Each window
uses its own native undo history, and text fields keep their normal shortcuts.

Clicking a clip selects it alone. Command- or shift-click adds a clip to the
selection or removes it. Dragging across empty lane space sweeps a blue
selection rectangle; every clip it touches on the lanes it spans becomes
selected, and holding shift or command keeps the existing selection. Command-A
(Edit > Select All) selects every clip while the timeline has focus. A plain
click on a lane still moves the playhead. Dragging any selected clip moves the
whole selection together, keeping its layout, snapping the grabbed clip's edge,
and changing lane only when every clip fits the new lane. Delete, Backspace, or
the context menu remove the whole selection as one undo step; Ripple Delete
closes each gap. Speed, Reverse, and the inspector need exactly one selected
clip; the toolbar shows the count otherwise.

## Track headers

Drag a header to reorder the lanes; right-click one for the rest: its alias,
whether it is pinned, and Delete Track. Deleting takes the lane's clips and
the transitions on them with it, as one undo step, and the timeline always
keeps a last lane.

Pinning holds a lane on screen while the timeline scrolls. A pinned lane keeps
its place in the order: it sits where it always did until the scroll would
take it off the top, and from there it rides along under any lanes pinned
above it, so the layout still reads top to bottom as it is. Its header shows a
pin beside the name, and the pin is saved with the film.

## Disabling clips and tracks

A clip can be turned off without being removed. The clip keeps its place,
trims, speed, volume and effects, and the timeline keeps its length; it is
simply left out of the preview and the render, so what was under it shows
through and a gap is all that remains where nothing else covers it. Nothing
on the timeline moves, so turning a clip back on restores the cut exactly.

Toggle it from the clip's context menu (Enable/Disable, which acts on the
whole selection), the timeline toolbar's eye button, the Clip inspector's
Enabled switch, or by pressing V with clips selected. A disabled clip draws
greyed out with a dashed border and an eye-with-a-slash badge.

Each track header carries the same eye button, which turns the whole lane off
the way disabling each of its clips would. It is separate from the audio
lane's mute button: mute silences a lane that still renders its picture,
while disabling removes the lane from the render entirely.

Everything downstream follows the switch: burned-in captions, embedded
subtitle tracks and sidecar transcripts all skip disabled caption clips and
lanes, and a Remotion clip that is off is neither rendered before an export
nor able to hold one up while its media is missing.

A caption clip starts with its project's default style
(`CaptionProject.captionStyle`, edited in the project's Style tab); the Clip
tab changes one clip, and the render sheet's Caption Style changes every
caption clip in the sequence. See `caption-export.md` for how captions reach a
render.

## Inspector tabs

The inspector's tab row is computed from the protocols the selected model
conforms to (`InspectorProtocols.swift`): `InspectorProtocol` supplies the
Settings tab (titled Sequence for a sequence) and an optional footer with the
Generate, Transcribe or Render button that stays under every tab;
`EditorTabProviding` adds an editor tab (Captions, Composition, Transcript);
`CaptionStyleProviding` adds Style. `InspectorTabResolver` appends Clip while
timeline clips are selected and Sequence when a clip's source is shown while
the sequence is the library selection. Conformances live in
`InspectorProtocol+Models.swift`; `LibraryIndex.model(for:)` is the one place a
kind resolves to a model.

Selecting footage or a clip never changes the tab. `EditorWindowState`
remembers the last tab picked (persisted in `UserDefaults` as `inspector.tab`);
a selection that does not offer it shows its first tab without forgetting the
choice, so picking Captions, clicking a music item and returning to the
captions lands on Captions again.

Effects and transitions temporarily open their own inspector tabs without
changing this preference. The timeline browser adds clip effect stacks and
single-edge or joined transitions; see [Effects and transitions](effects-and-transitions.md)
for drop targets, linked movement, duration handles and rendering rules.

Caption clips offer Align with Original Audio in their context menu. It moves
the caption clip onto the start of the clip that plays the audio the captions
were transcribed from, a narration, a music take or an imported asset, and
copies that clip's in point and length so the cues play in step. The item
appears for every caption project that has audio and stays disabled until a
clip playing that audio is on the timeline; when that audio has been split,
the earliest piece is the target. The caption clip stays on its own track and
must fit there without overlapping.

Clip edges trim without selecting first. A retimed clip shows an orange strip
at its top with the current percentage. Dragging the strip's left handle
changes speed while holding the end fixed; the right handle holds the start
fixed. The ordinary clip edges below the strip continue to trim. The percentage
and waveform update during the drag, and the strip disappears at 100%.
Double-clicking the strip's right handle restores 100%, keeping the clip's start
and source range fixed. The same overlap checks apply to this reset.

Clips with audio show a waveform strip along their bottom edge. Dragging the
strip up or down changes the clip's volume (0–200%, 40 points per 100%), with
the waveform and a readout following the drag and the level sticking at 100%
near unity. The clip's edges inside the strip still trim. Double-clicking the
strip restores 100%. The inspector's Volume slider edits the same value.

`Clip.duration` is timeline time. `playbackRate` is source seconds per timeline
second. The preserved source range is `inPoint ..< inPoint + duration *
playbackRate`; `inPoint` remains the lower bound even when reversed. Cuts and
trims use this mapping in either direction. Speed and reverse are saved with
the clip. Older projects default to 100%, forward playback, and capabilities
appropriate for their source kind.

Playback and export share AVFoundation composition time scaling. Audio uses
spectral pitch processing. Reverse audio is cached as PCM with reversed sample
frames and unchanged channel order, processed in bounded chunks. Waveforms use
the same source range, speed, and direction as the composition.

Validation includes model/source mapping and atomic overlap tests, save/reopen,
stereo reversal across chunk boundaries, retimed video track mappings, actual
retimed/reversed audio export, and speed/trim handle hit testing. The temporary
standalone timeline window was also exercised with mouse drags, percentage and
duration entry, reverse, selection gating, and the B shortcut.
