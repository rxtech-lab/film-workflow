import Foundation
import VideoEffectsCore

public enum TimelineEditError: Error, Equatable, Sendable {
    case unknownTrack(UUID)
    case unknownClip(UUID)
    case kindNotAllowed(SourceKind, on: TrackKind)
    case overlap
    case invalidDuration
    case invalidSpeed
    case unsupportedOperation
    case invalidTrackOrder
}

/// Pure editing operations on a `Timeline`. Every operation validates the
/// result so the timeline can never hold overlapping clips on one track.
public enum TimelineEditor {
    /// The edge held in place while the same source range changes length.
    public enum RetimeAnchor: Sendable { case start, end }
    /// Inserts a clip on a track. When `ripple` is set, later clips on that
    /// track shift right to make room; otherwise an overlap is an error.
    public static func insert(
        _ timeline: inout Timeline,
        clip: Clip,
        on trackID: UUID,
        ripple: Bool = false
    ) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard let index = timeline.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw TimelineEditError.unknownTrack(trackID)
        }
        guard clip.duration.isFinite, clip.duration > 0, clip.start.isFinite,
              clip.inPoint.isFinite, clip.inPoint >= 0 else { throw TimelineEditError.invalidDuration }
        guard clip.playbackRate.isFinite, clip.playbackRate > 0, clip.sourceRangeDuration.isFinite else { throw TimelineEditError.invalidSpeed }
        guard timeline.tracks[index].kind.accepts(clip.source.kind) else {
            throw TimelineEditError.kindNotAllowed(clip.source.kind, on: timeline.tracks[index].kind)
        }
        var clip = clip
        clip.start = timeline.quantized(clip.start)
        if ripple {
            // A clip straddling the insert point is split there, then everything
            // from the point onwards moves right by the inserted length.
            if let straddling = timeline.tracks[index].clips.first(where: { $0.start < clip.start && clip.start < $0.end }) {
                try split(&timeline, clipID: straddling.id, at: clip.start)
            }
            for i in timeline.tracks[index].clips.indices
            where timeline.tracks[index].clips[i].start >= clip.start {
                timeline.tracks[index].clips[i].start += clip.duration
            }
        } else if timeline.tracks[index].clips.contains(where: { $0.overlaps(clip) }) {
            throw TimelineEditError.overlap
        }
        timeline.tracks[index].clips.append(clip)
        timeline.tracks[index].clips.sort { $0.start < $1.start }
        try timeline.validateModifiers()
        committed = true
    }

    /// Appends a clip after the last clip on the track.
    public static func append(_ timeline: inout Timeline, clip: Clip, on trackID: UUID) throws {
        guard let track = timeline[trackID: trackID] else { throw TimelineEditError.unknownTrack(trackID) }
        var clip = clip
        clip.start = track.end
        try insert(&timeline, clip: clip, on: trackID)
    }

    /// The first free stretch on a track at or after `time` that fits `duration`.
    public static func nextFreeStart(_ timeline: Timeline, on trackID: UUID, at time: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard let track = timeline[trackID: trackID] else { return nil }
        var candidate = max(0, timeline.quantized(time))
        for clip in track.sortedClips {
            if clip.end <= candidate { continue }
            if clip.start >= candidate + duration { break }
            candidate = clip.end
        }
        return candidate
    }

    /// Moves a clip to a new start, optionally onto another track.
    public static func move(
        _ timeline: inout Timeline,
        clipID: UUID,
        to start: TimeInterval,
        onTrack trackID: UUID? = nil
    ) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard let fromIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        let destinationID = trackID ?? timeline.tracks[fromIndex].id
        guard let toIndex = timeline.tracks.firstIndex(where: { $0.id == destinationID }) else { throw TimelineEditError.unknownTrack(destinationID) }
        try move(&timeline, clipIDs: [clipID], by: timeline.quantized(max(0, start)) - clip.start, laneOffset: toIndex - fromIndex)
        try timeline.validateModifiers()
        committed = true
    }

    /// Whether every clip in `clipIDs` can shift `laneOffset` tracks: the
    /// target lane exists and takes the clip's kind. Zero is always allowed.
    public static func canShiftLanes(_ timeline: Timeline, clipIDs: Set<UUID>, by laneOffset: Int) -> Bool {
        let clipIDs = timeline.linkedClipIDs(clipIDs)
        guard laneOffset != 0 else { return true }
        for (index, track) in timeline.tracks.enumerated() {
            for clip in track.clips where clipIDs.contains(clip.id) {
                let target = index + laneOffset
                guard timeline.tracks.indices.contains(target),
                      timeline.tracks[target].kind.accepts(clip.source.kind) else { return false }
            }
        }
        return true
    }

    /// Moves several clips together by the same time delta, optionally
    /// shifting all of them `laneOffset` tracks. The group keeps its relative
    /// layout exactly: the delta is limited so the earliest clip stops at
    /// zero, and starts are not re-snapped to the frame grid, since rounding
    /// each clip on its own would pull butted neighbours into overlap. Callers
    /// wanting grid alignment pass a whole-frame delta. Either every clip
    /// moves or none does.
    public static func move(
        _ timeline: inout Timeline,
        clipIDs: Set<UUID>,
        by delta: TimeInterval,
        laneOffset: Int = 0
    ) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        let clipIDs = timeline.linkedClipIDs(clipIDs)
        guard delta.isFinite else { throw TimelineEditError.invalidDuration }
        var placements: [(clip: Clip, trackIndex: Int)] = []
        for id in clipIDs {
            guard let fromIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
                  let clip = timeline.clip(id: id) else { throw TimelineEditError.unknownClip(id) }
            guard clip.source.capabilities.contains(.drag) else { throw TimelineEditError.unsupportedOperation }
            let target = fromIndex + laneOffset
            guard timeline.tracks.indices.contains(target) else { throw TimelineEditError.unknownTrack(timeline.tracks[fromIndex].id) }
            guard timeline.tracks[target].kind.accepts(clip.source.kind) else {
                throw TimelineEditError.kindNotAllowed(clip.source.kind, on: timeline.tracks[target].kind)
            }
            placements.append((clip, target))
        }
        guard !placements.isEmpty else { return }

        let earliest = placements.map(\.clip.start).min() ?? 0
        let shift = max(delta, -earliest)
        for i in placements.indices {
            placements[i].clip.start = max(0, placements[i].clip.start + shift)
        }

        // Moved clips may not overlap anything left behind on their target
        // track. They cannot overlap each other: the same shift and lane
        // offset applies to all of them, so their layout is unchanged.
        for (clip, target) in placements {
            let others = timeline.tracks[target].clips.filter { !clipIDs.contains($0.id) }
            guard !others.contains(where: { $0.overlaps(clip) }) else { throw TimelineEditError.overlap }
        }

        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { clipIDs.contains($0.id) }
        }
        for (clip, target) in placements {
            timeline.tracks[target].clips.append(clip)
        }
        for (_, target) in placements {
            timeline.tracks[target].clips.sort { $0.start < $1.start }
        }
        try timeline.validateModifiers()
        committed = true
    }

    /// Lines a clip up with the clip it was derived from, such as captions
    /// transcribed from a narration. The clip takes the target's start, and
    /// when its length can change, the target's in point and duration too, so
    /// cues timed against the target's source play in step with it. The clip
    /// stays on its own track; it may not overlap anything else there.
    public static func align(_ timeline: inout Timeline, clipID: UUID, with targetClipID: UUID) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard clipID != targetClipID else { throw TimelineEditError.unsupportedOperation }
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              var clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        guard let target = timeline.clip(id: targetClipID) else { throw TimelineEditError.unknownClip(targetClipID) }
        guard clip.source.capabilities.contains(.drag) else { throw TimelineEditError.unsupportedOperation }

        clip.start = target.start
        if clip.source.capabilities.contains(.duration) {
            clip.inPoint = target.inPoint
            clip.duration = target.duration
        }
        guard clip.duration > 0 else { throw TimelineEditError.invalidDuration }
        let others = timeline.tracks[trackIndex].clips.filter { $0.id != clipID }
        guard !others.contains(where: { $0.overlaps(clip) }) else { throw TimelineEditError.overlap }

        timeline.tracks[trackIndex].clips.removeAll { $0.id == clipID }
        timeline.tracks[trackIndex].clips.append(clip)
        timeline.tracks[trackIndex].clips.sort { $0.start < $1.start }
        try timeline.validateModifiers()
        committed = true
    }

    /// Trims on the timeline clock while preserving the opposite source edge.
    /// `sourceDuration` lets older clips use a length resolved by the UI.
    public static func trimLeading(_ timeline: inout Timeline, clipID: UUID, by delta: TimeInterval, minimumDuration: TimeInterval? = nil, sourceDuration: TimeInterval? = nil) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard var clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        guard clip.source.capabilities.contains(.duration) else { throw TimelineEditError.unsupportedOperation }
        guard delta.isFinite else { throw TimelineEditError.invalidDuration }
        let minimum = minimumDuration ?? timeline.frameDuration
        var delta = timeline.quantized(abs(delta)) * (delta < 0 ? -1 : 1)
        delta = min(delta, clip.duration - minimum)
        let natural = sourceDuration ?? clip.sourceDuration
        if clip.source.kind != .image {
            if clip.isReversed {
                if let natural { delta = max(delta, -(max(0, natural - clip.sourceEnd) / clip.playbackRate)) }
            } else {
                delta = max(delta, -clip.inPoint / clip.playbackRate)
            }
        }
        delta = max(delta, -clip.start)
        clip.start += delta
        if !clip.isReversed && clip.source.kind != .image { clip.inPoint = max(0, clip.inPoint + delta * clip.playbackRate) }
        clip.duration -= delta
        try replaceTiming(&timeline, clip: clip)
        try timeline.validateModifiers()
        committed = true
    }

    /// Changes the end, limited by available source media and adjacent clips.
    /// `maximumDuration` is measured in timeline seconds.
    public static func trimTrailing(_ timeline: inout Timeline, clipID: UUID, by delta: TimeInterval, maximumDuration: TimeInterval? = nil, minimumDuration: TimeInterval? = nil, sourceDuration: TimeInterval? = nil) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard var clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        guard clip.source.capabilities.contains(.duration) else { throw TimelineEditError.unsupportedOperation }
        guard delta.isFinite else { throw TimelineEditError.invalidDuration }
        let minimum = minimumDuration ?? timeline.frameDuration
        var duration = max(minimum, timeline.quantized(clip.duration + delta))
        if let maximumDuration { duration = min(duration, maximumDuration) }
        if clip.isReversed {
            duration = min(duration, clip.duration + clip.inPoint / clip.playbackRate)
            clip.inPoint = max(0, clip.inPoint + (clip.duration - duration) * clip.playbackRate)
        } else if clip.source.kind != .image, let natural = sourceDuration ?? clip.sourceDuration {
            duration = min(duration, max(0, natural - clip.inPoint) / clip.playbackRate)
        }
        guard duration >= minimum - 0.0000001 else { throw TimelineEditError.invalidDuration }
        clip.duration = duration
        try replaceTiming(&timeline, clip: clip)
        try timeline.validateModifiers()
        committed = true
    }

    /// Positive multiplier (1.2 = 120%), retaining the same source range.
    public static func changeSpeed(_ timeline: inout Timeline, clipID: UUID, rate: Double) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard var clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        guard clip.source.capabilities.contains(.speed) else { throw TimelineEditError.unsupportedOperation }
        guard rate.isFinite, rate > 0 else { throw TimelineEditError.invalidSpeed }
        let duration = clip.sourceRangeDuration / rate
        guard duration.isFinite, duration >= timeline.frameDuration else { throw TimelineEditError.invalidDuration }
        clip.duration = duration
        clip.playbackRate = rate
        try replaceTiming(&timeline, clip: clip)
        try timeline.validateModifiers()
        committed = true
    }

    public static func retime(_ timeline: inout Timeline, clipID: UUID, duration: TimeInterval, anchor: RetimeAnchor = .start) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard var clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        guard clip.source.capabilities.contains(.speed) else { throw TimelineEditError.unsupportedOperation }
        guard duration.isFinite, duration >= timeline.frameDuration else { throw TimelineEditError.invalidDuration }
        let rate = clip.sourceRangeDuration / duration
        guard rate.isFinite, rate > 0 else { throw TimelineEditError.invalidSpeed }
        if anchor == .end {
            let start = clip.end - duration
            guard start >= 0 else { throw TimelineEditError.invalidDuration }
            clip.start = start
        }
        clip.duration = duration
        clip.playbackRate = rate
        try replaceTiming(&timeline, clip: clip)
        try timeline.validateModifiers()
        committed = true
    }

    public static func reverse(_ timeline: inout Timeline, clipID: UUID) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard var clip = timeline.clip(id: clipID) else { throw TimelineEditError.unknownClip(clipID) }
        guard clip.source.capabilities.contains(.reverse) else { throw TimelineEditError.unsupportedOperation }
        clip.isReversed.toggle()
        try replaceTiming(&timeline, clip: clip)
        try timeline.validateModifiers()
        committed = true
    }

    /// Commit atomically only after checking overlap, including speed edits.
    private static func replaceTiming(_ timeline: inout Timeline, clip: Clip) throws {
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clip.id } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clip.id }) else {
            throw TimelineEditError.unknownClip(clip.id)
        }
        guard !timeline.tracks[trackIndex].clips.contains(where: { $0.overlaps(clip) }) else { throw TimelineEditError.overlap }
        timeline.tracks[trackIndex].clips[clipIndex] = clip
    }

    /// Splits a clip at a timeline time. Returns the id of the new right half.
    @discardableResult
    public static func split(_ timeline: inout Timeline, clipID: UUID, at time: TimeInterval) throws -> UUID? {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        let clip = timeline.tracks[trackIndex].clips[clipIndex]
        guard clip.source.capabilities.contains(.cut) else { throw TimelineEditError.unsupportedOperation }
        guard time.isFinite else { throw TimelineEditError.invalidDuration }
        let cut = timeline.quantized(time)
        guard cut > clip.start + timeline.frameDuration / 2, cut < clip.end - timeline.frameDuration / 2 else { return nil }
        if timeline.transitions.contains(where: { transition in
            guard transition.attachment.clipIDs.contains(clipID), let range = transition.range(in: timeline) else { return false }
            return cut > range.lowerBound - 0.000001 && cut < range.upperBound + 0.000001
        }) { throw ModifierEditError.cutInTransition }
        var left = clip
        left.duration = cut - clip.start
        var right = clip
        right.id = UUID()
        for i in right.effects.indices { right.effects[i].id = UUID() }
        right.start = cut
        right.duration = clip.end - cut
        if clip.isReversed {
            left.inPoint = clip.inPoint + right.sourceRangeDuration
        } else if clip.source.kind != .image {
            right.inPoint = clip.inPoint + left.sourceRangeDuration
        }
        timeline.tracks[trackIndex].clips[clipIndex] = left
        timeline.tracks[trackIndex].clips.insert(right, at: clipIndex + 1)
        for i in timeline.transitions.indices {
            switch timeline.transitions[i].attachment {
            case .end(let id) where id == clipID: timeline.transitions[i].attachment = .end(right.id)
            case .between(let a, let b) where a == clipID: timeline.transitions[i].attachment = .between(outgoing: right.id, incoming: b)
            default: break
            }
        }
        try timeline.validateModifiers()
        committed = true
        return right.id
    }

    public static func remove(_ timeline: inout Timeline, clipID: UUID) {
        remove(&timeline, clipIDs: [clipID])
    }

    public static func remove(_ timeline: inout Timeline, clipIDs: Set<UUID>) {
        timeline.transitions.removeAll { !$0.attachment.clipIDs.isDisjoint(with: clipIDs) }
        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { clipIDs.contains($0.id) }
        }
    }

    /// Removes a clip and closes the gap it leaves on its track.
    public static func rippleDelete(_ timeline: inout Timeline, clipID: UUID) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clip = timeline.clip(id: clipID) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        remove(&timeline, clipID: clipID)
        for i in timeline.tracks[trackIndex].clips.indices where timeline.tracks[trackIndex].clips[i].start >= clip.end {
            timeline.tracks[trackIndex].clips[i].start -= clip.duration
        }
        try timeline.validateModifiers()
        committed = true
    }

    /// Ripple deletes several clips. Later clips go first so each removal
    /// closes its own gap without disturbing the clips still to be removed.
    public static func rippleDelete(_ timeline: inout Timeline, clipIDs: Set<UUID>) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        let ordered = timeline.allClips.filter { clipIDs.contains($0.id) }.sorted { $0.start > $1.start }
        for clip in ordered {
            try rippleDelete(&timeline, clipID: clip.id)
        }
        try timeline.validateModifiers()
        committed = true
    }

    /// The clips a selection rectangle touches: any clip on a track whose
    /// index falls in `trackIndices` and whose span overlaps `range`.
    public static func clipIDs(_ timeline: Timeline, intersecting range: ClosedRange<TimeInterval>, trackIndices: ClosedRange<Int>) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (index, track) in timeline.tracks.enumerated() where trackIndices.contains(index) {
            for clip in track.clips where clip.start < range.upperBound && clip.end > range.lowerBound {
                ids.insert(clip.id)
            }
        }
        return ids
    }

    public static func update(_ timeline: inout Timeline, clipID: UUID, _ change: (inout Clip) -> Void) throws {
        let previousTimeline = timeline
        var committed = false
        defer { if !committed { timeline = previousTimeline } }

        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        change(&timeline.tracks[trackIndex].clips[clipIndex])
        try timeline.validateModifiers()
        committed = true
    }

    /// Snap candidates: clip edges on every track plus zero.
    public static func snapPoints(_ timeline: Timeline, excluding clipID: UUID? = nil) -> [TimeInterval] {
        snapPoints(timeline, excluding: clipID.map { [$0] } ?? [])
    }

    /// Snap candidates without the edges of the clips being moved.
    public static func snapPoints(_ timeline: Timeline, excluding clipIDs: Set<UUID>) -> [TimeInterval] {
        var points: Set<TimeInterval> = [0]
        for clip in timeline.allClips where !clipIDs.contains(clip.id) {
            points.insert(clip.start)
            points.insert(clip.end)
        }
        return points.sorted()
    }

    /// The nearest snap point within `tolerance`, else the time itself.
    public static func snapped(_ time: TimeInterval, to points: [TimeInterval], tolerance: TimeInterval) -> TimeInterval {
        guard let nearest = points.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= tolerance else { return time }
        return nearest
    }

    /// Reorders whole tracks from top to bottom, retaining their identities,
    /// clips, settings and transitions. The order must include every track once.
    public static func reorderTracks(_ timeline: inout Timeline, trackIDs: [UUID]) throws {
        let existing = timeline.tracks.map(\.id)
        guard trackIDs.count == existing.count,
              Set(trackIDs).count == trackIDs.count,
              Set(trackIDs) == Set(existing) else { throw TimelineEditError.invalidTrackOrder }
        guard trackIDs != existing else { return }
        let tracks = Dictionary(uniqueKeysWithValues: timeline.tracks.map { ($0.id, $0) })
        timeline.tracks = trackIDs.compactMap { tracks[$0] }
    }

    /// Adds a track of a kind at the end of the layout.
    @discardableResult
    public static func addTrack(_ timeline: inout Timeline, kind: TrackKind) -> UUID {
        let count = timeline.tracks.filter { $0.kind == kind }.count + 1
        let prefix: String
        switch kind {
        case .video: prefix = "V"
        case .audio: prefix = "A"
        case .overlay: prefix = "T"
        case .caption: prefix = "C"
        }
        let track = Track(kind: kind, name: "\(prefix)\(count)")
        switch kind {
        case .overlay, .caption:
            timeline.tracks.insert(track, at: 0)
        case .video:
            let index = timeline.tracks.lastIndex { $0.kind == .video || $0.kind.drawsOverPicture }.map { $0 + 1 } ?? 0
            timeline.tracks.insert(track, at: index)
        case .audio:
            timeline.tracks.append(track)
        }
        return track.id
    }
}

extension TimelineEditError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .overlap: return "This edit would overlap another clip. Move it or make room on the track first."
        case .invalidDuration: return "Enter a duration of at least one frame within the available source media."
        case .invalidSpeed: return "Enter a finite speed greater than 0%."
        case .unsupportedOperation: return "This footage does not support that edit."
        case .invalidTrackOrder: return "Include every track exactly once in the new order."
        case .unknownTrack: return "The track is no longer available."
        case .unknownClip: return "The clip is no longer available."
        case .kindNotAllowed: return "This footage cannot be placed on that track."
        }
    }
}
