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

    init(
        projectName: String,
        audioDurationMs: Int,
        speakers: [CaptionSpeaker],
        segments: [CaptionSegmentSnapshot],
        alignmentQuality: CaptionAlignmentQuality = .none
    ) {
        self.projectName = projectName
        self.audioDurationMs = audioDurationMs
        self.speakers = speakers
        self.segments = segments
        self.alignmentQuality = alignmentQuality
    }

    func speakerLabel(_ id: UUID?) -> String {
        guard let id else { return "" }
        return speakers.first { $0.id == id }?.label ?? ""
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

    init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        text: String,
        speakerId: UUID? = nil,
        speakerLabel: String = "",
        words: [CaptionWord] = [],
        isEstimatedTiming: Bool = false
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.words = words
        self.isEstimatedTiming = isEstimatedTiming
    }

    var durationMs: Int { max(endMs - startMs, 0) }
}

// MARK: - Snapshotting

extension CaptionSegment {
    /// Must be called on the main actor; `@Model` properties are isolated.
    func snapshot(speakerLabel: String = "") -> CaptionSegmentSnapshot {
        CaptionSegmentSnapshot(
            id: uuid,
            startMs: startMs,
            endMs: endMs,
            text: text,
            speakerId: speakerId,
            speakerLabel: speakerLabel,
            words: orderedWords,
            isEstimatedTiming: isEstimatedTiming
        )
    }
}

extension CaptionProject {
    func snapshot() -> CaptionTranscriptSnapshot {
        let ordered = orderedSegments
        return CaptionTranscriptSnapshot(
            projectName: name,
            audioDurationMs: audioDurationMs,
            speakers: speakers,
            segments: ordered.map { $0.snapshot(speakerLabel: speakerLabel($0.speakerId)) },
            alignmentQuality: alignmentQualityEnum
        )
    }
}
