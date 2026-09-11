import Foundation

// Captions live on their source's clock; the timeline shifts and clips them.
// Burn-in, embedded subtitle tracks and sidecar files all go through these
// helpers so the three deliveries agree on timing to the millisecond.

public extension Clip {
    /// A source-clock interval mapped onto the timeline and clipped to this
    /// clip. Captions cannot be retimed, so the mapping is a plain shift.
    /// Nil when nothing of the interval falls inside the clip.
    func timelineInterval(sourceStart: TimeInterval, sourceEnd: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        let start = max(self.start, sourceStart - inPoint + self.start)
        let end = min(self.end, sourceEnd - inPoint + self.start)
        return end > start ? (start, end) : nil
    }

    /// `cues` shifted onto the timeline clock and clipped to the clip.
    func timelineCues(_ cues: [TextCue]) -> [TextCue] {
        cues.compactMap { cue in
            timelineInterval(sourceStart: cue.start, sourceEnd: cue.end).map {
                TextCue(start: $0.start, end: $0.end, text: cue.text)
            }
        }
    }
}

public extension Array where Element == TextCue {
    /// Time-sorted, non-overlapping cues covering the same moments. Where cues
    /// overlap, the overlap becomes its own cue whose text joins theirs with a
    /// newline — the same picture the compositor draws — so a subtitle track
    /// that can only show one sample at a time reads identically.
    func flattened() -> [TextCue] {
        let cues = filter { $0.end > $0.start }
        guard cues.count > 1 else { return cues }
        let edges = Set(cues.flatMap { [$0.start, $0.end] }).sorted()
        var out: [TextCue] = []
        for (a, b) in zip(edges, edges.dropFirst()) {
            let active = cues.filter { $0.start <= a && $0.end > a }
            guard !active.isEmpty else { continue }
            let text = active.map(\.text).joined(separator: "\n")
            if let last = out.last, last.end == a, last.text == text {
                out[out.count - 1].end = b
            } else {
                out.append(TextCue(start: a, end: b, text: text))
            }
        }
        return out
    }
}

/// One language's cues on the timeline clock, ready to become a subtitle track.
public struct CaptionTrack: Sendable, Hashable {
    /// BCP-47; empty when the language is not known.
    public var languageCode: String
    public var cues: [TextCue]

    public init(languageCode: String, cues: [TextCue]) {
        self.languageCode = languageCode
        self.cues = cues
    }
}
