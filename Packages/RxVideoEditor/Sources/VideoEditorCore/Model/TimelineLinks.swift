import Foundation

public extension Timeline {
    /// Explicit edit groups only. Transition joins deliberately do not trim together.
    func editLinkedClipIDs(_ selection: Set<UUID>) -> Set<UUID> {
        let groups = Set(allClips.filter { selection.contains($0.id) }.compactMap(\.linkGroupID))
        return selection.union(allClips.filter { $0.linkGroupID.map(groups.contains) ?? false }.map(\.id))
    }
}

public extension TimelineEditor {
    @discardableResult
    static func link(_ timeline: inout Timeline, clipIDs: Set<UUID>) throws -> UUID {
        guard clipIDs.count > 1 else { throw TimelineEditError.unsupportedOperation }
        for id in clipIDs where timeline.clip(id: id) == nil { throw TimelineEditError.unknownClip(id) }
        let members = timeline.editLinkedClipIDs(clipIDs)
        let group = UUID()
        for t in timeline.tracks.indices {
            for c in timeline.tracks[t].clips.indices where members.contains(timeline.tracks[t].clips[c].id) {
                timeline.tracks[t].clips[c].linkGroupID = group
            }
        }
        return group
    }

    static func unlink(_ timeline: inout Timeline, clipIDs: Set<UUID>) {
        let members = timeline.editLinkedClipIDs(clipIDs)
        for t in timeline.tracks.indices {
            for c in timeline.tracks[t].clips.indices where members.contains(timeline.tracks[t].clips[c].id) {
                timeline.tracks[t].clips[c].linkGroupID = nil
            }
        }
    }

    static func setTrackAlias(_ timeline: inout Timeline, trackID: UUID, alias: String?) throws {
        guard let index = timeline.tracks.firstIndex(where: { $0.id == trackID }) else { throw TimelineEditError.unknownTrack(trackID) }
        let value = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        timeline.tracks[index].alias = value?.isEmpty == false ? value : nil
    }

    internal static func editLinkedTrim(_ timeline: inout Timeline, clipID: UUID, leading: Bool, delta: Double, minimumDuration: Double?, maximumDuration: Double?, sourceDuration: Double?) throws {
        guard delta.isFinite else { throw TimelineEditError.invalidDuration }
        let members = timeline.editLinkedClipIDs([clipID])
        let group = timeline.clip(id: clipID)?.linkGroupID
        var draft = timeline
        unlink(&draft, clipIDs: members)
        let expected = timeline.quantized(abs(delta)) * (delta < 0 ? -1 : 1)
        for id in members {
            guard let old = draft.clip(id: id) else { throw TimelineEditError.unknownClip(id) }
            if leading {
                try trimLeading(&draft, clipID: id, by: expected, minimumDuration: minimumDuration, sourceDuration: id == clipID ? sourceDuration : nil)
            } else {
                try trimTrailing(&draft, clipID: id, by: expected, maximumDuration: id == clipID ? maximumDuration : nil, minimumDuration: minimumDuration, sourceDuration: id == clipID ? sourceDuration : nil)
            }
            guard let new = draft.clip(id: id), abs((leading ? new.start - old.start : new.end - old.end) - expected) < 0.000001 else {
                throw TimelineEditError.invalidDuration
            }
        }
        for t in draft.tracks.indices {
            for c in draft.tracks[t].clips.indices where members.contains(draft.tracks[t].clips[c].id) { draft.tracks[t].clips[c].linkGroupID = group }
        }
        try draft.validateModifiers()
        timeline = draft
    }

    internal static func splitLinked(_ timeline: inout Timeline, clipID: UUID, at time: Double) throws -> UUID? {
        guard time.isFinite, let selected = timeline.clip(id: clipID) else { throw TimelineEditError.invalidDuration }
        let cut = timeline.quantized(time)
        guard cut > selected.start + timeline.frameDuration / 2, cut < selected.end - timeline.frameDuration / 2 else { return nil }
        let members = timeline.editLinkedClipIDs([clipID])
        var draft = timeline
        unlink(&draft, clipIDs: members)
        let leftGroup = UUID(), rightGroup = UUID()
        var sides: [UUID: UUID] = [:]
        var result: UUID?
        for id in members {
            guard let clip = draft.clip(id: id) else { continue }
            if let right = try split(&draft, clipID: id, at: cut) {
                sides[id] = leftGroup; sides[right] = rightGroup
                if id == clipID { result = right }
            } else { sides[id] = clip.start >= cut ? rightGroup : leftGroup }
        }
        for t in draft.tracks.indices {
            for c in draft.tracks[t].clips.indices {
                if let side = sides[draft.tracks[t].clips[c].id] {
                    draft.tracks[t].clips[c].linkGroupID = sides.values.filter { $0 == side }.count > 1 ? side : nil
                }
            }
        }
        try draft.validateModifiers()
        timeline = draft
        return result
    }
}
