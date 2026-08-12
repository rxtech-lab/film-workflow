import Foundation
import SwiftData

@Model
final class CaptionProject {
    /// Stable identity for cross-entity links (`GeneratedNarrative.captionProjectID`)
    /// and for MCP, neither of which can use a `PersistentIdentifier`.
    var projectUUID: UUID = UUID()

    var name: String
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Source audio

    var sourceKind: String = CaptionSourceKind.importedFile.rawValue

    /// Relative to `FileStorage.appSupportURL`, per repo convention.
    /// `captions/<uuid>.<ext>` when imported, `generated/<uuid>.<ext>` when it
    /// points at a narrative's audio.
    var audioFilePath: String = ""

    /// False when the file belongs to something else (a `GeneratedNarrative`).
    /// Deleting the project must not delete audio it doesn't own.
    var ownsAudioFile: Bool = true

    var audioDurationMs: Int = 0

    /// Weak, non-relational link to `GeneratedNarrative.id`. Deliberately not a
    /// `@Relationship`: a hand-edited caption project should survive the
    /// narrative's audio history being pruned, and keeping it a plain `UUID?`
    /// makes the schema change purely additive.
    var sourceNarrativeID: UUID?
    var sourceNarrativeName: String = ""

    // MARK: - Provider configuration

    /// Empty means "use the app-wide default from `CaptionSettings`".
    var provider: String = ""

    /// Per-project Whisper model. Empty means "use the one chosen in Settings".
    /// Lets one project run a fast small model while another uses large-v3.
    var whisperVariantOverride: String = ""

    /// BCP-47 hint, e.g. "zh-CN". Empty means auto-detect.
    var languageHint: String = ""

    var maxSpeakers: Int = 2
    var diarizationEnabled: Bool = true
    var wordTimestampsEnabled: Bool = true

    // MARK: - Narrative reference (timings-only captions)

    /// The author's spoken text, shortcode-stripped, in spoken order. Only
    /// populated for narrative sources.
    var referenceUnits: [CaptionReferenceUnit] = []

    var alignmentQuality: String = CaptionAlignmentQuality.none.rawValue

    /// Fraction of anchorable reference tokens that matched the ASR hypothesis.
    var alignmentMatchRatio: Double = 0

    var lastTranscribedAt: Date?
    var lastProviderName: String = ""

    /// Non-fatal problem worth showing the user (degraded alignment, missing
    /// word timings, a provider fallback that fired).
    var warning: String = ""

    // MARK: - Content

    var speakers: [CaptionSpeaker] = []

    /// Project glossary: spellings that speech recognition gets wrong. Guides
    /// the AI review pass and keeps the splitter from breaking a term in half.
    var terms: [CaptionTerm] = []

    @Relationship(deleteRule: .cascade, inverse: \CaptionSegment.project)
    var segments: [CaptionSegment] = []

    // MARK: - Assistant

    @Relationship(deleteRule: .cascade, inverse: \CaptionAssistantMessage.project)
    var assistantMessages: [CaptionAssistantMessage] = []

    /// Rolling summary of conversation turns that have been compacted away.
    ///
    /// The on-device model's window is small enough that a long conversation
    /// can't be replayed verbatim; older turns are folded into this instead.
    var assistantSummary: String = ""

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceKind = CaptionSourceKind.importedFile.rawValue
        self.audioFilePath = ""
        self.ownsAudioFile = true
        self.audioDurationMs = 0
        self.provider = ""
        self.languageHint = ""
        self.maxSpeakers = 2
        self.diarizationEnabled = true
        self.wordTimestampsEnabled = true
        self.referenceUnits = []
        self.alignmentQuality = CaptionAlignmentQuality.none.rawValue
        self.alignmentMatchRatio = 0
        self.lastProviderName = ""
        self.warning = ""
        self.speakers = []
        self.terms = []
        self.segments = []
        self.assistantMessages = []
        self.assistantSummary = ""
    }

    // MARK: - Enum accessors

    var sourceKindEnum: CaptionSourceKind {
        get { CaptionSourceKind(rawValue: sourceKind) ?? .importedFile }
        set { sourceKind = newValue.rawValue }
    }

    var alignmentQualityEnum: CaptionAlignmentQuality {
        get { CaptionAlignmentQuality(rawValue: alignmentQuality) ?? .none }
        set { alignmentQuality = newValue.rawValue }
    }

    /// The provider override, or nil when the app-wide default should be used.
    /// Callers resolve nil against `CaptionSettings.shared.defaultProvider`
    /// rather than this type reaching for a `@MainActor` singleton.
    var providerOverride: CaptionProvider? {
        get { provider.isEmpty ? nil : CaptionProvider(rawValue: provider) }
        set { provider = newValue?.rawValue ?? "" }
    }

    // MARK: - Derived

    var audioURL: URL { FileStorage.absoluteURL(for: audioFilePath) }

    var hasAudio: Bool { !audioFilePath.isEmpty }

    var isNarrativeSourced: Bool { sourceKindEnum == .generatedNarrative }

    var orderedSegments: [CaptionSegment] {
        segments.sorted {
            $0.startMs == $1.startMs ? $0.orderIndex < $1.orderIndex : $0.startMs < $1.startMs
        }
    }

    var orderedAssistantMessages: [CaptionAssistantMessage] {
        assistantMessages.sorted { $0.createdAt < $1.createdAt }
    }

    var orderedReferenceUnits: [CaptionReferenceUnit] {
        referenceUnits.sorted { $0.order < $1.order }
    }

    func speaker(_ id: UUID?) -> CaptionSpeaker? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }
    }

    func speakerLabel(_ id: UUID?) -> String {
        speaker(id)?.label ?? ""
    }

    /// Glossary entries with a non-blank spelling, in the order the user added
    /// them. Everything that reads the glossary goes through this so a
    /// half-typed row can never reach a prompt.
    var usableTerms: [CaptionTerm] {
        terms.filter { !$0.isEmpty }
    }
}
