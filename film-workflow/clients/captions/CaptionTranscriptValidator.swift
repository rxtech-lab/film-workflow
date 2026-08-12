import Foundation
import SwiftUI

nonisolated enum CaptionTimingError: LocalizedError {
    case nonPositiveDuration
    case negativeOffset(phraseIndex: Int, offsetMs: Int)
    case nonPositivePhraseDuration(phraseIndex: Int, durationMs: Int)
    case nonMonotonicOffset(phraseIndex: Int, offsetMs: Int, previousOffsetMs: Int)
    case exceedsAudioDuration(phraseIndex: Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .nonPositiveDuration:
            return "The audio duration could not be determined."
        case .negativeOffset(let i, let ms):
            return "Phrase \(i) has a negative offset (\(ms) ms)."
        case .nonPositivePhraseDuration(let i, let ms):
            return "Phrase \(i) has a non-positive duration (\(ms) ms)."
        case .nonMonotonicOffset(let i, let ms, let previous):
            return "Phrase \(i) starts at \(ms) ms, before the previous phrase at \(previous) ms."
        case .exceedsAudioDuration(let i):
            return "Phrase \(i) ends after the audio ends."
        case .empty:
            return "The provider returned no phrases."
        }
    }
}

nonisolated struct CaptionValidationIssue: Sendable, Identifiable, Hashable {
    enum Kind: Sendable, Hashable {
        case emptyText
        case missingSpeaker
        case negativeOffset
        case nonPositiveDuration
        case exceedsAudioDuration
        case overlapsNext
        case wordOutsideSegment
        case wordsNonMonotonic
    }

    var id: String { "\(segmentIndex)-\(wordIndex ?? -1)-\(kind)" }

    let segmentIndex: Int
    let wordIndex: Int?
    let kind: Kind

    var message: LocalizedStringKey {
        switch kind {
        case .emptyText: return "Caption text is empty."
        case .missingSpeaker: return "No speaker assigned."
        case .negativeOffset: return "Start time is negative."
        case .nonPositiveDuration: return "End time must be after the start time."
        case .exceedsAudioDuration: return "Ends after the audio ends."
        case .overlapsNext: return "Overlaps the next caption."
        case .wordOutsideSegment: return "Word timing falls outside the caption."
        case .wordsNonMonotonic: return "Word timings are out of order."
        }
    }

    /// Timing problems make a caption unusable in an exported file; the rest are
    /// advisory and must never block a save.
    var isBlocking: Bool {
        switch kind {
        case .nonPositiveDuration, .negativeOffset: return true
        default: return false
        }
    }
}

nonisolated enum CaptionTranscriptValidator {

    /// Rejects provider output that cannot safely own subtitle timing.
    ///
    /// Port of `debate-bot/internal/stt/validate.go`. Generative models
    /// (Gemini) return fluent text alongside a timestamp sequence that can jump
    /// backwards; publishing that makes every following caption point at
    /// unrelated audio. Callers respond by retrying on the timing-fallback
    /// provider.
    static func validateTiming(_ transcript: CaptionTranscript) throws {
        guard transcript.durationMs > 0 else { throw CaptionTimingError.nonPositiveDuration }
        guard !transcript.phrases.isEmpty else { throw CaptionTimingError.empty }

        var previousOffset = -1
        for (index, phrase) in transcript.phrases.enumerated() {
            if phrase.offsetMs < 0 {
                throw CaptionTimingError.negativeOffset(phraseIndex: index, offsetMs: phrase.offsetMs)
            }
            if phrase.durationMs <= 0 {
                throw CaptionTimingError.nonPositivePhraseDuration(
                    phraseIndex: index, durationMs: phrase.durationMs
                )
            }
            if phrase.offsetMs < previousOffset {
                throw CaptionTimingError.nonMonotonicOffset(
                    phraseIndex: index, offsetMs: phrase.offsetMs, previousOffsetMs: previousOffset
                )
            }
            if phrase.durationMs > transcript.durationMs - phrase.offsetMs {
                throw CaptionTimingError.exceedsAudioDuration(phraseIndex: index)
            }
            previousOffset = phrase.offsetMs
        }
    }

    /// Per-field findings for the editor.
    ///
    /// Returns issues rather than throwing so rows can be badged: a user who
    /// has typed an inverted range must still be able to save and fix it later,
    /// never be trapped in an unsaveable editor.
    static func issues(in snapshot: CaptionTranscriptSnapshot) -> [CaptionValidationIssue] {
        var out: [CaptionValidationIssue] = []
        let segments = snapshot.segments

        for (index, segment) in segments.enumerated() {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.init(segmentIndex: index, wordIndex: nil, kind: .emptyText))
            }
            if segment.speakerId == nil, !snapshot.speakers.isEmpty {
                out.append(.init(segmentIndex: index, wordIndex: nil, kind: .missingSpeaker))
            }
            if segment.startMs < 0 {
                out.append(.init(segmentIndex: index, wordIndex: nil, kind: .negativeOffset))
            }
            if segment.endMs <= segment.startMs {
                out.append(.init(segmentIndex: index, wordIndex: nil, kind: .nonPositiveDuration))
            }
            if snapshot.audioDurationMs > 0, segment.endMs > snapshot.audioDurationMs {
                out.append(.init(segmentIndex: index, wordIndex: nil, kind: .exceedsAudioDuration))
            }
            if index + 1 < segments.count, segment.endMs > segments[index + 1].startMs {
                out.append(.init(segmentIndex: index, wordIndex: nil, kind: .overlapsNext))
            }

            var previousWordEnd = Int.min
            for (wordIndex, word) in segment.words.enumerated() {
                if word.offsetMs < segment.startMs || word.endMs > segment.endMs {
                    out.append(.init(
                        segmentIndex: index, wordIndex: wordIndex, kind: .wordOutsideSegment
                    ))
                }
                if word.offsetMs < previousWordEnd {
                    out.append(.init(
                        segmentIndex: index, wordIndex: wordIndex, kind: .wordsNonMonotonic
                    ))
                }
                previousWordEnd = word.endMs
            }
        }
        return out
    }
}
