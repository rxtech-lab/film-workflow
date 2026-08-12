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

    /// BCP-47 language code → the approved wording in that language.
    ///
    /// A missing or blank entry means "no approved wording", and a caption that
    /// references the term renders `text` instead. Stored as a dictionary rather
    /// than an array of structs because the value is a leaf — no timings, no
    /// engine, no staleness fingerprint, unlike `CaptionTranslation` — and a
    /// String-keyed dictionary keeps `Hashable` free and lookup O(1).
    var translations: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case id, text, note, variants, translations
    }

    init(
        id: UUID = UUID(),
        text: String,
        note: String = "",
        variants: [String] = [],
        translations: [String: String] = [:]
    ) {
        self.id = id
        self.text = text
        self.note = note
        self.variants = variants
        self.translations = translations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
        self.translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
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

    // MARK: - Per-language wording

    /// The approved wording for a language, or "" when there isn't one.
    func translation(_ languageCode: String) -> String {
        guard !languageCode.isEmpty else { return "" }
        let wording = translations[languageCode]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return wording ?? ""
    }

    /// What a `{{term}}` placeholder resolves to in this language: the approved
    /// wording when there is one, otherwise the canonical spelling. Falling back
    /// to `text` matches the glossary's own rule — leave a proper noun in the
    /// source form unless the target language has a standard rendering.
    func rendered(in languageCode: String) -> String {
        let wording = translation(languageCode)
        return wording.isEmpty ? text : wording
    }

    /// Upserts a wording. Blank removes the entry rather than storing "".
    mutating func setTranslation(_ text: String, language: String) {
        guard !language.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            translations.removeValue(forKey: language)
        } else {
            translations[language] = trimmed
        }
    }

    /// Languages with a non-blank wording, sorted by localized name so the
    /// editor and the term row list them the same way.
    var translatedLanguages: [String] {
        translations
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .keys
            .sorted {
                CaptionTranslationAvailability.displayName($0)
                    < CaptionTranslationAvailability.displayName($1)
            }
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

    /// Glossary block for the *translation* prompt, which asks for placeholders
    /// instead of translated words.
    ///
    /// A sibling of `promptBlock` rather than a flag on it: the splitter, the
    /// proofreader and the chat assistant all work on the original caption text,
    /// where a `{{...}}` must never appear. Teaching the shared block about
    /// placeholders would put them one prompt tweak away from the transcript.
    ///
    /// Variants are deliberately left out — a mis-hearing is a transcription
    /// concern, and listing them here invites `{{rex lab}}`.
    static func translationPromptBlock(_ terms: [CaptionTerm], target: String) -> String {
        let usable = terms.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return "" }
        let targetName = CaptionTranslationAvailability.displayName(target)

        var lines = [
            "Glossary — write each of these in your translation as the placeholder "
                + "shown, never as translated words. The app substitutes the approved "
                + "wording afterwards:"
        ]
        for term in usable {
            var line = "- \(CaptionTermPlaceholder.wrap(term.text))"
            if !term.note.isEmpty { line += " (\(term.note))" }
            let wording = term.translation(target)
            if wording.isEmpty {
                line += " → no \(targetName) wording set; becomes \"\(term.text)\""
            } else {
                line += " → becomes \"\(wording)\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
