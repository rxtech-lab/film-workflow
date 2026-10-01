import Foundation
import Testing

@testable import VideoEditorCore

@Suite("Timeline gaps")
struct TimelineGapTests {
    private func clip(_ name: String, _ kind: SourceKind = .video, start: TimeInterval, duration: TimeInterval, sourceDuration: TimeInterval? = nil) -> Clip {
        Clip(source: ClipSource(id: "\(kind.rawValue):\(name)", kind: kind, displayName: name), start: start, duration: duration, sourceDuration: sourceDuration)
    }

    private func track(_ t: Timeline, _ name: String) -> UUID { t.tracks.first { $0.name == name }!.id }

    private func gaps(_ t: Timeline, _ name: String) -> [TimelineGap] {
        TimelineGapAnalyzer.analyze(t).first { $0.trackID == track(t, name) }?.gaps ?? []
    }

    @Test("A hole on the only picture lane is a blank screen; one covered by another lane is not")
    func blankScreen() throws {
        var t = Timeline(fps: 30)
        let v1 = track(t, "V1")
        try TimelineEditor.insert(&t, clip: clip("a", start: 0, duration: 4), on: v1)
        try TimelineEditor.insert(&t, clip: clip("b", start: 6, duration: 4), on: v1)
        let hole = try #require(gaps(t, "V1").first)
        #expect(hole.position == .between)
        #expect(hole.start == 4 && hole.end == 6)
        #expect(hole.issues == [.blankScreen])
        #expect(TimelineGapAnalyzer.blankPicture(t) == [4..<6])

        let v2 = TimelineEditor.addTrack(&t, kind: .video)
        try TimelineEditor.insert(&t, clip: clip("cover", .image, start: 3, duration: 4), on: v2)
        let covered = try #require(gaps(t, "V1").first)
        #expect(covered.issues.isEmpty)
        #expect(covered.coveredBy == [v2])
        #expect(TimelineGapAnalyzer.blankPicture(t).isEmpty)
    }

    @Test("A few frames between clips is a flash, and it breaks a transition joining them")
    func flashAndTransition() throws {
        var t = Timeline(fps: 30)
        let v1 = track(t, "V1")
        let a = clip("a", start: 0, duration: 2)
        let b = clip("b", start: 2 + 2.0 / 30, duration: 2)
        try TimelineEditor.insert(&t, clip: a, on: v1)
        try TimelineEditor.insert(&t, clip: b, on: v1)
        t.transitions = [TransitionInstance(definitionID: "fade", attachment: .between(outgoing: a.id, incoming: b.id))]
        let gap = try #require(gaps(t, "V1").first)
        #expect(Set(gap.issues) == [.blankScreen, .flash, .breaksTransition])
    }

    @Test("Audio gaps are silence only when nothing else is heard; trailing gaps reach the sequence end")
    func audio() throws {
        var t = Timeline(fps: 30)
        let a1 = track(t, "A1"), a2 = track(t, "A2"), v1 = track(t, "V1")
        try TimelineEditor.insert(&t, clip: clip("v", start: 0, duration: 10), on: v1)
        try TimelineEditor.insert(&t, clip: clip("n1", .audio, start: 0, duration: 3), on: a1)
        try TimelineEditor.insert(&t, clip: clip("n2", .audio, start: 5, duration: 3), on: a1)
        // The video clip carries sound across the whole gap.
        #expect(gaps(t, "A1").first?.issues == [])
        t.tracks[t.tracks.firstIndex { $0.id == v1 }!].isMuted = true
        #expect(gaps(t, "A1").first?.issues == [.silence])
        try TimelineEditor.insert(&t, clip: clip("m", .audio, start: 2, duration: 4), on: a2)
        #expect(gaps(t, "A1").first?.issues == [])
        let trailing = try #require(gaps(t, "A1").last)
        #expect(trailing.position == .trailing && trailing.end == 10)
    }

    @Test("Disabled clips leave a gap; empty lanes report nothing")
    func disabled() throws {
        var t = Timeline(fps: 30)
        let v1 = track(t, "V1")
        let b = clip("b", start: 2, duration: 2)
        try TimelineEditor.insert(&t, clip: clip("a", start: 0, duration: 2), on: v1)
        try TimelineEditor.insert(&t, clip: b, on: v1)
        try TimelineEditor.insert(&t, clip: clip("c", start: 4, duration: 2), on: v1)
        #expect(gaps(t, "V1").isEmpty)
        try TimelineEditor.setEnabled(&t, clipIDs: [b.id], isEnabled: false)
        #expect(gaps(t, "V1").map(\.range) == [2..<4])
        #expect(TimelineGapAnalyzer.analyze(t).count == 1)
    }

    @Test("Closing a gap by ripple, or by extending the clip on either side")
    func close() throws {
        var t = Timeline(fps: 30)
        let v1 = track(t, "V1")
        let a = clip("a", .image, start: 0, duration: 4)
        let b = clip("b", start: 6, duration: 4, sourceDuration: 20)
        try TimelineEditor.insert(&t, clip: a, on: v1)
        try TimelineEditor.insert(&t, clip: b, on: v1)

        var rippled = t
        try TimelineEditor.closeGap(&rippled, trackID: v1, at: 4, fill: .ripple)
        #expect(rippled.clip(id: b.id)?.start == 4)
        #expect(TimelineGapAnalyzer.blankPicture(rippled).isEmpty)

        var extended = t
        try TimelineEditor.closeGap(&extended, trackID: v1, at: 5, fill: .extendPrevious)
        #expect(extended.clip(id: a.id)?.end == 6)

        var pulled = t
        try TimelineEditor.closeGap(&pulled, trackID: v1, at: 4, fill: .extendNext)
        // `b` starts at 0 in its source, so there is nothing earlier to show.
        #expect(pulled.clip(id: b.id)?.start == 6)

        #expect(throws: TimelineEditError.unsupportedOperation) {
            try TimelineEditor.closeGap(&t, trackID: v1, at: 1, fill: .ripple)
        }
    }
}
