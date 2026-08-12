import Foundation
import SwiftData

@Model
final class CaptionProject: GroupableProject {
    /// Stable identity for cross-entity links (`GeneratedNarrative.captionProjectID`)
    /// and for MCP, neither of which can use a `PersistentIdentifier`.
    var projectUUID: UUID = UUID()

    var name: String
    var createdAt: Date
    var updatedAt: Date
    var groupID: UUID?

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

    /// Every transcription run this project has had.
    ///
    /// Empty on a project last written before versioning existed — see
    /// `ensureVersioned()`. Nothing prunes this: re-transcribing is cheap to
    /// undo precisely because old takes stay around, and deleting one is a
    /// deliberate action in Caption Setup.
    var versions: [CaptionTranscriptVersion] = []

    /// Which run the editor, the exporter and every MCP tool see.
    ///
    /// `nil` is not a missing value, it is the pre-versioning state: a legacy
    /// project has nil here and nil `CaptionSegment.versionID` on every row, and
    /// `activeSegments` matches them up without any migration having to run.
    var activeVersionID: UUID?

    /// BCP-47 of the translation shown beneath each caption in the editor, and
    /// the export sheet's initial selection. Empty means original only.
    var displayedTranslationLanguage: String = ""

    /// **Every** segment of **every** version. Use `activeSegments` or
    /// `orderedSegments` to read the transcript; this is storage, and iterating
    /// it directly will mix takes together.
    @Relationship(deleteRule: .cascade, inverse: \CaptionSegment.project)
    var segments: [CaptionSegment] = []

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupID = nil
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
        self.versions = []
        self.activeVersionID = nil
        self.displayedTranslationLanguage = ""
        self.segments = []
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

    /// Segments belonging to the active version, unsorted.
    ///
    /// The `nil == nil` case is not a fallback, it *is* the legacy state, so a
    /// project written before versioning renders correctly before — and even
    /// without — `ensureVersioned()` ever running.
    var activeSegments: [CaptionSegment] {
        segments.filter { $0.versionID == activeVersionID }
    }

    /// Caption count of the active version. Cheaper than `orderedSegments.count`
    /// for list rows, which don't need the sort.
    var activeSegmentCount: Int {
        segments.reduce(into: 0) { $0 += ($1.versionID == activeVersionID ? 1 : 0) }
    }

    var orderedSegments: [CaptionSegment] {
        activeSegments.sorted {
            $0.startMs == $1.startMs ? $0.orderIndex < $1.orderIndex : $0.startMs < $1.startMs
        }
    }

    /// Active-version lookup by segment uuid. Call sites must use this rather
    /// than `segments.first(where:)`, which would reach into an inactive take.
    func segment(_ uuid: UUID) -> CaptionSegment? {
        segments.first { $0.uuid == uuid && $0.versionID == activeVersionID }
    }

    // MARK: - Versions

    var activeVersion: CaptionTranscriptVersion? {
        guard let activeVersionID else { return nil }
        return versions.first { $0.id == activeVersionID }
    }

    /// Newest first — the order the version menu shows them in.
    var orderedVersions: [CaptionTranscriptVersion] {
        versions.sorted { $0.number > $1.number }
    }

    /// Never reuses a number, even after a deletion, so a version label the user
    /// has already seen never points at different content.
    var nextVersionNumber: Int {
        (versions.map(\.number).max() ?? 0) + 1
    }

    /// BCP-47 of the caption text itself: what the active run actually produced,
    /// falling back to the recognizer hint on a project that predates versioning.
    var sourceLanguageCode: String {
        let recorded = activeVersion?.languageCode ?? ""
        return recorded.isEmpty ? languageHint : recorded
    }

    /// Target languages with at least one translated caption in the active
    /// version. Read from the version summary rather than walking every row.
    var translatedLanguages: [String] {
        activeVersion?.translatedLanguages ?? []
    }

    /// Gives a pre-versioning project its version 1 record and stamps every
    /// unversioned segment with it. Idempotent, and a no-op on an empty project.
    ///
    /// Called lazily — when the editor opens a project, when a transcription or
    /// translation runs, and when MCP resolves one — never at launch. Because
    /// `activeSegments` already returns the right rows for an un-migrated
    /// project, nothing breaks if this never runs at all.
    @discardableResult
    func ensureVersioned() -> CaptionTranscriptVersion? {
        if let activeVersion { return activeVersion }
        guard versions.isEmpty, !segments.isEmpty else { return nil }

        let detected = segments.first { !$0.locale.isEmpty }?.locale ?? ""
        let version = CaptionTranscriptVersion(
            number: 1,
            createdAt: lastTranscribedAt ?? createdAt,
            languageCode: languageHint.isEmpty ? detected : languageHint,
            provider: lastProviderName.isEmpty ? provider : lastProviderName,
            sourceKind: sourceKind,
            alignmentQuality: alignmentQuality,
            alignmentMatchRatio: alignmentMatchRatio,
            segmentCount: segments.count
        )

        for segment in segments where segment.versionID == nil {
            segment.versionID = version.id
        }
        versions = [version]
        activeVersionID = version.id
        refreshTranslationSummary()
        return version
    }

    /// Recomputes the active version's per-language counts from its segments.
    ///
    /// The counts are denormalized onto the version so the version list and the
    /// language pickers can render without faulting every row; this is the one
    /// place that keeps them honest, and every writer calls it.
    func refreshTranslationSummary() {
        guard let index = versions.firstIndex(where: { $0.id == activeVersionID }) else { return }
        let rows = activeSegments
        var counts: [String: Int] = [:]
        for row in rows {
            for language in row.translatedLanguages {
                counts[language, default: 0] += 1
            }
        }

        var summaries = versions[index].translations
        // Update or drop what's already recorded, preserving order and engine.
        summaries = summaries.compactMap { summary in
            guard let count = counts[summary.languageCode] else { return nil }
            var updated = summary
            updated.translatedCount = count
            updated.totalCount = rows.count
            return updated
        }
        // Append languages that appeared without a summary (e.g. inherited).
        let known = Set(summaries.map(\.languageCode))
        for (language, count) in counts.sorted(by: { $0.key < $1.key }) where !known.contains(language) {
            summaries.append(
                CaptionVersionTranslation(
                    languageCode: language,
                    translatedCount: count,
                    totalCount: rows.count
                )
            )
        }
        versions[index].translations = summaries

        // A displayed language that no longer exists would render every row as
        // "Not translated".
        if !displayedTranslationLanguage.isEmpty,
           !summaries.contains(where: { $0.languageCode == displayedTranslationLanguage }) {
            displayedTranslationLanguage = ""
        }
    }

    /// Marks `languageCode` as touched by `engine` and refreshes the counts.
    func recordTranslationRun(language: String, engine: String) {
        guard !language.isEmpty,
              let index = versions.firstIndex(where: { $0.id == activeVersionID })
        else { return }

        if let existing = versions[index].translations.firstIndex(where: { $0.languageCode == language }) {
            versions[index].translations[existing].engine = engine
            versions[index].translations[existing].updatedAt = Date()
        } else {
            versions[index].translations.append(
                CaptionVersionTranslation(languageCode: language, engine: engine)
            )
        }
        refreshTranslationSummary()
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
