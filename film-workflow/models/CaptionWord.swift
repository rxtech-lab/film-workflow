import Foundation

/// One word (or CJK glyph) with its position on the audio timeline.
///
/// Stored as an embedded `Codable` array on `CaptionSegment` rather than as its
/// own `@Model`: a one-hour transcript holds 15–20k of these, and they are only
/// ever read as a whole segment's worth at a time by the word inspector.
///
/// Timings are relative to the start of the audio file, not to the owning
/// segment, so a word range can be handed straight to a player without knowing
/// which segment it came from.
nonisolated struct CaptionWord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var offsetMs: Int
    var durationMs: Int

    /// Provider confidence in 0…1 where reported, otherwise 0.
    var confidence: Double = 0

    /// The user hand-edited this boundary. Pinned words are exempt from
    /// rescaling and act as fixed anchors for the words around them.
    var isPinned: Bool = false

    /// This timing was synthesized (proportional split, alignment gap fill)
    /// rather than measured by the provider.
    var isEstimated: Bool = false

    var endMs: Int { offsetMs + durationMs }

    /// Grapheme-cluster count of the word-ish characters, used as the weight
    /// when distributing a duration across words. Never zero, so a
    /// punctuation-only token still gets a slice rather than collapsing.
    var runeWeight: Int {
        max(text.count(where: { !$0.isWhitespace }), 1)
    }

    enum CodingKeys: String, CodingKey {
        case id, text, offsetMs, durationMs, confidence, isPinned, isEstimated
    }

    init(
        id: UUID = UUID(),
        text: String,
        offsetMs: Int,
        durationMs: Int,
        confidence: Double = 0,
        isPinned: Bool = false,
        isEstimated: Bool = false
    ) {
        self.id = id
        self.text = text
        self.offsetMs = offsetMs
        self.durationMs = durationMs
        self.confidence = confidence
        self.isPinned = isPinned
        self.isEstimated = isEstimated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.offsetMs = try c.decodeIfPresent(Int.self, forKey: .offsetMs) ?? 0
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        self.confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }
}
