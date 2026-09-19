import Foundation
import Testing
@testable import VideoEditorCore

@Suite("Recording zoom lane") struct RecordingZoomLaneTests {
    /// A screen on V1 with a camera sharing its instance, and an empty zoom lane.
    private func fixture(screenStart: Double = 1, duration: Double = 6, inPoint: Double = 1,
                         rate: Double = 1, reversed: Bool = false) throws -> (Timeline, UUID, UUID, UUID) {
        var timeline = Timeline(width: 1920, height: 1080, fps: 60)
        let instance = UUID()
        var screenPresentation = RecordingClipPresentation()
        screenPresentation.timeOffset = 0.5
        var cameraPresentation = RecordingClipPresentation()
        cameraPresentation.role = .camera
        let screen = Clip(source: .init(id: "screen", kind: .video, displayName: "Screen"), start: screenStart, duration: duration,
                          inPoint: inPoint, playbackRate: rate, isReversed: reversed, sourceDuration: 20,
                          recordingInstanceID: instance, recording: screenPresentation)
        let camera = Clip(source: .init(id: "camera", kind: .video, displayName: "Camera"), start: screenStart, duration: duration,
                          sourceDuration: 20, recordingInstanceID: instance, recording: cameraPresentation)
        let video = try #require(timeline.tracks.first { $0.kind == .video })
        try TimelineEditor.insert(&timeline, clip: screen, on: video.id)
        let cameraTrack = TimelineEditor.addTrack(&timeline, kind: .video)
        try TimelineEditor.insert(&timeline, clip: camera, on: cameraTrack)
        let zoomTrack = TimelineEditor.addTrack(&timeline, kind: .zoom)
        return (timeline, screen.id, camera.id, zoomTrack)
    }

    private func addZoom(_ timeline: inout Timeline, on track: UUID, instance: UUID,
                         start: Double, duration: Double, scale: Double = 3) throws -> UUID {
        let clip = Clip(source: .init(id: "zoom", kind: .zoom, displayName: "Zoom"), start: start, duration: duration,
                        recordingInstanceID: instance, recordingZoom: .init(scale: scale, x: 0.25, y: 0.75, followsPointer: false))
        try TimelineEditor.insert(&timeline, clip: clip, on: track)
        return clip.id
    }

