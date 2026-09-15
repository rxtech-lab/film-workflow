# Screen recording and the camera pet

## Workflow

Create **Screen Recording** footage in the library. Its inspector configures
Record Content or Record Actions, capture sources, app sound, cameras and
microphones. Record Actions stores an editable action document; Replay and
Record creates a new media take. Open **Edit Recording Movement** for the
separate action editor. Each insertion of a take creates independent linked
tracks and a new presentation instance. The screen claims the sequence's own
video lane when its range is free, so a recording composes with the rest of the
film; the camera takes a video lane above it, the cursor an overlay lane, and
shortcuts a caption lane. Inserting the same take again reuses the lanes it
named rather than stacking new ones.

The floating toolbar and menu bar controls share `RecordingSession`. Stop is
idempotent during finalization. Pausing suspends the media and action clocks;
capture failures pause the session and resuming rebuilds failed capture inputs.
Closing the owning film or quitting the app finalizes active capture.

The recording menu bar item stays available while the app is running. **Quick
Recording…** opens setup for the most recently updated recording project in the
active film, creating one if needed. With no film open, it asks where to save a
new film first.

Remove individual takes from the inspector, versions list, or a thumbnail's
context menu. Removal hides the take from the library and supports **Edit →
Undo**. The stored take and media remain available to existing timeline clips;
removing a take does not free its media from disk.

Window screenshots, app screenshots and agent observations use ScreenCaptureKit.
App screenshots return individual successes and failures. Saved screenshots use
the existing image footage model. Agent observations default to unsaved images.
Source IDs are runtime window/display/device identifiers, supplemented by app
identity, title and geometry for action replay target resolution.

## Files and editing

Film format 2 stores `ScreenRecordingProject`, `RecordingTake`, component
manifests, action revisions, geometry, cursor events and shortcut cues. Upgrading
a format 1 film first creates a sibling migration backup. Existing builds reject
the newer format. Each recording stores its own media below
`Media/ScreenRecordings/<project>/<operation>`, with a checkpoint and fragmented
movies for interruption recovery. Recovery preserves playable media and avoids
duplicating a take whose operation was already saved.

General clip links remain separate from transition joins. Move, edge trim and
split validate the whole edit before applying it in one undo step. Invalid
bounds, collisions and unsupported operations are rejected. Unlinking leaves
camera/cursor/zoom relationships intact. Track aliases change the display name
without changing the track UUID or technical name.

Capture input changes produce additional media segments on their source's track.
Empty intervals remain empty. All linked segments participate in trims, so a
trim that cannot fit every segment is rejected; unlink for individual segment
editing. Media and input events stay unchanged when editing presentation.

Cursor visibility, clicks, smoothing, interaction zooms, camera masks and camera
keyframes use source time. The composition renderer and layered preview use the
same presentation geometry. Shortcut clips contain their own editable cues and
text style; regular typing does not become a subtitle.

Zooms live on their own lane, one clip per interval, which is where their start
and end are kept: drag or trim a clip to retime its zoom, and the inspector sets
its scale, focus and whether it follows the pointer. The lane is read in timeline
seconds and mapped onto the screen's source clock, so trims, speed changes,
reversal and splits carry their zooms with them. A zoom belongs to the screen
sharing its presentation instance, and the camera and cursor of that instance
follow it. **Generate Zooms from Clicks** writes one clip per click burst, with
clicks closer together than the ramp out and back in becoming a single zoom; a
recording set to zoom on clicks does this once as it is inserted. Nothing is
invented at render time afterwards, so a zoom clip that is deleted stays deleted.
A lane holding no clips leaves any intervals a film was written with in place.

The cursor and shortcut lanes draw what they contribute rather than the
composited recording: the pointer with its click ripple, and the key caps at that
moment. A zoom clip shows its scale and its ramp.

## Agent tools

`recording_sources`, `recording_focus`, `recording_screenshot`, `recording_get`,
`recording_configure`, `recording_start`, `recording_control`,
`recording_actions_edit`, `recording_perform_action`, `recording_presentation`,
`recording_shortcuts`, `recording_insert_take`, `recording_pet`,
`sequence_link_clips` and `sequence_track_alias` are registered MCP tools.
Existing agent policy still controls tool availability. Operations return stable
object IDs and a session handle. Focus context distinguishes current focus from
the last external window and includes bounded accessibility text and an image.

