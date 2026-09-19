import Foundation
import VideoEffectsCore

public enum TransitionAttachment: Codable, Hashable, Sendable {
    case start(UUID)
    case end(UUID)
    case between(outgoing: UUID, incoming: UUID)

    public var clipIDs: Set<UUID> {
        switch self {
        case .start(let id), .end(let id): return [id]
        case .between(let a, let b): return [a, b]
        }
    }
    public var isPair: Bool { if case .between = self { return true }; return false }
}

public struct TransitionInstance: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var definitionID: String
    public var parameters: ModifierParameters
    public var attachment: TransitionAttachment
    public var duration: TimeInterval
    public var isEnabled: Bool

    public init(id: UUID = UUID(), definitionID: String, parameters: ModifierParameters = [:], attachment: TransitionAttachment,
                duration: TimeInterval = 1, isEnabled: Bool = true) {
        self.id = id; self.definitionID = definitionID; self.parameters = parameters
        self.attachment = attachment; self.duration = duration; self.isEnabled = isEnabled
    }

    public func range(in timeline: Timeline) -> Range<TimeInterval>? {
        switch attachment {
        case .start(let id):
            guard let clip = timeline.clip(id: id) else { return nil }
            return clip.start..<(clip.start + duration)
        case .end(let id):
            guard let clip = timeline.clip(id: id) else { return nil }
            return (clip.end - duration)..<clip.end
        case .between(let a, let b):
            guard let left = timeline.clip(id: a), let right = timeline.clip(id: b),
                  abs(left.end - right.start) < 0.000001 else { return nil }
            // Keep the entire duration on the frame grid, including odd frame counts.
            let leading = floor(duration / timeline.frameDuration / 2 + 0.000001) * timeline.frameDuration
            return (left.end - leading)..<(left.end + duration - leading)
        }
    }
}

public enum ModifierEditError: LocalizedError {
    case incompatibleTarget, brokenJoin, overlappingTransitions, invalidDuration, unknownDefinition, missingInstance, cutInTransition
    public var errorDescription: String? {
        switch self {
        case .incompatibleTarget: return "Use a video, image or Remotion clip on a picture track. Joined clips must touch on the same track."
        case .brokenJoin: return "This edit would break a transition. Remove the transition first, or move the linked clips together."
        case .overlappingTransitions: return "There is already a transition here. Shorten or remove it first."
        case .invalidDuration: return "The transition must fit inside its clips, last at least one frame, and not overlap another transition."
        case .unknownDefinition: return "An effect or transition is unavailable. Disable or remove it before exporting."
        case .missingInstance: return "This effect or transition is no longer available."
        case .cutInTransition: return "Move the cut outside the transition, or remove the transition first."
        }
    }
}

