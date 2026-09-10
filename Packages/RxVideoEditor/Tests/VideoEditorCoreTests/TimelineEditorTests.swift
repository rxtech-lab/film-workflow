import Foundation
import Testing

@testable import VideoEditorCore

@Suite("Timeline editing")
struct TimelineEditorTests {
    private func video(_ name: String, start: TimeInterval, duration: TimeInterval) -> Clip {
        Clip(source: ClipSource(id: "video:\(name)", kind: .video, displayName: name), start: start, duration: duration)
    }

    private var timeline: Timeline { Timeline(width: 1920, height: 1080, fps: 30) }
    private func videoTrack(_ t: Timeline) -> UUID { t.tracks.first { $0.kind == .video }!.id }
    private func audioTrack(_ t: Timeline) -> UUID { t.tracks.first { $0.kind == .audio }!.id }

    @Test("Insert rejects overlaps and wrong kinds, ripple shifts later clips")
    func insertRules() throws {
        var t = timeline
        let v = videoTrack(t)
        try TimelineEditor.insert(&t, clip: video("a", start: 0, duration: 4), on: v)
        try TimelineEditor.insert(&t, clip: video("b", start: 4, duration: 2), on: v)
        #expect(throws: TimelineEditError.overlap) {
            try TimelineEditor.insert(&t, clip: video("c", start: 3, duration: 2), on: v)
        }
        let captions = Clip(source: ClipSource(id: "caption:x", kind: .captions, displayName: "x"), start: 0, duration: 3)
        #expect(throws: TimelineEditError.kindNotAllowed(.captions, on: .video)) {
            try TimelineEditor.insert(&t, clip: captions, on: v)
        }
        try TimelineEditor.insert(&t, clip: video("c", start: 2, duration: 3), on: v, ripple: true)
        let starts = t[trackID: v]!.sortedClips.map { ($0.source.displayName, $0.start) }
        // "a" (0–4) straddled the insert point and was split around "c".
        #expect(starts.map(\.0) == ["a", "c", "a", "b"])
        #expect(starts.map(\.1) == [0, 2, 5, 7])
        #expect(t.duration == 9)
    }

    @Test("Next free start walks past occupied ranges")
    func nextFree() throws {
        var t = timeline
        let v = videoTrack(t)
        try TimelineEditor.insert(&t, clip: video("a", start: 0, duration: 4), on: v)
        try TimelineEditor.insert(&t, clip: video("b", start: 5, duration: 4), on: v)
        #expect(TimelineEditor.nextFreeStart(t, on: v, at: 1, duration: 1) == 4)
        #expect(TimelineEditor.nextFreeStart(t, on: v, at: 1, duration: 2) == 9)
        #expect(TimelineEditor.nextFreeStart(t, on: v, at: 20, duration: 2) == 20)
    }

    @Test("Move changes start and track, refusing overlaps")
    func move() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 0, duration: 4)
        try TimelineEditor.insert(&t, clip: a, on: v)
        try TimelineEditor.insert(&t, clip: video("b", start: 6, duration: 2), on: v)
        try TimelineEditor.move(&t, clipID: a.id, to: 2)
        #expect(t.clip(id: a.id)?.start == 2)
        #expect(throws: TimelineEditError.overlap) { try TimelineEditor.move(&t, clipID: a.id, to: 5) }
        let v2 = TimelineEditor.addTrack(&t, kind: .video)
        try TimelineEditor.move(&t, clipID: a.id, to: 5, onTrack: v2)
        #expect(t.track(containing: a.id)?.id == v2)
        #expect(throws: TimelineEditError.kindNotAllowed(.video, on: .overlay)) {
            try TimelineEditor.move(&t, clipID: a.id, to: 0, onTrack: t.tracks.first { $0.kind == .overlay }!.id)
        }
    }

    @Test("Trimming preserves the opposite edge and clamps to the source")
    func trim() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 2, duration: 6)
        try TimelineEditor.insert(&t, clip: a, on: v)
        try TimelineEditor.trimLeading(&t, clipID: a.id, by: 1)
        var c = t.clip(id: a.id)!
        #expect(c.start == 3 && c.duration == 5 && c.inPoint == 1 && c.end == 8)
        try TimelineEditor.trimLeading(&t, clipID: a.id, by: -5)   // only 1 s of in-point available
        c = t.clip(id: a.id)!
        #expect(c.start == 2 && c.inPoint == 0 && c.end == 8)
        try TimelineEditor.trimTrailing(&t, clipID: a.id, by: 4, maximumDuration: 8)
        #expect(t.clip(id: a.id)?.duration == 8)
        try TimelineEditor.trimTrailing(&t, clipID: a.id, by: -100)
        #expect(t.clip(id: a.id)?.duration == t.frameDuration)
    }

    @Test("Split keeps total duration and offsets the right half's in point")
    func split() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 1, duration: 6)
        try TimelineEditor.insert(&t, clip: a, on: v)
        let right = try #require(try TimelineEditor.split(&t, clipID: a.id, at: 4))
        let l = t.clip(id: a.id)!, r = t.clip(id: right)!
        #expect(l.start == 1 && l.duration == 3)
        #expect(r.start == 4 && r.duration == 3 && r.inPoint == 3)
        #expect(t[trackID: v]!.clips.count == 2)
        #expect(try TimelineEditor.split(&t, clipID: a.id, at: 0.5) == nil)
    }

    @Test("Ripple delete closes the gap, remove leaves it")
    func deletion() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 0, duration: 2), b = video("b", start: 2, duration: 2), c = video("c", start: 6, duration: 1)
        for clip in [a, b, c] { try TimelineEditor.insert(&t, clip: clip, on: v) }
        try TimelineEditor.rippleDelete(&t, clipID: a.id)
        #expect(t.clip(id: b.id)?.start == 0)
        #expect(t.clip(id: c.id)?.start == 4)
        TimelineEditor.remove(&t, clipID: b.id)
        #expect(t.clip(id: c.id)?.start == 4)
        #expect(t.allClips.count == 1)
    }

    @Test("Snapping picks the nearest edge inside the tolerance")
    func snapping() throws {
        var t = timeline
        let v = videoTrack(t)
        try TimelineEditor.insert(&t, clip: video("a", start: 1, duration: 2), on: v)
        let points = TimelineEditor.snapPoints(t)
        #expect(points == [0, 1, 3])
        #expect(TimelineEditor.snapped(2.9, to: points, tolerance: 0.2) == 3)
        #expect(TimelineEditor.snapped(2.5, to: points, tolerance: 0.2) == 2.5)
    }

    @Test("Audio tracks take audio and video sources; overlays take captions and stills")
    func trackKinds() {
        #expect(TrackKind.audio.accepts(.audio) && TrackKind.audio.accepts(.video) && !TrackKind.audio.accepts(.image))
        #expect(TrackKind.overlay.accepts(.captions) && TrackKind.overlay.accepts(.image) && !TrackKind.overlay.accepts(.video))
        #expect(TrackKind.video.accepts(.remotion) && !TrackKind.video.accepts(.audio))
    }
}