Secure inputs create unresolved actions. Missing/ambiguous targets and failed
waits pause replay. Cmd-Shift-Escape stops a session. Local pointer and scroll
motion honor editable easing and pause state. Physical iOS automation requires a
configured Appium/XCTest device; the Mac preview records controllable actions.
Direct finger interactions are only captured visually. An in-flight Appium
request cannot be interrupted by the local pause control; subsequent actions
wait until resumed.

## RxPet

`Packages/RxPet` is a standalone SwiftUI package. The camera character includes
48 generated movement frames, registered face anchors, six expressions, native
text, a reusable overlay presenter and a declarative state API. The animation
manifest gives movements slower 2–3 second loops and longer idle/waiting rests.
`.animationSpeed(0.5)` plays at half speed.

Open `Packages/RxPet/Sources/RxPet/PetPreviews.swift` for interactive controls,
every movement, every mood, all recording states, all 48 still frames, and
Reduce Motion/message examples. The gallery includes a speed slider.

The host registers the toolbar, pet, recording bar and controls windows before
creating capture filters, and keeps each hidden until its window ID is included
in the applied exclusions. `SCContentFilter` freezes its exclusion list when it
is built, so a window created later would be recorded. The controls panel is
additionally in the excluded input windows and deliberately not in the
pass-through set, so its own buttons are chrome rather than actions the take
replays; the pet and the recording bar are click-through and stay in the
pass-through set, so what happens under them is still captured. The pet never
owns or overrides the session's status. Hidden views stop animation scheduling,
and Reduce Motion shows a still frame.

Recording shows a companion beside the captured window, or inside a display's
corner when there is no room outside it. When several windows are recorded only
the frontmost carries a companion, so the desktop does not fill with pets; the
rest still exist, because every overlay must be registered before capture filters
are built. Each companion names its source and follows window movement,
pause/resume and source changes.

A red bar marks the top edge of everything being recorded, turning orange while
paused. It draws at status-bar level so a display's bar is not hidden behind the
menu bar.

Selection outlines disappear when recording starts and the floating toolbar is
hidden — a compact panel beside the companion carries elapsed time and
pause/resume/stop instead, so the controls sit where the user is already looking.
With more than one recorded display the panel follows the display holding the
cursor. The toolbar returns on its own if the session reports an error, and on
demand from the menu bar, which keeps the full control set. Window selections can
be removed from the toolbar during setup or while changing sources in a paused
take.

Selection itself: an unselected display dims hard enough to read as unarmed, and
dragging on a display selects an area directly rather than requiring the Area
tool first — a drag too small to record reverts to a plain display selection. The
selection overlay never takes key focus from the toolbar, which would otherwise
desaturate the record button for the length of a drag.

Overlays follow at 30 Hz so they keep up with a window being dragged, snapping
rather than animating while the target is in motion. The geometry samples written
into a take stay on the slower 10 Hz loop: they are renderer input stored in every
recording, so their density is deliberately decoupled from how smoothly the
overlays track.

## Validation

Automated coverage includes package resource/frame checks, linked edits and
rollback, aliases, instance isolation, save/reopen, undo/redo, action revision
validation, clock pause mapping and MCP screenshot results. Live window/app
screenshots and static-window movie duration checks require Screen Recording
permission. The display comparison additionally requires an interactive test
host and `RX_RECORDING_LIVE_DISPLAY_TEST=1`: hosted unit-test windows were
capturable individually but absent from both filtered and unfiltered desktop
captures in this session.

Release acceptance still requires connected-camera/microphone/device tests,
ten-minute synchronization measurement, live full-display/area exclusion,
fullscreen/Spaces and monitor changes, menu bar interaction while the editor is
minimized, native/browser/Simulator/physical-device replay and preview/export
comparison with mixed Remotion footage. These have not all been validated in
this implementation session.

Latest focused results: app build succeeded; five recording workflow/live window
tests passed and the interactive display test was skipped; RxPet's three tests
passed; RxVideoEditor's 97 tests passed. An earlier full app suite had 615 passing
tests and seven failures in marketplace, sign-in UI and Remotion tests. The font
specimen failures also reproduced on the original code; the other failures have
not all been isolated. These results do not establish full release acceptance.