public extension Timeline {
    func acceptsModifiers(on clipID: UUID) -> Bool {
        guard let clip = clip(id: clipID), let track = track(containing: clipID), track.kind != .audio else { return false }
        return [.video, .image, .remotion].contains(clip.source.kind)
    }
    var hasActiveModifiers: Bool {
        allClips.contains { $0.effects.contains(where: \.isEnabled) } || transitions.contains(where: \.isEnabled)
    }
    func linkedClipIDs(_ selection: Set<UUID>) -> Set<UUID> {
        var result = selection
        var changed = true
        while changed {
            let old = result
            result.formUnion(editLinkedClipIDs(result))
            for transition in transitions where transition.attachment.isPair && !result.isDisjoint(with: transition.attachment.clipIDs) {
                result.formUnion(transition.attachment.clipIDs)
            }
            changed = result != old
        }
        return result
    }
    func validateModifiers(requireDefinitions: Bool = false) throws {
        let catalog = ModifierCatalog.current
        for clip in allClips where !clip.effects.isEmpty {
            guard acceptsModifiers(on: clip.id) else { throw ModifierEditError.incompatibleTarget }
            if requireDefinitions && clip.effects.contains(where: { $0.isEnabled && catalog.effect($0.definitionID) == nil }) {
                throw ModifierEditError.unknownDefinition
            }
        }
        var ranges: [(TransitionInstance, Range<TimeInterval>)] = []
        for item in transitions {
            guard item.duration.isFinite, item.duration >= frameDuration - 0.000001 else { throw ModifierEditError.invalidDuration }
            guard item.attachment.clipIDs.allSatisfy({ acceptsModifiers(on: $0) }) else { throw ModifierEditError.incompatibleTarget }
            if case .between(let a, let b) = item.attachment {
                guard a != b, track(containing: a)?.id == track(containing: b)?.id else { throw ModifierEditError.brokenJoin }
            }
            guard let range = item.range(in: self) else { throw ModifierEditError.brokenJoin }
            let clips = item.attachment.clipIDs.compactMap { clip(id: $0) }
            guard let lower = clips.map(\.start).min(), let upper = clips.map(\.end).max(),
                  range.lowerBound >= lower - 0.000001, range.upperBound <= upper + 0.000001 else { throw ModifierEditError.invalidDuration }
            // Two transitions sharing a clip may touch but cannot cover the same frames.
            if ranges.contains(where: { !$0.0.attachment.clipIDs.isDisjoint(with: item.attachment.clipIDs)
                && $0.1.lowerBound < range.upperBound - 0.000001 && range.lowerBound < $0.1.upperBound - 0.000001 }) {
                throw ModifierEditError.overlappingTransitions
            }
            ranges.append((item, range))
            if requireDefinitions && item.isEnabled && catalog.transition(item.definitionID) == nil { throw ModifierEditError.unknownDefinition }
        }
    }
}

public extension TimelineEditor {
    @discardableResult
    static func addEffect(_ timeline: inout Timeline, definitionID: String, clipID: UUID) throws -> UUID {
        guard timeline.acceptsModifiers(on: clipID) else { throw ModifierEditError.incompatibleTarget }
        guard let definition = ModifierCatalog.current.effect(definitionID) else { throw ModifierEditError.unknownDefinition }
        let effect = EffectInstance(definitionID: definitionID, parameters: definition.defaults)
        try update(&timeline, clipID: clipID) { $0.effects.append(effect) }
        return effect.id
    }

    @discardableResult
    static func addTransition(_ timeline: inout Timeline, definitionID: String, attachment: TransitionAttachment, duration: Double = 1) throws -> UUID {
        guard let definition = ModifierCatalog.current.transition(definitionID) else { throw ModifierEditError.unknownDefinition }
        guard duration.isFinite, duration > 0 else { throw ModifierEditError.invalidDuration }
        guard !timeline.transitions.contains(where: { $0.attachment == attachment }) else { throw ModifierEditError.overlappingTransitions }
        var item = TransitionInstance(definitionID: definitionID, parameters: definition.defaults, attachment: attachment, duration: duration)
        // Find the largest legal initial duration without changing any existing transition.
        let frames = max(1, Int((min(duration, max(timeline.duration, timeline.frameDuration)) / timeline.frameDuration).rounded()))
        var lastError: Error = ModifierEditError.invalidDuration
        for count in stride(from: frames, through: 1, by: -1) {
            item.duration = Double(count) * timeline.frameDuration
            var candidate = timeline
            candidate.transitions.append(item)
            do { try candidate.validateModifiers(); timeline = candidate; return item.id }
            catch { lastError = error }
        }
        throw lastError
    }

    static func updateTransition(_ timeline: inout Timeline, id: UUID, _ change: (inout TransitionInstance) -> Void) throws {
        guard let index = timeline.transitions.firstIndex(where: { $0.id == id }) else { throw ModifierEditError.missingInstance }
        var candidate = timeline
        change(&candidate.transitions[index])
        let duration = candidate.transitions[index].duration
        guard duration.isFinite else { throw ModifierEditError.invalidDuration }
        candidate.transitions[index].duration = candidate.quantized(duration)
        try candidate.validateModifiers()
        timeline = candidate
    }

    static func removeTransition(_ timeline: inout Timeline, id: UUID) {
        timeline.transitions.removeAll { $0.id == id }
    }
}
