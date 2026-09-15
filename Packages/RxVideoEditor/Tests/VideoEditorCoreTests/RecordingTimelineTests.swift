import Foundation
import CoreImage
import Testing
@testable import VideoEditorCore

@Suite("Recording groups and presentation") struct RecordingTimelineTests {
    private func fixture() throws -> (Timeline, UUID, UUID) {
        var timeline = Timeline(width: 1920, height: 1080, fps: 60)
        let group = UUID(), instance = UUID()
        let screen = Clip(source: .init(id: "screen", kind: .video, displayName: "Screen"), start: 1, duration: 6, inPoint: 1, sourceDuration: 12, linkGroupID: group, recordingInstanceID: instance)
        let mic = Clip(source: .init(id: "mic", kind: .audio, displayName: "Mic"), start: 1.5, duration: 6, inPoint: 1, sourceDuration: 12, linkGroupID: group, recordingInstanceID: instance)
        try TimelineEditor.insert(&timeline, clip: screen, on: timeline.tracks.first { $0.kind == .video }!.id)
        try TimelineEditor.insert(&timeline, clip: mic, on: timeline.tracks.first { $0.kind == .audio }!.id)
        return (timeline, screen.id, mic.id)
    }
    @Test func linkedMoveTrimAndSplit() throws {
        var (timeline, screen, mic) = try fixture()
        try TimelineEditor.move(&timeline, clipID: screen, to: 2)
        #expect(timeline.clip(id: mic)?.start == 2.5)
        try TimelineEditor.trimLeading(&timeline, clipID: screen, by: 0.5)
        #expect(timeline.clip(id: mic)?.start == 3); #expect(timeline.clip(id: screen)?.duration == 5.5)
        try TimelineEditor.trimTrailing(&timeline, clipID: mic, by: -0.5)
        #expect(timeline.clip(id: screen)?.duration == 5)
        let right = try #require(TimelineEditor.split(&timeline, clipID: screen, at: 5))
        #expect(timeline.allClips.count == 4)
        #expect(timeline.clip(id: screen)?.linkGroupID != timeline.clip(id: right)?.linkGroupID)
        #expect(timeline.clip(id: screen)?.recordingInstanceID == timeline.clip(id: right)?.recordingInstanceID)
        let leftMic = try #require(timeline.clip(id: mic)); #expect(leftMic.end == 5)
    }
    @Test func atomicFailureAndUnsupportedRipple() throws {
        var (timeline, screen, mic) = try fixture()
        let track = try #require(timeline.track(containing: mic))
        try TimelineEditor.insert(&timeline, clip: Clip(source: .init(id: "blocker", kind: .audio, displayName: "Blocker"), start: 9, duration: 2), on: track.id)
        let saved = timeline
        #expect(throws: TimelineEditError.overlap) { try TimelineEditor.move(&timeline, clipID: screen, to: 4) }
        #expect(timeline == saved)
        #expect(throws: TimelineEditError.invalidDuration) { try TimelineEditor.move(&timeline, clipIDs: [screen], by: -3) }
        #expect(timeline == saved)
        #expect(throws: TimelineEditError.invalidDuration) { try TimelineEditor.trimTrailing(&timeline, clipID: screen, by: -20) }
        #expect(timeline == saved)
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.rippleDelete(&timeline, clipID: screen) }
        #expect(timeline == saved)
    }
    @Test func roundtripAndUnlinkPreserveIdentity() throws {
        var (timeline, screen, mic) = try fixture()
        let track = try #require(timeline.track(containing: mic))
        try TimelineEditor.setTrackAlias(&timeline, trackID: track.id, alias: "  Narrator  ")
        let copy = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(copy == timeline); #expect(copy[trackID: track.id]?.alias == "Narrator")
        TimelineEditor.unlink(&timeline, clipIDs: [screen])
        #expect(timeline.clip(id: mic)?.linkGroupID == nil)
        #expect(timeline.clip(id: mic)?.recordingInstanceID == copy.clip(id: mic)?.recordingInstanceID)
    }
    @Test func instanceZoomIsolationAndSourceTime() throws {
        var (timeline, screen, mic) = try fixture()
        var p = RecordingClipPresentation(); p.autoZoom = true; p.pointer = [.init(time: 1, x: 0.7, y: 0.3, clicked: true)]
        try TimelineEditor.update(&timeline, clipID: screen) { $0.recording = p }
        p.role = .camera; p.autoZoom = false
        try TimelineEditor.update(&timeline, clipID: mic) { $0.recording = p }
        let resolved = timeline.resolvedRecordingClip(try #require(timeline.clip(id: mic)))
        #expect(resolved.recording?.autoZoom == true)
        var unrelated = resolved; unrelated.recordingInstanceID = UUID(); unrelated.recording?.autoZoom = false
        #expect(timeline.resolvedRecordingClip(unrelated).recording?.autoZoom == false)
        p.visibility = [.init(start: 2, end: 3, visible: false)]
        #expect(!p.isVisible(at: 2.5)); #expect(p.isVisible(at: 3))
        #expect(p.zoom(at: 0).scale == 1)
        p.autoZoom = true; #expect(p.zoom(at: 1.5).scale > 1)
    }
    @Test func cameraKeepsAspectAndCursorHonorsOpacity() throws {
        let size = CGSize(width: 640, height: 360)
        var p = RecordingClipPresentation(); p.role = .camera; p.cameraAspectRatio = 4.0 / 3; p.shape = .circle
        let clip = Clip(source: .init(id: "camera", kind: .video, displayName: "Camera"), start: 0, duration: 3, recording: p)
        let transform = RecordingRenderer.cameraTransform(p, clip: clip, size: size)
        #expect(transform.a == transform.d, "A circular camera crop must not stretch the face")
        let content = PreviewGeometry.placement(source: CGSize(width: 400, height: 300), canvas: size, transform: .identity)
        let result = try #require(RecordingRenderer.render(CIImage(color: .red).cropped(to: content), clip: clip, time: 1, size: size))
        let rect = RecordingRenderer.cameraRect(p, size: size), context = CIContext()
        func alpha(_ image: CIImage, x: Double, y: Double) -> UInt8 {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes[3]
        }
        #expect(alpha(result, x: rect.midX, y: rect.midY) == 255)
        #expect(alpha(result, x: rect.minX + 1, y: rect.minY + 1) == 0)
        p.role = .cursor; p.cursor = .circle; p.smoothing = 0; p.pointer = [.init(time: 0, x: 0.5, y: 0.5)]
        var cursor = clip; cursor.recording = p; cursor.opacity = 0.25
        let raster = try #require(RecordingRenderer.render(nil, clip: cursor, time: 1, size: size))
        #expect((62...65).contains(alpha(raster, x: 320, y: 180)))
        p.pointer = [.init(time: 0, x: 1.1, y: 0.5)]
        #expect(RecordingRenderer.cursor(p, time: 1, size: size) == nil)
    }
}
