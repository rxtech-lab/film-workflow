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

The toolbar below the timecode has Select (A), Cut (B), Speed, and Reverse.
Escape returns to Select. Blade clicks split at the pointer's frame. Speed and
Reverse are disabled without a compatible selection. Speed accepts a positive
percentage, including `120%`, or a target duration in seconds. Edits that would
overlap another clip are rejected without changing the timeline.

Command-Z undoes an editor change; Shift-Command-Z redoes it. The same actions
are available in the native Edit menu. History covers clip insertion, deletion,
movement, trimming, cuts, speed and reverse, track changes, clip properties,
and sequence settings. A drag or trim commits as one undo step. Each window
uses its own native undo history, and text fields keep their normal shortcuts.

Clip edges trim without selecting first. A retimed clip shows an orange strip
at its top with the current percentage. Dragging the strip's left handle
changes speed while holding the end fixed; the right handle holds the start
fixed. The ordinary clip edges below the strip continue to trim. The percentage
and waveform update during the drag, and the strip disappears at 100%.
Double-clicking the strip's right handle restores 100%, keeping the clip's start
and source range fixed. The same overlap checks apply to this reset.

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
