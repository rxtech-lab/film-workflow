import Foundation

/// An empty stretch on one track: before its first clip, between two of its
/// clips, or after its last clip up to the end of the sequence. Disabled
/// clips count as empty, since the render skips them.
public struct TimelineGap: Sendable, Hashable {
    public enum Position: String, Sendable, Hashable {
        case leading, between, trailing
    }

    /// Why a gap is likely a mistake rather than a deliberate pause.
    public enum Issue: String, Sendable, Hashable, CaseIterable {
        /// No picture track covers part of it, so the sequence shows its
        /// background colour — a black screen between shots.
        case blankScreen = "blank_screen"
        /// A few frames at most between two clips: too short to be a pause,
        /// long enough to flash the background or the lane below.
        case flash
        /// Separates two clips a transition joins; the transition only plays
        /// while they butt, so it is dropped from the render.
        case breaksTransition = "breaks_transition"
        /// Nothing else is audible across it. Often intended (a beat of
        /// silence) but worth a look between narration or music clips.
        case silence
    }

    public var trackID: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var position: Position
    /// The clip before and after the gap on the same track, when there is one.
    public var previousClipID: UUID?
    public var nextClipID: UUID?
    /// Other lanes of the same role (picture or sound) playing somewhere in
    /// the gap, top to bottom.
    public var coveredBy: [UUID]
    /// Parts of the gap where nothing of that role plays at all.
    public var uncovered: [Range<TimeInterval>]
    public var issues: [Issue]

    public var duration: TimeInterval { end - start }
    public var range: Range<TimeInterval> { start..<end }
}

public struct TrackGapReport: Sendable, Hashable {
    public var trackID: UUID
    public var gaps: [TimelineGap]
}

/// Finds the empty stretches on each track and judges which would show up as
/// a fault in the render. Pure: reads a `Timeline`, changes nothing.
public enum TimelineGapAnalyzer {
    /// Shorter than this is two clips that butt, allowing for float drift.
    static let epsilon: TimeInterval = 0.0005
    /// Gaps this many frames or fewer between clips are called flashes.
    public static let flashFrames = 3

    /// One report per enabled track, top to bottom. Tracks with no rendered
    /// clip report nothing: an empty lane is not a gap in the cut.
    public static func analyze(_ timeline: Timeline, minimumDuration: TimeInterval = 0) -> [TrackGapReport] {
        let end = timeline.duration
        let pictureLanes = timeline.tracks.filter { $0.isEnabled && $0.kind == .video }
        let soundLanes = timeline.tracks.filter { $0.isEnabled && !$0.isMuted && $0.kind.carriesAudio }
        let flashLimit = Double(flashFrames) * timeline.frameDuration + epsilon
        let joined: Set<[UUID]> = Set(timeline.transitions.compactMap { transition in
            guard transition.isEnabled, case .between(let a, let b) = transition.attachment else { return nil }
            return [a, b]
        })

        return timeline.tracks.filter(\.isEnabled).compactMap { track in
            let clips = track.renderedClips
            guard !clips.isEmpty else { return nil }
            var gaps: [TimelineGap] = []
            var cursor: TimeInterval = 0
            var previous: Clip?
            for clip in clips {
                if clip.start - cursor > epsilon {
                    gaps.append(TimelineGap(trackID: track.id, start: cursor, end: clip.start,
                                            position: previous == nil ? .leading : .between,
                                            previousClipID: previous?.id, nextClipID: clip.id,
                                            coveredBy: [], uncovered: [], issues: []))
                }
                cursor = max(cursor, clip.end)
                previous = clip
            }
            if end - cursor > epsilon {
                gaps.append(TimelineGap(trackID: track.id, start: cursor, end: end, position: .trailing,
                                        previousClipID: previous?.id, nextClipID: nil,
                                        coveredBy: [], uncovered: [], issues: []))
            }

            gaps = gaps.filter { $0.duration >= minimumDuration }.map { gap in
                var gap = gap
                let lanes: [Track]? = switch track.kind {
                case .video: pictureLanes
                case .audio: soundLanes
                default: nil
                }
                if let lanes {
                    let others = lanes.filter { $0.id != track.id }
                    // Every clip on a picture lane draws; on a sound lane only
                    // clips with audible sound count.
                    let playing: (Track) -> [Clip] = { lane in
                        track.kind == .video ? lane.renderedClips : lane.renderedClips.filter { $0.source.kind.hasAudio && $0.volume > 0 }
                    }
                    gap.coveredBy = others.filter { lane in playing(lane).contains { $0.start < gap.end && gap.start < $0.end } }.map(\.id)
                    gap.uncovered = subtract(others.flatMap(playing).map(\.range), from: gap.range)
                }
                let uncoveredLength = gap.uncovered.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
                if track.kind == .video, uncoveredLength > epsilon { gap.issues.append(.blankScreen) }
                if gap.position == .between, gap.duration <= flashLimit, track.kind == .video || track.kind == .audio {
                    gap.issues.append(.flash)
                }
                if let a = gap.previousClipID, let b = gap.nextClipID, joined.contains([a, b]) {
                    gap.issues.append(.breaksTransition)
                }
                if track.kind == .audio, gap.position == .between, uncoveredLength > epsilon { gap.issues.append(.silence) }
                return gap
            }
            return TrackGapReport(trackID: track.id, gaps: gaps)
        }
    }

