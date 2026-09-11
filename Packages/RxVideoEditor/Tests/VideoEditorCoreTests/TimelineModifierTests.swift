import Foundation
import Testing
import VideoEffectsCore
@testable import VideoEditorCore

@Suite("Timeline effects and transitions")
struct TimelineModifierTests {
    func pair() -> (Timeline, UUID, UUID) {
        let source = ClipSource(id: "picture", kind: .video, displayName: "Picture")
        let a = Clip(source: source, start: 0, duration: 4, inPoint: 2, sourceDuration: 10)
        let b = Clip(source: source, start: 4, duration: 4, inPoint: 2, sourceDuration: 10)
        return (Timeline(tracks: [Track(kind: .video, name: "V1", clips: [a, b])]), a.id, b.id)
    }
    @Test func persistenceAndLegacyDefaults() throws {
        var (timeline, a, b) = pair()
        try TimelineEditor.addEffect(&timeline, definitionID: "rx.saturation", clipID: a)
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a, incoming: b))
        #expect(try TimelineCodec.decode(TimelineCodec.encode(timeline)) == timeline)
        var envelope = try #require(JSONSerialization.jsonObject(with: TimelineCodec.encode(timeline)) as? [String: Any])
        var json = try #require(envelope["timeline"] as? [String: Any])
        json.removeValue(forKey: "transitions")
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        var clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        for i in clips.indices { clips[i].removeValue(forKey: "effects") }
        tracks[0]["clips"] = clips; json["tracks"] = tracks; envelope["timeline"] = json
        let legacy = try TimelineCodec.decode(JSONSerialization.data(withJSONObject: envelope))
        #expect(legacy.transitions.isEmpty)
        #expect(legacy.allClips.allSatisfy { $0.effects.isEmpty })
    }
    @Test func joinedMovementAndAtomicEdits() throws {
        var (timeline, a, b) = pair()
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a, incoming: b))
        let initial = timeline
        #expect(throws: ModifierEditError.self) { try TimelineEditor.trimTrailing(&timeline, clipID: a, by: -1) }
        #expect(timeline == initial)
        #expect(throws: ModifierEditError.self) { try TimelineEditor.changeSpeed(&timeline, clipID: a, rate: 2) }
        #expect(timeline == initial)
        try TimelineEditor.move(&timeline, clipID: b, to: 7)
        #expect(timeline.clip(id: a)?.start == 3)
        #expect(timeline.clip(id: b)?.start == 7)
        #expect(timeline.transitions[0].range(in: timeline) == 6.5..<7.5)
        TimelineEditor.removeTransition(&timeline, id: timeline.transitions[0].id)
        #expect(timeline.linkedClipIDs([a]) == [a])
    }
    @Test func splitAndDeletePreserveOtherClips() throws {
        var (timeline, a, b) = pair()
        try TimelineEditor.addEffect(&timeline, definitionID: "rx.gaussian-blur", clipID: a)
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a, incoming: b))
        let before = timeline
        #expect(throws: ModifierEditError.self) { try TimelineEditor.split(&timeline, clipID: a, at: 3.8) }
        #expect(timeline == before)
        let right = try #require(TimelineEditor.split(&timeline, clipID: a, at: 2))
        #expect(timeline.transitions[0].attachment == .between(outgoing: right, incoming: b))
        #expect(timeline.clip(id: a)?.effects.first?.id != timeline.clip(id: right)?.effects.first?.id)
        #expect(timeline.clip(id: a)?.effects.first?.parameters == timeline.clip(id: right)?.effects.first?.parameters)
        TimelineEditor.remove(&timeline, clipID: right)
        #expect(timeline.transitions.isEmpty)
        #expect(timeline.clip(id: b) != nil)
        #expect(timeline.clip(id: a) != nil)
    }
    @Test func transitionLimitsAndProtectedRippleInsert() throws {
        var (timeline, a, b) = pair()
        let id = try TimelineEditor.addTransition(&timeline, definitionID: "rx.directional-wipe", attachment: .between(outgoing: a, incoming: b))
        let original = timeline
        #expect(throws: ModifierEditError.self) { try TimelineEditor.updateTransition(&timeline, id: id) { $0.duration = 9 } }
        #expect(timeline == original)
        #expect(throws: ModifierEditError.self) { try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a, incoming: b)) }
        let inserted = Clip(source: timeline.allClips[0].source, start: 4, duration: 1)
        #expect(throws: ModifierEditError.self) { try TimelineEditor.insert(&timeline, clip: inserted, on: timeline.tracks[0].id, ripple: true) }
        #expect(timeline == original)
        let startID = try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .start(a), duration: 4)
        let start = try #require(timeline.transitions.first { $0.id == startID })
        #expect(abs(start.duration - 3.5) < 0.000001)
        #expect(timeline.duration == original.duration)
    }
    @Test func unknownDefinitionsMustBeDisabled() throws {
        var (timeline, a, _) = pair()
        try TimelineEditor.update(&timeline, clipID: a) { $0.effects = [EffectInstance(definitionID: "future")] }
        #expect(throws: ModifierEditError.self) { try timeline.validateModifiers(requireDefinitions: true) }
        try TimelineEditor.update(&timeline, clipID: a) { $0.effects[0].isEnabled = false }
        try timeline.validateModifiers(requireDefinitions: true)
        #expect(timeline.allClips[0].effects[0].definitionID == "future")
    }
    @Test func chainedLinksAndOddFrames() throws {
        var (timeline, a, b) = pair()
        let c = Clip(source: timeline.allClips[0].source, start: 8, duration: 4)
        try TimelineEditor.insert(&timeline, clip: c, on: timeline.tracks[0].id)
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: a, incoming: b), duration: 7 / 30)
        try TimelineEditor.addTransition(&timeline, definitionID: "rx.cross-dissolve", attachment: .between(outgoing: b, incoming: c.id))
        #expect(timeline.linkedClipIDs([a]) == [a, b, c.id])
        let range = try #require(timeline.transitions[0].range(in: timeline))
        #expect(abs(range.lowerBound * 30 - (range.lowerBound * 30).rounded()) < 0.000001)
        #expect(abs(range.upperBound * 30 - (range.upperBound * 30).rounded()) < 0.000001)
    }
}
