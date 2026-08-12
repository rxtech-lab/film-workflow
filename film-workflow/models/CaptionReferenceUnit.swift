import Foundation

/// One narrative paragraph reduced to the words that are actually spoken.
///
/// This is the *reference* side of narrative caption alignment: the speech
/// service supplies timings, but the caption text comes from here so it stays
/// character-identical to what the author wrote. Persisted on the caption
/// project so re-aligning never has to reach back into the narrative project
/// (which may have been edited or deleted since).
nonisolated struct CaptionReferenceUnit: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// `NarrativeParagraph.id` this came from.
    var paragraphId: UUID

    /// `CaptionSpeaker.id`, resolved from the paragraph's narrative speaker.
    var speakerId: UUID

    /// Position in the narrative, used to keep units in spoken order.
    var order: Int

    /// The paragraph's `content` with shortcode markup removed — see
    /// `ShortcodeExpander.plainSpeechText`.
    var plainText: String

    /// Silence the author asked for before this unit (`{{pause}}`,
    /// `{{break:250ms}}`), in milliseconds. Used as a fixed gap by the
    /// estimated-timing fallback so authored pauses survive even when
    /// alignment fails.
    var fixedPauseMsBefore: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, paragraphId, speakerId, order, plainText, fixedPauseMsBefore
    }

    init(
        id: UUID = UUID(),
        paragraphId: UUID,
        speakerId: UUID,
        order: Int,
        plainText: String,
        fixedPauseMsBefore: Int = 0
    ) {
        self.id = id
        self.paragraphId = paragraphId
        self.speakerId = speakerId
        self.order = order
        self.plainText = plainText
        self.fixedPauseMsBefore = fixedPauseMsBefore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.paragraphId = try c.decodeIfPresent(UUID.self, forKey: .paragraphId) ?? UUID()
        self.speakerId = try c.decodeIfPresent(UUID.self, forKey: .speakerId) ?? UUID()
        self.order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        self.plainText = try c.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        self.fixedPauseMsBefore = try c.decodeIfPresent(Int.self, forKey: .fixedPauseMsBefore) ?? 0
    }
}
