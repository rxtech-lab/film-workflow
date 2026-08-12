import Foundation

/// A word or phrase this project spells a particular way.
///
/// Speech recognition has no idea that "RxLab" is one word, or that the speaker
/// means "Remotion" and not "remotion". A term records the canonical spelling
/// plus the wrong spellings that have actually shown up, so the AI review pass
/// can correct them and the splitter knows never to break the phrase in half.
///
/// Embedded `Codable` on `CaptionProject` rather than a `@Model`, matching
/// `CaptionSpeaker` — a glossary is small, always loaded with its project, and
/// never referenced from elsewhere.
nonisolated struct CaptionTerm: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// The spelling that should appear in the captions.
    var text: String

    /// Optional hint for the model, e.g. "company name", "chemical compound".
    var note: String = ""

    /// Known mis-transcriptions. Empty is fine — the model still catches
    /// near-misses; these just make the correction unambiguous.
    var variants: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, text, note, variants
    }

    init(
        id: UUID = UUID(),
        text: String,
        note: String = "",
        variants: [String] = []
    ) {
        self.id = id
        self.text = text
        self.note = note
        self.variants = variants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
    }

    /// The term plus its variants, as normalized matching keys.
    ///
    /// A multi-word term normalizes to several tokens, so this returns token
    /// *sequences* rather than single keys — "RX lab" is two tokens on the way
    /// in and one on the way out, and the validator has to see both shapes.
    var normalizedForms: [[String]] {
        ([text] + variants)
            .map { CaptionTermMatching.tokens($0) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Tokenizing helpers shared by the glossary, the AI validator and the prompt
/// builders. Split out so nothing has to reach into `CaptionTokenizer` and
/// remember which field is the matching key.
nonisolated enum CaptionTermMatching {

    /// Normalized, punctuation-free tokens — the same key the aligner matches on.
    static func tokens(_ text: String) -> [String] {
        CaptionTokenizer.tokenize(text)
            .map(\.normalized)
            .filter { !$0.isEmpty }
    }

    /// Whether `haystack` contains `needle` as a contiguous token run.
    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Compact glossary block for a prompt. Empty when there are no terms, so
    /// callers can append it unconditionally.
    static func promptBlock(_ terms: [CaptionTerm]) -> String {
        let usable = terms.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return "" }

        var lines = ["Glossary — these spellings are correct and must be preserved exactly:"]
        for term in usable {
            var line = "- \(term.text)"
            if !term.note.isEmpty { line += " (\(term.note))" }
            let variants = term.variants.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !variants.isEmpty {
                line += " — sometimes mis-heard as: \(variants.joined(separator: ", "))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
