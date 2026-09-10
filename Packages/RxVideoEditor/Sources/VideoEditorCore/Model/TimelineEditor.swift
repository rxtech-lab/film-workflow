import Foundation

public enum TimelineEditError: Error, Equatable, Sendable {
    case unknownTrack(UUID)
    case unknownClip(UUID)
    case kindNotAllowed(SourceKind, on: TrackKind)
    case overlap
    case invalidDuration
}

/// Pure editing operations on a `Timeline`. Every operation validates the
/// result so the timeline can never hold overlapping clips on one track.
public enum TimelineEditor {
    /// Inserts a clip on a track. When `ripple` is set, later clips on that
    /// track shift right to make room; otherwise an overlap is an error.
    public static func insert(
        _ timeline: inout Timeline,
        clip: Clip,
        on trackID: UUID,
        ripple: Bool = false
    ) throws {
        guard let index = timeline.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw TimelineEditError.unknownTrack(trackID)
        }
        guard clip.duration > 0 else { throw TimelineEditError.invalidDuration }
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
        guard let fromTrack = timeline.track(containing: clipID),
              var clip = timeline.clip(id: clipID) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        let destinationID = trackID ?? fromTrack.id
        guard let destinationIndex = timeline.tracks.firstIndex(where: { $0.id == destinationID }) else {
            throw TimelineEditError.unknownTrack(destinationID)
        }
        guard timeline.tracks[destinationIndex].kind.accepts(clip.source.kind) else {
            throw TimelineEditError.kindNotAllowed(clip.source.kind, on: timeline.tracks[destinationIndex].kind)
        }
        clip.start = timeline.quantized(max(0, start))
        let others = timeline.tracks[destinationIndex].clips.filter { $0.id != clipID }
        guard !others.contains(where: { $0.overlaps(clip) }) else { throw TimelineEditError.overlap }

        remove(&timeline, clipID: clipID)
        timeline.tracks[destinationIndex].clips.append(clip)
        timeline.tracks[destinationIndex].clips.sort { $0.start < $1.start }
    }

    /// Changes where a clip begins, keeping its end fixed. Positive `delta`
    /// shortens the clip from the front. Clamped to the source's in point.
    public static func trimLeading(_ timeline: inout Timeline, clipID: UUID, by delta: TimeInterval, minimumDuration: TimeInterval? = nil) throws {
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        var clip = timeline.tracks[trackIndex].clips[clipIndex]
        let minimum = minimumDuration ?? timeline.frameDuration
        var delta = timeline.quantized(abs(delta)) * (delta < 0 ? -1 : 1)
        delta = min(delta, clip.duration - minimum)
        delta = max(delta, -clip.inPoint)
        delta = max(delta, -clip.start)
        clip.start += delta
        clip.inPoint += delta
        clip.duration -= delta
        let others = timeline.tracks[trackIndex].clips.filter { $0.id != clipID }
        guard !others.contains(where: { $0.overlaps(clip) }) else { throw TimelineEditError.overlap }
        timeline.tracks[trackIndex].clips[clipIndex] = clip
    }

    /// Changes where a clip ends. Positive `delta` lengthens it; `maximumDuration`
    /// caps it at the source's remaining length when known.
    public static func trimTrailing(_ timeline: inout Timeline, clipID: UUID, by delta: TimeInterval, maximumDuration: TimeInterval? = nil, minimumDuration: TimeInterval? = nil) throws {
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        var clip = timeline.tracks[trackIndex].clips[clipIndex]
        let minimum = minimumDuration ?? timeline.frameDuration
        var duration = timeline.quantized(clip.duration + delta)
        duration = max(duration, minimum)
        if let maximumDuration { duration = min(duration, maximumDuration) }
        clip.duration = duration
        let others = timeline.tracks[trackIndex].clips.filter { $0.id != clipID }
        guard !others.contains(where: { $0.overlaps(clip) }) else { throw TimelineEditError.overlap }
        timeline.tracks[trackIndex].clips[clipIndex] = clip
    }

    /// Splits a clip at a timeline time. Returns the id of the new right half.
    @discardableResult
    public static func split(_ timeline: inout Timeline, clipID: UUID, at time: TimeInterval) throws -> UUID? {
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        let clip = timeline.tracks[trackIndex].clips[clipIndex]
        let cut = timeline.quantized(time)
        guard cut > clip.start + timeline.frameDuration / 2, cut < clip.end - timeline.frameDuration / 2 else { return nil }
        var left = clip
        left.duration = cut - clip.start
        var right = clip
        right.id = UUID()
        right.start = cut
        right.inPoint = clip.inPoint + left.duration
        right.duration = clip.end - cut
        timeline.tracks[trackIndex].clips[clipIndex] = left
        timeline.tracks[trackIndex].clips.insert(right, at: clipIndex + 1)
        return right.id
    }

    public static func remove(_ timeline: inout Timeline, clipID: UUID) {
        for i in timeline.tracks.indices {
            timeline.tracks[i].clips.removeAll { $0.id == clipID }
        }
    }

    /// Removes a clip and closes the gap it leaves on its track.
    public static func rippleDelete(_ timeline: inout Timeline, clipID: UUID) throws {
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clip = timeline.clip(id: clipID) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        timeline.tracks[trackIndex].clips.removeAll { $0.id == clipID }
        for i in timeline.tracks[trackIndex].clips.indices where timeline.tracks[trackIndex].clips[i].start >= clip.end {
            timeline.tracks[trackIndex].clips[i].start -= clip.duration
        }
    }

    public static func update(_ timeline: inout Timeline, clipID: UUID, _ change: (inout Clip) -> Void) throws {
        guard let trackIndex = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.unknownClip(clipID)
        }
        change(&timeline.tracks[trackIndex].clips[clipIndex])
    }

    /// Snap candidates: clip edges on every track plus zero.
    public static func snapPoints(_ timeline: Timeline, excluding clipID: UUID? = nil) -> [TimeInterval] {
        var points: Set<TimeInterval> = [0]
        for clip in timeline.allClips where clip.id != clipID {
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

    /// Adds a track of a kind at the end of the layout.
    @discardableResult
    public static func addTrack(_ timeline: inout Timeline, kind: TrackKind) -> UUID {
        let count = timeline.tracks.filter { $0.kind == kind }.count + 1
        let prefix: String
        switch kind {
        case .video: prefix = "V"
        case .audio: prefix = "A"
        case .overlay: prefix = "T"
        }
        let track = Track(kind: kind, name: "\(prefix)\(count)")
        switch kind {
        case .overlay:
            timeline.tracks.insert(track, at: 0)
        case .video:
            let index = timeline.tracks.lastIndex { $0.kind == .video || $0.kind == .overlay }.map { $0 + 1 } ?? 0
            timeline.tracks.insert(track, at: index)
        case .audio:
            timeline.tracks.append(track)
        }
        return track.id
    }
}
