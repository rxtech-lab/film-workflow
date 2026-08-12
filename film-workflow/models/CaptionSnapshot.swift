import Foundation

/// `Sendable` copies of a caption project, taken on the main actor before
/// handing work to `@concurrent` code.
///
/// SwiftData models are `@MainActor`-bound under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting, so the exporter and the
/// aligner never see a `@Model` — they take one of these. Same pattern as
/// `NarrativePreviewBuilder` / `AzureTTSClient.generate`.
nonisolated struct CaptionTranscriptSnapshot: Sendable, Hashable {
    var projectName: String
    var audioDurationMs: Int
    var speakers: [CaptionSpeaker]
    var segments: [CaptionSegmentSnapshot]
    var alignmentQuality: CaptionAlignmentQuality

    /// BCP-47 of the caption text itself, from the active transcript version.
    var sourceLanguage: String

    /// Which transcript version this is a copy of, so an exported JSON document
    /// can be traced back to a take.
    var versionNumber: Int

    /// Target languages present on at least one segment, in the version's order.
    var availableTranslations: [String]

    init(
        projectName: String,
        audioDurationMs: Int,
        speakers: [CaptionSpeaker],
        segments: [CaptionSegmentSnapshot],
        alignmentQuality: CaptionAlignmentQuality = .none,
        sourceLanguage: String = "",
        versionNumber: Int = 1,
        availableTranslations: [String] = []
    ) {
        self.projectName = projectName
        self.audioDurationMs = audioDurationMs
        self.speakers = speakers
        self.segments = segments
        self.alignmentQuality = alignmentQuality
        self.sourceLanguage = sourceLanguage
        self.versionNumber = versionNumber
        self.availableTranslations = availableTranslations
    }

    func speakerLabel(_ id: UUID?) -> String {
        guard let id else { return "" }
        return speakers.first { $0.id == id }?.label ?? ""
    }

    /// Whether any segment carries `languageCode`. The exporter checks this
    /// before committing to a translation-only render.
    func hasTranslation(_ languageCode: String) -> Bool {
        guard !languageCode.isEmpty else { return false }
        return segments.contains { $0.translations[languageCode]?.isEmpty == false }
    }
}

nonisolated struct CaptionSegmentSnapshot: Sendable, Hashable, Identifiable {
    var id: UUID
    var startMs: Int
    var endMs: Int
    var text: String
    var speakerId: UUID?
    var speakerLabel: String
    var words: [CaptionWord]
    var isEstimatedTiming: Bool

    /// Language code → translated text. A dictionary rather than an array of
    /// `CaptionTranslation` keeps the snapshot `Hashable` and the exporter's
    /// per-cue lookup O(1); nothing downstream needs the timestamps or the
    /// staleness fingerprint.
    var translations: [String: String]

    init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        text: String,
        speakerId: UUID? = nil,
        speakerLabel: String = "",
        words: [CaptionWord] = [],
        isEstimatedTiming: Bool = false,
        translations: [String: String] = [:]
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.words = words
        self.isEstimatedTiming = isEstimatedTiming
        self.translations = translations
    }

    var durationMs: Int { max(endMs - startMs, 0) }

    func translation(_ languageCode: String) -> String {
        translations[languageCode] ?? ""
    }
}

// MARK: - Snapshotting

extension CaptionSegment {
    /// Must be called on the main actor; `@Model` properties are isolated.
    ///
    /// Translations are rendered here, at the one place raw storage turns into
    /// a value type, so every downstream consumer — the exporter and all four of
    /// its formats, the agent, MCP's export tool — gets resolved text without
    /// knowing placeholders exist. Resolving any later would mean racing the
    /// exporter's `stripPunctuation`, which eats braces.
    func snapshot(
        speakerLabel: String = "",
        resolver: CaptionTermResolver = .empty
    ) -> CaptionSegmentSnapshot {
        CaptionSegmentSnapshot(
            id: uuid,
            startMs: startMs,
            endMs: endMs,
            text: text,
            speakerId: speakerId,
            speakerLabel: speakerLabel,
            words: orderedWords,
            isEstimatedTiming: isEstimatedTiming,
            translations: translationMap(resolvedBy: resolver)
        )
    }
}

extension CaptionProject {
    /// A copy of the **active** transcript version. `orderedSegments` is already
    /// version-filtered, so every consumer downstream — exporter, validator, AI
    /// passes, the assistant — sees one take and never a mix of them.
    func snapshot() -> CaptionTranscriptSnapshot {
        let ordered = orderedSegments
        // Built once for the whole transcript, not once per segment: the table
        // is the same for every caption and a thousand-segment project would
        // otherwise rebuild it a thousand times.
        let resolver = CaptionTermResolver(terms: usableTerms)
        return CaptionTranscriptSnapshot(
            projectName: name,
            audioDurationMs: audioDurationMs,
            speakers: speakers,
            segments: ordered.map {
                $0.snapshot(speakerLabel: speakerLabel($0.speakerId), resolver: resolver)
            },
            alignmentQuality: activeAlignmentQuality,
            sourceLanguage: sourceLanguageCode,
            versionNumber: activeVersion?.number ?? 1,
            availableTranslations: translatedLanguages
        )
    }
}
