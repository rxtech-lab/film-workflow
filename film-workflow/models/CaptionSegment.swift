import Foundation
import SwiftData

/// One sentence-level caption cue: who said it, where it sits on the audio
/// timeline, the text, and the word timings inside it.
///
/// A child `@Model` rather than an embedded struct because a one-hour
/// transcript is 600–900 of these: as rows they fault lazily and a single edit
/// writes one row, whereas an embedded array would re-archive the whole
/// transcript (including every word timing) on every keystroke.
@Model
final class CaptionSegment {
    /// Stable identity for SwiftUI and for snapshots. `persistentModelID` is
    /// not usable as a `Sendable` snapshot id, and it changes shape across
    /// stores, so segments carry their own UUID.
    var uuid: UUID = UUID()

    /// Tie-breaker for ordering. SwiftData relationship arrays are unordered,
    /// and `startMs` alone is ambiguous when two segments share a start.
    var orderIndex: Int = 0

    var startMs: Int
    var endMs: Int

    /// The authoritative caption text. For narrative sources this is the
    /// author's original wording, never the ASR hypothesis.
    var text: String

    var speakerId: UUID?

    /// The provider's raw diarization id, kept so re-transcription can
    /// re-attach speaker labels the user already renamed.
    var providerSpeakerNumber: Int = 0

    var locale: String = ""
    var confidence: Double = 0

    /// The span was derived rather than measured (alignment fallback, or a
    /// proportional split of a phrase that had no word timings).
    var isEstimatedTiming: Bool = false

    /// The user has touched this segment; bulk operations leave it alone.
    var isUserEdited: Bool = false

    var words: [CaptionWord] = []

    /// The transcription run this caption came from.
    ///
    /// `nil` on rows written before versioning existed; those belong to the
    /// project's implicit legacy version, which is exactly what
    /// `CaptionProject.activeSegments` returns when `activeVersionID` is nil too.
    /// Deliberately not a `@Relationship` — the version is an embedded value on
    /// the project, and a plain UUID keeps this schema change additive. There is
    /// also no `= UUID()` default: a per-row random default would give every
    /// legacy row its own phantom version.
    var versionID: UUID?

    /// This caption in other languages, at most one entry per language code.
    var translations: [CaptionTranslation] = []

    var project: CaptionProject?

    init(
        orderIndex: Int = 0,
        startMs: Int,
        endMs: Int,
        text: String,
        speakerId: UUID? = nil,
        providerSpeakerNumber: Int = 0,
        locale: String = "",
        confidence: Double = 0,
        isEstimatedTiming: Bool = false,
        words: [CaptionWord] = []
    ) {
        self.orderIndex = orderIndex
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
        self.providerSpeakerNumber = providerSpeakerNumber
        self.locale = locale
        self.confidence = confidence
        self.isEstimatedTiming = isEstimatedTiming
        self.isUserEdited = false
        self.words = words
    }

    var durationMs: Int { max(endMs - startMs, 0) }

    /// Words in timeline order. Stored order should already match, but the
    /// editor's nudge operations can transiently reorder.
    var orderedWords: [CaptionWord] {
        words.sorted { $0.offsetMs < $1.offsetMs }
    }

    var hasWordTimings: Bool { !words.isEmpty }
}