    /// Stretches of `0..<duration` where no picture lane draws anything: the
    /// background shows through. The fastest check for a black screen.
    public static func blankPicture(_ timeline: Timeline) -> [Range<TimeInterval>] {
        let pictures = timeline.tracks.filter { $0.isEnabled && $0.kind == .video }
            .flatMap(\.renderedClips).map(\.range)
        guard timeline.duration > epsilon else { return [] }
        return subtract(pictures, from: 0..<timeline.duration)
    }

    /// What is left of `range` once every one of `ranges` is taken out,
    /// ignoring slivers shorter than `epsilon`.
    static func subtract(_ ranges: [Range<TimeInterval>], from range: Range<TimeInterval>) -> [Range<TimeInterval>] {
        var result: [Range<TimeInterval>] = []
        var cursor = range.lowerBound
        for covered in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where covered.upperBound > cursor {
            if covered.lowerBound >= range.upperBound { break }
            if covered.lowerBound - cursor > epsilon { result.append(cursor..<covered.lowerBound) }
            cursor = max(cursor, covered.upperBound)
        }
        if range.upperBound - cursor > epsilon { result.append(cursor..<range.upperBound) }
        return result
    }
}

extension TimelineEditor {
    /// How `closeGap` fills an empty stretch on a track.
    public enum GapFill: String, Sendable, CaseIterable {
        /// Pull every later clip on the track left by the gap's length.
        /// Clips linked to them move too; other tracks stay where they are.
        case ripple
        /// Lengthen the clip before the gap, as far as its media allows.
        case extendPrevious = "extend_previous"
        /// Start the clip after the gap earlier, as far as its media allows.
        case extendNext = "extend_next"
    }

    /// Fills the gap on `trackID` that contains `time` (or starts at it).
    /// Returns the gap that was worked on; a clip that runs out of media can
    /// leave part of it open, which a second analysis shows.
    @discardableResult
    public static func closeGap(_ timeline: inout Timeline, trackID: UUID, at time: TimeInterval, fill: GapFill) throws -> TimelineGap {
        guard timeline[trackID: trackID] != nil else { throw TimelineEditError.unknownTrack(trackID) }
        let gaps = TimelineGapAnalyzer.analyze(timeline).first { $0.trackID == trackID }?.gaps ?? []
        let tolerance = timeline.frameDuration / 2
        guard let gap = gaps.first(where: { $0.start - tolerance <= time && time < $0.end }) else {
            throw TimelineEditError.unsupportedOperation
        }
        switch fill {
        case .ripple:
            guard gap.nextClipID != nil, let track = timeline[trackID: trackID] else { throw TimelineEditError.unsupportedOperation }
            let later = Set(track.clips.filter { $0.start >= gap.end - TimelineGapAnalyzer.epsilon }.map(\.id))
            try move(&timeline, clipIDs: later, by: -gap.duration)
        case .extendPrevious:
            guard let id = gap.previousClipID else { throw TimelineEditError.unsupportedOperation }
            try trimTrailing(&timeline, clipID: id, by: gap.duration)
        case .extendNext:
            guard let id = gap.nextClipID else { throw TimelineEditError.unsupportedOperation }
            try trimLeading(&timeline, clipID: id, by: -gap.duration)
        }
        return gap
    }
}