    @Test func zoomLaneReplacesPresentationZooms() throws {
        var (timeline, screenID, _, zoomTrack) = try fixture()
        let screen = try #require(timeline.clip(id: screenID))
        // Stored zooms and auto zoom both give way once the lane holds anything.
        try TimelineEditor.update(&timeline, clipID: screenID) {
            $0.recording?.zooms = [.init(start: 0, end: 99, scale: 8)]
            $0.recording?.autoZoom = true
        }
        let instance = try #require(screen.recordingInstanceID)
        _ = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 2)
        let updated = try #require(timeline.clip(id: screenID))
        let resolved = try #require(timeline.resolvedRecordingClip(updated).recording)
        #expect(resolved.autoZoom == false)
        #expect(resolved.zooms.count == 1)
        // start 2 on the timeline is 1s into a clip that starts at 1 with inPoint 1,
        // plus the presentation's own 0.5 offset.
        #expect(abs(resolved.zooms[0].start - 2.5) < 0.0001)
        #expect(abs(resolved.zooms[0].end - 4.5) < 0.0001)
        #expect(resolved.zooms[0].scale == 3)
        #expect(resolved.zooms[0].followsPointer == false)
    }

    @Test func zoomPropagatesToCameraAndCursorSiblings() throws {
        var (timeline, screenID, cameraID, zoomTrack) = try fixture()
        let instance = try #require(timeline.clip(id: screenID)?.recordingInstanceID)
        _ = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 2)
        let screenClip = try #require(timeline.clip(id: screenID))
        let cameraClip = try #require(timeline.clip(id: cameraID))
        let screen = timeline.resolvedRecordingClip(screenClip)
        let camera = timeline.resolvedRecordingClip(cameraClip)
        #expect(camera.recording?.zooms == screen.recording?.zooms)
        #expect(camera.recording?.zooms.isEmpty == false)
    }

    @Test func laneIsIgnoredForOtherInstances() throws {
        var (timeline, screenID, _, zoomTrack) = try fixture()
        _ = try addZoom(&timeline, on: zoomTrack, instance: UUID(), start: 2, duration: 2)
        let clip = try #require(timeline.clip(id: screenID))
        let resolved = try #require(timeline.resolvedRecordingClip(clip).recording)
        #expect(resolved.zooms.isEmpty)
    }

    @Test(arguments: [(1.0, false), (2.0, false), (0.5, false), (1.0, true), (2.0, true)])
    func sourceTimeMappingUnderTrimRateAndReverse(rate: Double, reversed: Bool) throws {
        var (timeline, screenID, _, zoomTrack) = try fixture(rate: rate, reversed: reversed)
        let screen = try #require(timeline.clip(id: screenID))
        let instance = try #require(screen.recordingInstanceID)
        _ = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 2)
        let updated = try #require(timeline.clip(id: screenID))
        let resolved = try #require(timeline.resolvedRecordingClip(updated).recording)
        let zoom = try #require(resolved.zooms.first)
        // Reverse playback walks the source backwards; the interval must still read forwards.
        #expect(zoom.end > zoom.start)
        #expect(abs((zoom.end - zoom.start) - 2 * rate) < 0.0001)
        // The mapping and its inverse agree, so a generated clip lands where it was read from.
        let back = screen.timelineTime(atSource: zoom.start - resolved.timeOffset)
        let forward = screen.timelineTime(atSource: zoom.end - resolved.timeOffset)
        #expect(abs(min(back, forward) - 2) < 0.0001)
        #expect(abs(max(back, forward) - 4) < 0.0001)
    }

    @Test func zoomClipsStraddlingASplitClampToEachHalf() throws {
        var (timeline, screenID, _, zoomTrack) = try fixture()
        let instance = try #require(timeline.clip(id: screenID)?.recordingInstanceID)
        _ = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 3)
        let right = try #require(TimelineEditor.split(&timeline, clipID: screenID, at: 4))
        let leftClip = try #require(timeline.clip(id: screenID))
        let rightClip = try #require(timeline.clip(id: right))
        let left = try #require(timeline.resolvedRecordingClip(leftClip).recording)
        let rightResolved = try #require(timeline.resolvedRecordingClip(rightClip).recording)
        // 2...4 of the zoom belongs to the left half, 4...5 to the right.
        let leftZoom = try #require(left.zooms.first)
        let rightZoom = try #require(rightResolved.zooms.first)
        #expect(abs(leftZoom.start - 2.5) < 0.0001)
        #expect(abs(leftZoom.end - 4.5) < 0.0001)
        #expect(abs(rightZoom.start - 4.5) < 0.0001)
        #expect(abs(rightZoom.end - 5.5) < 0.0001)
    }

    @Test func zoomTrackAcceptsOnlyZoomSources() throws {
        #expect(TrackKind.zoom.accepts(.zoom))
        for kind in [SourceKind.video, .image, .captions, .audio, .remotion] {
            #expect(!TrackKind.zoom.accepts(kind))
        }
        for kind in TrackKind.allCases where kind != .zoom { #expect(!kind.accepts(.zoom)) }
        #expect(!TrackKind.zoom.drawsOverPicture)
        #expect(!TrackKind.zoom.carriesAudio)

        var (timeline, _, _, zoomTrack) = try fixture()
        let still = Clip(source: .init(id: "still", kind: .image, displayName: "Still"), start: 12, duration: 1)
        #expect(throws: TimelineEditError.self) { try TimelineEditor.insert(&timeline, clip: still, on: zoomTrack) }
        let video = try #require(timeline.tracks.first { $0.kind == .video })
        let zoom = Clip(source: .init(id: "zoom", kind: .zoom, displayName: "Zoom"), start: 12, duration: 1, recordingZoom: .init())
        #expect(throws: TimelineEditError.self) { try TimelineEditor.insert(&timeline, clip: zoom, on: video.id) }
    }

    @Test func zoomLaneSuppliesNoPicture() throws {
        var (timeline, screenID, _, zoomTrack) = try fixture()
        let instance = try #require(timeline.clip(id: screenID)?.recordingInstanceID)
        _ = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 2)
        #expect(!timeline.pictureTracksBackToFront.contains { $0.kind == .zoom })
    }

    @Test func zoomClipTrimsBothEdges() throws {
        var (timeline, screenID, _, zoomTrack) = try fixture()
        let instance = try #require(timeline.clip(id: screenID)?.recordingInstanceID)
        let zoom = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 2)
        // A zoom clip has no source to run out of, so its left edge extends.
        try TimelineEditor.trimLeading(&timeline, clipID: zoom, by: -0.5)
        #expect(timeline.clip(id: zoom)?.start == 1.5)
        #expect(timeline.clip(id: zoom)?.duration == 2.5)
        try TimelineEditor.trimTrailing(&timeline, clipID: zoom, by: 1)
        #expect(timeline.clip(id: zoom)?.duration == 3.5)
    }

    @Test func zoomClipSurvivesARoundTrip() throws {
        var (timeline, screenID, _, zoomTrack) = try fixture()
        let instance = try #require(timeline.clip(id: screenID)?.recordingInstanceID)
        let zoom = try addZoom(&timeline, on: zoomTrack, instance: instance, start: 2, duration: 2)
        let copy = try TimelineCodec.decode(try TimelineCodec.encode(timeline))
        #expect(copy == timeline)
        #expect(copy.clip(id: zoom)?.recordingZoom?.scale == 3)
    }

    @Test func autoZoomWindowsCoalesce() {
        func windows(_ times: [Double]) -> [(start: Double, end: Double, x: Double, y: Double)] {
            var p = RecordingClipPresentation()
            p.pointer = times.map { .init(time: $0, x: 0.5, y: 0.5, clicked: true) }
            return p.autoZoomWindows()
        }
        #expect(RecordingClipPresentation().autoZoomWindows().isEmpty)
        #expect(windows([0]).count == 1)
        // Inside the hold, and inside the gap that follows it: one window.
        #expect(windows([0, 1]).count == 1)
        #expect(windows([0, 3.0]).count == 1)
        #expect(windows([0, 0.05, 0.1]).count == 1)
        // Past the hold plus the gap: a second window.
        let apart = windows([0, 4])
        #expect(apart.count == 2)
        #expect(apart[1].start - apart[0].end >= 0.6)
        // A click storm extends one window rather than restarting it.
        #expect(abs(windows([0, 1, 2]).first!.end - 4.5) < 0.0001)
    }

    @Test func materializeAutoZoomMakesOneClipPerBurstAndStops() throws {
        var (timeline, screenID, _, _) = try fixture(screenStart: 0, duration: 12, inPoint: 0)
        try TimelineEditor.update(&timeline, clipID: screenID) {
            $0.recording?.autoZoom = true
            $0.recording?.zoomScale = 2.5
            $0.recording?.pointer = [1, 1.2, 6].map { .init(time: $0, x: 0.4, y: 0.6, clicked: true) }
        }
        let source = ClipSource(id: "recordingZoom:screen", kind: .zoom, displayName: "Zoom")
        let ids = TimelineEditor.materializeAutoZoom(&timeline, screenClipID: screenID, source: source)
        #expect(ids.count == 2)
        let lane = try #require(timeline.tracks.first { $0.kind == .zoom && !$0.clips.isEmpty })
        #expect(lane.clips.allSatisfy { $0.recordingZoom?.scale == 2.5 })
        let instance = timeline.clip(id: screenID)?.recordingInstanceID
        #expect(lane.clips.allSatisfy { $0.recordingInstanceID == instance })
        // Clips replace the render-time synthesis rather than adding to it.
        #expect(timeline.clip(id: screenID)?.recording?.autoZoom == false)
        #expect(TimelineEditor.materializeAutoZoom(&timeline, screenClipID: screenID, source: source).isEmpty)
        let updated = try #require(timeline.clip(id: screenID))
        let resolved = try #require(timeline.resolvedRecordingClip(updated).recording)
        #expect(resolved.zooms.count == 2)
    }
}
