import Foundation

/// One caption rendered into one target language.
///
/// Embedded `Codable` on `CaptionSegment` rather than its own `@Model`: a
/// translation has no timings, no identity a user ever refers to, and is always
/// read alongside the caption it belongs to. Keeping it here also means a
/// segment carries all of its languages in one archived blob, so switching the
/// displayed language in the editor never touches the store.
nonisolated struct CaptionTranslation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// BCP-47 target language, e.g. "zh-Hans".
    var languageCode: String = ""

    var text: String = ""

    var updatedAt: Date = Date()

    /// The user typed this. Bulk re-translation leaves it alone, matching
    /// `CaptionSegment.isUserEdited`.
    var isUserEdited: Bool = false

    /// `CaptionTranslationEngineKind.rawValue` of whatever produced it.
    var engine: String = ""

    /// Which model actually answered, e.g. "gpt-4o-mini" or "Claude Code".
    ///
    /// Separate from `engine` because that only says *how* the translation was
    /// made — "AI model" covers every backend the app can reach. Re-running one
    /// language on a stronger model is a normal thing to do, and without this
    /// there is no way to tell afterwards which lines came from which. Empty for
    /// Apple's on-device engine, which has no model to name.
    var model: String = ""

    /// Fingerprint of the source text at the moment this was produced.
    ///
    /// This is what makes staleness *computed* rather than stored: every path
    /// that rewrites `CaptionSegment.text` — the editor sheet, the AI applier,
    /// the MCP update tool, a merge — invalidates the translation for free,
    /// without any of them knowing translations exist. It is also the key a new
    /// transcript version matches on to inherit translations for captions that
    /// came out identical.
    var sourceFingerprint: String = ""

    enum CodingKeys: String, CodingKey {
        case id, languageCode, text, updatedAt, isUserEdited, engine, model, sourceFingerprint
    }

    init(
        id: UUID = UUID(),
        languageCode: String = "",
        text: String = "",
        updatedAt: Date = Date(),
        isUserEdited: Bool = false,
        engine: String = "",
        model: String = "",
        sourceFingerprint: String = ""
    ) {
        self.id = id
        self.languageCode = languageCode
        self.text = text
        self.updatedAt = updatedAt
        self.isUserEdited = isUserEdited
        self.engine = engine
        self.model = model
        self.sourceFingerprint = sourceFingerprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.isUserEdited = try c.decodeIfPresent(Bool.self, forKey: .isUserEdited) ?? false
        self.engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.sourceFingerprint = try c.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? ""
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var languageDisplayName: String {
        guard !languageCode.isEmpty else { return "" }
        return Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
    }

    /// "AI model · gpt-4o-mini". Empty when nothing was recorded.
    var producerDescription: String {
        CaptionTranslationEngineKind.producerDescription(engine: engine, model: model)
    }

    /// FNV-1a over the caption's normalized tokens.
    ///
    /// Hand-rolled rather than `hashValue` because Swift's hashing is seeded per
    /// process — a stored `hashValue` would flag every translation stale on the
    /// next launch. Built on `CaptionTermMatching.tokens`, so it is blind to
    /// punctuation and casing: re-punctuating a caption does not invalidate its
    /// translation, but changing a word does.
    static func fingerprint(of text: String) -> String {
        let key = CaptionTermMatching.tokens(text).joined(separator: " ")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Segment access

extension CaptionSegment {

    func translation(_ languageCode: String) -> CaptionTranslation? {
        translations.first { $0.languageCode == languageCode }
    }

    func translatedText(_ languageCode: String) -> String {
        translation(languageCode)?.text ?? ""
    }

    /// Languages with non-blank text, in insertion order.
    var translatedLanguages: [String] {
        translations.filter { !$0.isEmpty }.map(\.languageCode)
    }

    /// Language code → text, for snapshots. Blank translations are dropped so
    /// the exporter never has to distinguish "absent" from "empty".
    var translationMap: [String: String] {
        var map: [String: String] = [:]
        for translation in translations where !translation.isEmpty {
            map[translation.languageCode] = translation.text
        }
        return map
    }

    /// Same map with every `{{term}}` placeholder resolved for its own language.
    ///
    /// The stored text is the source of truth and keeps its placeholders; this
    /// is what anything showing text to a human — the exporter, an export
    /// document, an MCP reader — should use.
    func translationMap(resolvedBy resolver: CaptionTermResolver) -> [String: String] {
        var map: [String: String] = [:]
        for translation in translations where !translation.isEmpty {
            map[translation.languageCode] = resolver.render(
                translation.text,
                language: translation.languageCode
            )
        }
        return map
    }

    /// Upserts a translation, re-stamping the fingerprint from the *current*
    /// text. Blank text removes the entry rather than storing an empty one.
    func setTranslation(
        _ text: String,
        language: String,
        engine: String = "",
        model: String = "",
        isUserEdited: Bool = false
    ) {
        guard !language.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeTranslation(language)
            return
        }

        let fingerprint = CaptionTranslation.fingerprint(of: self.text)
        if let index = translations.firstIndex(where: { $0.languageCode == language }) {
            var existing = translations[index]
            existing.text = trimmed
            existing.updatedAt = Date()
            existing.sourceFingerprint = fingerprint
            if !engine.isEmpty { existing.engine = engine }
            if !model.isEmpty { existing.model = model }
            if isUserEdited { existing.isUserEdited = true }
            translations[index] = existing
        } else {
            translations.append(
                CaptionTranslation(
                    languageCode: language,
                    text: trimmed,
                    isUserEdited: isUserEdited,
                    engine: engine,
                    model: model,
                    sourceFingerprint: fingerprint
                )
            )
        }
    }

    func removeTranslation(_ languageCode: String) {
        translations.removeAll { $0.languageCode == languageCode }
    }

    /// The caption was rewritten after this translation was made.
    ///
    /// A translation with no recorded fingerprint (carried in from somewhere
    /// that predates this field) is treated as current — flagging every one of
    /// them would be noise, and the user can re-run the pass if they disagree.
    func isTranslationStale(_ languageCode: String) -> Bool {
        guard let translation = translation(languageCode),
              !translation.sourceFingerprint.isEmpty
        else { return false }
        return translation.sourceFingerprint != CaptionTranslation.fingerprint(of: text)
    }

    /// Needs a translation pass: nothing there, or what's there no longer
    /// matches the caption.
    func needsTranslation(_ languageCode: String) -> Bool {
        guard let translation = translation(languageCode), !translation.isEmpty else { return true }
        return isTranslationStale(languageCode)
    }
}
