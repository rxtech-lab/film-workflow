import Foundation

/// A named speaker in a caption project.
///
/// For diarized providers the roster is seeded from the raw speaker numbers the
/// provider returned ("Speaker 1", "Speaker 2", …) and the user renames them.
/// For narrative sources it is seeded from the project's `NarrativeSpeaker`
/// list, so the labels are already meaningful and diarization is not used.
nonisolated struct CaptionSpeaker: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// User-facing name. Editable.
    var label: String

    /// The provider's 1-based diarization id; 0 means unknown or not diarized.
    /// Kept so re-transcribing the same audio can re-attach existing labels.
    var providerSpeakerNumber: Int = 0

    /// Index into the editor's speaker tint palette.
    var colorIndex: Int = 0

    /// Links back to `NarrativeSpeaker.id` for narrative-sourced projects.
    var narrativeSpeakerId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, label, providerSpeakerNumber, colorIndex, narrativeSpeakerId
    }

    init(
        id: UUID = UUID(),
        label: String,
        providerSpeakerNumber: Int = 0,
        colorIndex: Int = 0,
        narrativeSpeakerId: UUID? = nil
    ) {
        self.id = id
        self.label = label
        self.providerSpeakerNumber = providerSpeakerNumber
        self.colorIndex = colorIndex
        self.narrativeSpeakerId = narrativeSpeakerId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.providerSpeakerNumber = try c.decodeIfPresent(Int.self, forKey: .providerSpeakerNumber) ?? 0
        self.colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        self.narrativeSpeakerId = try c.decodeIfPresent(UUID.self, forKey: .narrativeSpeakerId)
    }
}
