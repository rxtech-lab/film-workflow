import Foundation

/// One transcription run: when it happened, what produced it, and what language
/// it came out in.
///
/// Re-transcribing used to throw the previous transcript away. It now appends
/// one of these instead, so a user who re-runs with a different provider can
/// compare the two takes and switch back to the one they had already hand-edited.
///
/// Embedded `Codable` on `CaptionProject` rather than a `@Model`, matching
/// `CaptionSpeaker` and `CaptionTerm`: there are a handful per project, they are
/// always read with the project, and nothing else references them. Segments
/// point back with a plain `CaptionSegment.versionID` rather than a
/// `@Relationship`, which keeps the schema change purely additive — repointing
/// the existing `segments` inverse would not survive lightweight migration.
nonisolated struct CaptionTranscriptVersion: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// 1-based, monotonically increasing within a project. Deleting version 2
    /// does not renumber version 3 — the number is a label the user has already
    /// seen, not an index.
    var number: Int = 1

    var createdAt: Date = Date()

    /// BCP-47 of the transcript's own language, e.g. "en" or "zh-CN".
    ///
    /// Unlike `CaptionProject.languageHint` — which is a *hint* handed to the
    /// recognizer and may be empty — this records what the text actually is,
    /// falling back to the provider's detected locale when no hint was given.
    var languageCode: String = ""

    /// `CaptionProvider.rawValue` of whatever produced this run.
    var provider: String = ""

    var sourceKind: String = CaptionSourceKind.importedFile.rawValue

    var alignmentQuality: String = CaptionAlignmentQuality.none.rawValue
    var alignmentMatchRatio: Double = 0

    /// Cue count at the time of writing. Kept denormalized so the version list
    /// can render without faulting in every segment row of every version.
    var segmentCount: Int = 0

    /// Short human note, e.g. "Aligned to script".
    var note: String = ""

    /// Non-fatal caveat about **this run** — missing word timings, a provider
    /// fallback that fired, a degraded alignment.
    ///
    /// Lives here rather than only on the project because the project's copy
    /// describes whichever run happened last, so it kept warning about a take
    /// the user had already switched away from.
    var warning: String = ""

    /// Per-language translation status for this run.
    var translations: [CaptionVersionTranslation] = []

    enum CodingKeys: String, CodingKey {
        case id, number, createdAt, languageCode, provider, sourceKind
        case alignmentQuality, alignmentMatchRatio, segmentCount, note, warning, translations
    }

    init(
        id: UUID = UUID(),
        number: Int = 1,
        createdAt: Date = Date(),
        languageCode: String = "",
        provider: String = "",
        sourceKind: String = CaptionSourceKind.importedFile.rawValue,
        alignmentQuality: String = CaptionAlignmentQuality.none.rawValue,
        alignmentMatchRatio: Double = 0,
        segmentCount: Int = 0,
        note: String = "",
        warning: String = "",
        translations: [CaptionVersionTranslation] = []
    ) {
        self.id = id
        self.number = number
        self.createdAt = createdAt
        self.languageCode = languageCode
        self.provider = provider
        self.sourceKind = sourceKind
        self.alignmentQuality = alignmentQuality
        self.alignmentMatchRatio = alignmentMatchRatio
        self.segmentCount = segmentCount
        self.note = note
        self.warning = warning
        self.translations = translations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
            ?? CaptionSourceKind.importedFile.rawValue
        self.alignmentQuality = try c.decodeIfPresent(String.self, forKey: .alignmentQuality)
            ?? CaptionAlignmentQuality.none.rawValue
        self.alignmentMatchRatio = try c.decodeIfPresent(Double.self, forKey: .alignmentMatchRatio) ?? 0
        self.segmentCount = try c.decodeIfPresent(Int.self, forKey: .segmentCount) ?? 0
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.warning = try c.decodeIfPresent(String.self, forKey: .warning) ?? ""
        self.translations = try c.decodeIfPresent([CaptionVersionTranslation].self, forKey: .translations) ?? []
    }

    // MARK: - Derived

    var alignmentQualityEnum: CaptionAlignmentQuality {
        CaptionAlignmentQuality(rawValue: alignmentQuality) ?? .none
    }

    var providerEnum: CaptionProvider? {
        CaptionProvider(rawValue: provider)
    }

    var sourceKindEnum: CaptionSourceKind {
        CaptionSourceKind(rawValue: sourceKind) ?? .importedFile
    }

    /// Localized name of `languageCode`, or the raw code when the system has no
    /// name for it. Empty when the language was never resolved.
    var languageDisplayName: String {
        guard !languageCode.isEmpty else { return "" }
        return Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
    }

    func translation(_ languageCode: String) -> CaptionVersionTranslation? {
        translations.first { $0.languageCode == languageCode }
    }

    /// Target languages with at least one translated caption, in the order they
    /// were first translated.
    var translatedLanguages: [String] {
        translations.filter { $0.translatedCount > 0 }.map(\.languageCode)
    }
}

/// Translation status for one target language of one transcript version.
///
/// Lives on the version, not the project: a translation is only meaningful
/// against the text it was made from, so re-transcribing starts a fresh set of
/// counts (populated by whatever carries over from the previous version).
nonisolated struct CaptionVersionTranslation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// BCP-47 target language.
    var languageCode: String = ""

    /// `CaptionTranslationEngineKind.rawValue` of the last engine to write here.
    var engine: String = ""

    /// The model behind that engine, e.g. "gpt-4o-mini". Empty for Apple's
    /// on-device translator, and for a run recorded before this was stored.
    var model: String = ""

    var updatedAt: Date = Date()

    /// Captions carrying a translation in this language.
    var translatedCount: Int = 0

    /// Captions in the version, so the UI can say "412 of 900" without walking
    /// the rows.
    var totalCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, languageCode, engine, model, updatedAt, translatedCount, totalCount
    }

    init(
        id: UUID = UUID(),
        languageCode: String = "",
        engine: String = "",
        model: String = "",
        updatedAt: Date = Date(),
        translatedCount: Int = 0,
        totalCount: Int = 0
    ) {
        self.id = id
        self.languageCode = languageCode
        self.engine = engine
        self.model = model
        self.updatedAt = updatedAt
        self.translatedCount = translatedCount
        self.totalCount = totalCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
        self.engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.translatedCount = try c.decodeIfPresent(Int.self, forKey: .translatedCount) ?? 0
        self.totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
    }

    var isComplete: Bool { totalCount > 0 && translatedCount >= totalCount }

    /// "AI model · gpt-4o-mini". Empty when nothing was recorded.
    var producerDescription: String {
        CaptionTranslationEngineKind.producerDescription(engine: engine, model: model)
    }

    var languageDisplayName: String {
        guard !languageCode.isEmpty else { return "" }
        return Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
    }
}
