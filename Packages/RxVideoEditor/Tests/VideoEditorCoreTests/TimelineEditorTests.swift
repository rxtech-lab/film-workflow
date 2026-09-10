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

    @Test("Align takes the target's start, in point and length on the clip's own track")
    func alignWithOrigin() throws {
        var t = timeline
        let a = audioTrack(t)
        let overlay = t.tracks.first { $0.kind == .overlay }!.id
        var narration = Clip(source: ClipSource(id: "narration:n", kind: .audio, displayName: "n"), start: 6, duration: 5)
        narration.inPoint = 1.5
        try TimelineEditor.insert(&t, clip: narration, on: a)
        let captions = Clip(source: ClipSource(id: "caption:c", kind: .captions, displayName: "c"), start: 0, duration: 3)
        try TimelineEditor.insert(&t, clip: captions, on: overlay)

        try TimelineEditor.align(&t, clipID: captions.id, with: narration.id)
        let aligned = try #require(t.clip(id: captions.id))
        #expect(aligned.start == 6)
        #expect(aligned.inPoint == 1.5)
        #expect(aligned.duration == 5)
        #expect(t.track(containing: captions.id)?.id == overlay)

        // Still (fixed-length) clips only move.
        var still = Clip(source: ClipSource(id: "image:i", kind: .image, displayName: "i", capabilities: [.drag]), start: 0, duration: 2)
        still.inPoint = 0
        try TimelineEditor.insert(&t, clip: still, on: videoTrack(t))
        try TimelineEditor.align(&t, clipID: still.id, with: narration.id)
        #expect(t.clip(id: still.id)?.start == 6)
        #expect(t.clip(id: still.id)?.duration == 2)

        // Anything already occupying the target span blocks the move.
        let blocker = Clip(source: ClipSource(id: "caption:b", kind: .captions, displayName: "b"), start: 12, duration: 2)
        try TimelineEditor.insert(&t, clip: blocker, on: overlay)
        try TimelineEditor.move(&t, clipID: narration.id, to: 11)
        #expect(throws: TimelineEditError.overlap) { try TimelineEditor.align(&t, clipID: captions.id, with: narration.id) }
        #expect(t.clip(id: captions.id)?.start == 6)
        #expect(throws: TimelineEditError.unknownClip(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try TimelineEditor.align(&t, clipID: captions.id, with: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        }
        #expect(throws: TimelineEditError.unsupportedOperation) { try TimelineEditor.align(&t, clipID: captions.id, with: captions.id) }
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

    @Test("A group moves together, keeps its layout and stops at zero")
    func groupMove() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 1, duration: 2)
        let b = video("b", start: 4, duration: 2)
        let c = video("c", start: 8, duration: 1)
        try TimelineEditor.insert(&t, clip: a, on: v)
        try TimelineEditor.insert(&t, clip: b, on: v)
        try TimelineEditor.insert(&t, clip: c, on: v)

        try TimelineEditor.move(&t, clipIDs: [a.id, b.id], by: 1)
        #expect(t.clip(id: a.id)?.start == 2)
        #expect(t.clip(id: b.id)?.start == 5)
        #expect(t.clip(id: c.id)?.start == 8)

        // Too far left: the earliest clip stops at zero and the rest follow.
        try TimelineEditor.move(&t, clipIDs: [a.id, b.id], by: -10)
        #expect(t.clip(id: a.id)?.start == 0)
        #expect(t.clip(id: b.id)?.start == 3)

        // Landing on c would overlap, so nothing moves.
        let before = t
        #expect(throws: TimelineEditError.overlap) {
            try TimelineEditor.move(&t, clipIDs: [a.id, b.id], by: 4.5)
        }
        #expect(t == before)
        #expect(t[trackID: v]!.sortedClips.map(\.id) == [a.id, b.id, c.id])
    }

    @Test("A group changes lane only when every clip fits the new lane")
    func groupLaneShift() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 0, duration: 2)
        let b = video("b", start: 3, duration: 2)
        try TimelineEditor.insert(&t, clip: a, on: v)
        try TimelineEditor.insert(&t, clip: b, on: v)

        // Video lane sits under the overlay lane and above the audio lanes.
        #expect(TimelineEditor.canShiftLanes(t, clipIDs: [a.id, b.id], by: 1))
        #expect(!TimelineEditor.canShiftLanes(t, clipIDs: [a.id, b.id], by: -1))
        #expect(!TimelineEditor.canShiftLanes(t, clipIDs: [a.id, b.id], by: 3))
        #expect(TimelineEditor.canShiftLanes(t, clipIDs: [a.id, b.id], by: 0))

        try TimelineEditor.move(&t, clipIDs: [a.id, b.id], by: 1, laneOffset: 1)
        let audio = audioTrack(t)
        #expect(t.track(containing: a.id)?.id == audio)
        #expect(t.track(containing: b.id)?.id == audio)
        #expect(t.clip(id: a.id)?.start == 1)
        #expect(t.clip(id: b.id)?.start == 4)
        #expect(t[trackID: v]!.clips.isEmpty)

        #expect(throws: TimelineEditError.kindNotAllowed(.video, on: .overlay)) {
            try TimelineEditor.move(&t, clipIDs: [a.id, b.id], by: 0, laneOffset: -2)
        }
    }

    @Test("Removing and ripple deleting several clips at once")
    func groupDelete() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 0, duration: 2)
        let b = video("b", start: 2, duration: 2)
        let c = video("c", start: 4, duration: 2)
        let d = video("d", start: 6, duration: 2)
        try TimelineEditor.insert(&t, clip: a, on: v)
        try TimelineEditor.insert(&t, clip: b, on: v)
        try TimelineEditor.insert(&t, clip: c, on: v)
        try TimelineEditor.insert(&t, clip: d, on: v)

        var plain = t
        TimelineEditor.remove(&plain, clipIDs: [a.id, c.id])
        #expect(plain[trackID: v]!.sortedClips.map(\.id) == [b.id, d.id])
        #expect(plain.clip(id: d.id)?.start == 6)

        try TimelineEditor.rippleDelete(&t, clipIDs: [a.id, c.id])
        #expect(t[trackID: v]!.sortedClips.map(\.id) == [b.id, d.id])
        #expect(t.clip(id: b.id)?.start == 0)
        #expect(t.clip(id: d.id)?.start == 2)
    }

    @Test("A selection rectangle picks the clips it touches on the lanes it spans")
    func marqueeQuery() throws {
        var t = timeline
        let v = videoTrack(t)
        let a = video("a", start: 0, duration: 2)
        let b = video("b", start: 5, duration: 2)
        let onAudio = video("audio", start: 1, duration: 2)
        try TimelineEditor.insert(&t, clip: a, on: v)
        try TimelineEditor.insert(&t, clip: b, on: v)
        try TimelineEditor.insert(&t, clip: onAudio, on: audioTrack(t))
        let videoLane = t.tracks.firstIndex { $0.id == v }!
        let audioLane = t.tracks.firstIndex { $0.id == audioTrack(t) }!

        #expect(TimelineEditor.clipIDs(t, intersecting: 1...1.5, trackIndices: videoLane...videoLane) == [a.id])
        #expect(TimelineEditor.clipIDs(t, intersecting: 1...6, trackIndices: videoLane...videoLane) == [a.id, b.id])
        #expect(TimelineEditor.clipIDs(t, intersecting: 1...1.5, trackIndices: videoLane...audioLane) == [a.id, onAudio.id])
        // Touching only the gap, or only an edge, selects nothing.
        #expect(TimelineEditor.clipIDs(t, intersecting: 3...4, trackIndices: videoLane...audioLane).isEmpty)
        #expect(TimelineEditor.clipIDs(t, intersecting: 2...5, trackIndices: videoLane...videoLane).isEmpty)
        #expect(TimelineEditor.snapPoints(t, excluding: [a.id, b.id]) == [0, 1, 3])
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
