import Foundation

/// The `{{Term}}` syntax that lets a translated caption point at the glossary
/// instead of baking a wording in.
///
/// A translation is *stored* with placeholders and *rendered* on the way out, so
/// changing a term's wording updates every caption that references it with no
/// re-translation and no staleness. Nothing else in the app uses braces, and the
/// original caption text never carries them — only `CaptionTranslation.text`.
nonisolated enum CaptionTermPlaceholder {
    static let open = "{{"
    static let close = "}}"

    /// The lookup key for a term or a placeholder's inner text.
    ///
    /// Tokens joined with **no separator**, unlike `CaptionTranslation
    /// .fingerprint`, which joins with a space. The tokenizer splits Latin runs
    /// on whitespace and CJK per glyph, so a space-join would break both
    /// multi-word Latin keys ("rx lab" ≠ "rxlab") and every CJK key. The empty
    /// join also folds case, width, diacritics and internal punctuation, so
    /// `{{ rx-lab }}`, `{{RXLAB}}` and `{{RxLab}}` all reach the same term.
    ///
    /// Two glossary entries can collide once punctuation and spacing are gone
    /// ("therapist" / "the rapist"). Acceptable in a hand-curated list of a few
    /// dozen entries; the first entry wins.
    static func key(_ text: String) -> String {
        CaptionTermMatching.tokens(text).joined()
    }

    static func wrap(_ termText: String) -> String {
        "\(open)\(termText)\(close)"
    }

    /// Cheap guard so the no-placeholder path — every Apple-translated line,
    /// every line written before this feature — costs one substring scan.
    static func contains(_ raw: String) -> Bool {
        raw.contains(open)
    }

    /// Inner strings, trimmed, in order of appearance.
    static func keys(in raw: String) -> [String] {
        scan(raw).compactMap { piece in
            guard case .placeholder(let inner) = piece else { return nil }
            return inner
        }
    }

    /// Well-formedness pass that needs no glossary: collapses runs of extra
    /// braces, drops unterminated openers, trims the inside.
    static func normalizeBraces(_ raw: String) -> String {
        guard contains(raw) else { return raw }
        var out = ""
        for piece in scan(raw) {
            switch piece {
            case .literal(let text): out += text
            case .placeholder(let inner): out += wrap(inner)
            }
        }
        return out
    }

    // MARK: - Scanning

    enum Piece: Equatable {
        case literal(String)
        /// Brace contents, trimmed. Braces themselves already removed.
        case placeholder(String)
    }

    /// Splits `raw` into literals and placeholders in one forward pass.
    ///
    /// Malformed input never throws: an unterminated `{{` gives up its braces
    /// and contributes the rest as text, and a nested `{{a{{b}}` resolves the
    /// innermost opener so a model can't nest its way past the resolver. The
    /// invariant every caller depends on is that reassembling the pieces without
    /// re-wrapping yields a string containing no `{{`.
    ///
    /// An unmatched `}}` is left alone rather than deleted. It was never part of
    /// a placeholder — the same way a lone `}` isn't — and text that legitimately
    /// contains one should survive a round trip. Doing anything else would also
    /// make the no-brace fast path in `render` disagree with the slow one.
    static func scan(_ raw: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var index = raw.startIndex

        func flush() {
            guard !literal.isEmpty else { return }
            pieces.append(.literal(literal))
            literal = ""
        }

        while index < raw.endIndex {
            if raw[index...].hasPrefix(open) {
                // Collapse `{{{` and friends down to one opener.
                var open_ = raw.index(index, offsetBy: 2)
                while open_ < raw.endIndex, raw[open_] == "{" {
                    open_ = raw.index(after: open_)
                }

                guard let closeRange = raw.range(of: close, range: open_..<raw.endIndex) else {
                    // Unterminated: give up the braces and keep scanning the
                    // rest as ordinary text.
                    index = open_
                    continue
                }

                // A nested opener inside the span wins — restart there rather
                // than swallowing it into the key.
                if let nested = raw.range(of: open, range: open_..<closeRange.lowerBound) {
                    flush()
                    literal += String(raw[open_..<nested.lowerBound])
                    index = nested.lowerBound
                    continue
                }

                // Collapse `}}}` and friends down to one closer.
                var after = closeRange.upperBound
                while after < raw.endIndex, raw[after] == "}" {
                    after = raw.index(after: after)
                }

                flush()
                let inner = String(raw[open_..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pieces.append(.placeholder(inner))
                index = after
                continue
            }

            literal.append(raw[index])
            index = raw.index(after: index)
        }

        flush()
        return pieces
    }
}

/// A glossary compiled into a lookup table, so rendering a list of captions
/// costs one build rather than one linear search per placeholder.
///
/// `Sendable` and `nonisolated` because the exporter is `@concurrent` and takes
/// only value types; build it on the main actor and hand it across.
nonisolated struct CaptionTermResolver: Sendable, Hashable {
    static let empty = CaptionTermResolver(terms: [])

    /// Normalized key → term. Variants are keyed too, so a model that echoes a
    /// known mis-spelling inside braces still lands on the right wording.
    private let byKey: [String: CaptionTerm]

    init(terms: [CaptionTerm]) {
        var table: [String: CaptionTerm] = [:]
        for term in terms where !term.isEmpty {
            for form in [term.text] + term.variants {
                let key = CaptionTermPlaceholder.key(form)
                guard !key.isEmpty, table[key] == nil else { continue }
                table[key] = term
            }
        }
        byKey = table
    }

    var isEmpty: Bool { byKey.isEmpty }

    func term(forKey inner: String) -> CaptionTerm? {
        let key = CaptionTermPlaceholder.key(inner)
        guard !key.isEmpty else { return nil }
        return byKey[key]
    }

    /// One placeholder's display text: the term's wording for this language, the
    /// term's canonical spelling when it has none, or — when the key matches no
    /// term at all — the inner text verbatim, which is the closest thing to what
    /// the model meant.
    func resolve(key inner: String, language: String) -> String {
        guard let term = term(forKey: inner) else { return inner }
        return term.rendered(in: language)
    }

    /// Raw stored text → what the reader sees. Never emits `{{` or `}}`.
    func render(_ raw: String, language: String) -> String {
        guard CaptionTermPlaceholder.contains(raw) else { return raw }
        var out = ""
        for piece in CaptionTermPlaceholder.scan(raw) {
            switch piece {
            case .literal(let text): out += text
            case .placeholder(let inner): out += resolve(key: inner, language: language)
            }
        }
        return out
    }

    /// Placeholders that match no glossary term, for the editor's warning.
    func unresolvedKeys(in raw: String) -> [String] {
        guard CaptionTermPlaceholder.contains(raw) else { return [] }
        var seen = Set<String>()
        return CaptionTermPlaceholder.keys(in: raw).filter { inner in
            guard !inner.isEmpty, term(forKey: inner) == nil else { return false }
            return seen.insert(inner).inserted
        }
    }

    /// Write-time hygiene for text that came from a model or a person.
    ///
    /// Fixes what is fixable and leaves the rest legible:
    /// - malformed braces are normalized away (`CaptionTermPlaceholder.scan`);
    /// - a matched key is rewritten to the term's canonical spelling, so stored
    ///   text is greppable and the raw view reads cleanly;
    /// - `{Term}` is promoted to `{{Term}}` only when it names a real term — an
    ///   unmatched `{...}` may well be legitimate text;
    /// - an unknown `{{Foo}}` is unwrapped to `Foo` when `unwrapUnknown` is set.
    ///   The AI path unwraps, because a hallucinated placeholder renders as its
    ///   inner text anyway and the braces are noise. The hand-edit path does
    ///   not, so someone writing `{{NewTerm}}` before creating the term keeps
    ///   their text and gets a warning instead.
    ///
    /// Idempotent: sanitizing sanitized text changes nothing.
    func sanitize(_ raw: String, unwrapUnknown: Bool) -> String {
        var out = ""
        for piece in CaptionTermPlaceholder.scan(raw) {
            switch piece {
            case .literal(let text):
                out += promoteSingleBraces(text)
            case .placeholder(let inner):
                if let term = term(forKey: inner) {
                    out += CaptionTermPlaceholder.wrap(term.text)
                } else if unwrapUnknown {
                    out += inner
                } else {
                    out += CaptionTermPlaceholder.wrap(inner)
                }
            }
        }
        return out
    }

    /// `{Term}` → `{{Term}}`, but only for text that names a glossary term.
    private func promoteSingleBraces(_ text: String) -> String {
        guard !isEmpty, text.contains("{") else { return text }
        var out = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "{",
                  let closeIndex = text[index...].firstIndex(of: "}")
            else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }

            let inner = String(text[text.index(after: index)..<closeIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let term = term(forKey: inner) {
                out += CaptionTermPlaceholder.wrap(term.text)
            } else {
                out += String(text[index...closeIndex])
            }
            index = text.index(after: closeIndex)
        }
        return out
    }
}
