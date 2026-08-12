import Foundation

/// One comparable unit of text on either side of narrative alignment.
nonisolated struct CaptionToken: Sendable, Hashable {
    /// Exactly as it appears in the source, punctuation and case intact. This
    /// is what gets rendered, so it must round-trip byte-for-byte.
    var display: String

    /// Case/width/diacritic-folded, punctuation-stripped matching key.
    /// Empty means punctuation-only: kept in the sequence so `display` still
    /// round-trips, but never used as an alignment anchor.
    var normalized: String

    /// Content-character count, the weight used when distributing durations.
    var runeWeight: Int

    /// `display` ends with sentence-boundary punctuation, so a cue can close
    /// here.
    var isSentenceEnd: Bool

    /// Index into the project's `referenceUnits` (reference side only).
    var unitIndex: Int = -1

    /// Speaker carried from the reference unit (reference side only).
    var speakerId: UUID?

    /// Index into the hypothesis word array (hypothesis side only), so a match
    /// can find its timing.
    var timingIndex: Int = -1

    /// Whether this token can serve as an alignment anchor.
    var isAnchorable: Bool { !normalized.isEmpty }

    init(
        display: String,
        normalized: String,
        runeWeight: Int,
        isSentenceEnd: Bool,
        unitIndex: Int = -1,
        speakerId: UUID? = nil,
        timingIndex: Int = -1
    ) {
        self.display = display
        self.normalized = normalized
        self.runeWeight = runeWeight
        self.isSentenceEnd = isSentenceEnd
        self.unitIndex = unitIndex
        self.speakerId = speakerId
        self.timingIndex = timingIndex
    }
}

/// Splits reference and hypothesis text into comparable tokens.
///
/// The critical design point is CJK handling: each CJK grapheme cluster becomes
/// its own token, while runs of non-CJK characters accumulate into one Latin
/// token. That makes the reference tokenization structurally identical to what
/// Azure returns for CJK audio (one "word" per glyph — see the `欢/迎/大/家。`
/// fixture in `debate-bot/internal/stt/azure_test.go`) and to Whisper's CJK
/// tokens. Without it, CJK alignment cannot match at all.
nonisolated struct CaptionTokenizer {

    /// Tokenizes the narrative reference, tagging each token with its unit and
    /// speaker so cue construction never merges across a speaker change.
    static func tokenizeReference(_ units: [CaptionReferenceUnit]) -> [CaptionToken] {
        var out: [CaptionToken] = []
        for (index, unit) in units.sorted(by: { $0.order < $1.order }).enumerated() {
            for token in tokenize(unit.plainText) {
                var copy = token
                copy.unitIndex = index
                copy.speakerId = unit.speakerId
                out.append(copy)
            }
        }
        return out
    }

    /// Tokenizes ASR word timings. A provider "word" may itself contain several
    /// CJK glyphs, so it is re-split by the same rules; every resulting token
    /// keeps `timingIndex` pointing at the originating timing.
    static func tokenizeHypothesis(_ words: [CaptionWordTiming]) -> [CaptionToken] {
        var out: [CaptionToken] = []
        for (index, word) in words.enumerated() {
            for token in tokenize(word.text) {
                var copy = token
                copy.timingIndex = index
                out.append(copy)
            }
        }
        return out
    }

    /// The shared splitter: whitespace separates tokens, each CJK cluster is its
    /// own token, and runs of non-CJK non-space characters group together.
    static func tokenize(_ text: String) -> [CaptionToken] {
        var out: [CaptionToken] = []
        var buffer = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            out.append(makeToken(buffer))
            buffer = ""
        }

        for character in text {
            if character.isWhitespace {
                flushBuffer()
                continue
            }
            if CaptionText.isCJK(character) {
                // A CJK glyph stands alone, but trailing punctuation attaches to
                // the glyph before it — matching Azure, which emits "家。" as one
                // word rather than splitting the full stop off.
                if character.isPunctuation || character.isSymbol, let last = out.last {
                    var updated = last
                    updated.display += String(character)
                    updated.isSentenceEnd = CaptionText.isCueBoundary(character)
                    out[out.count - 1] = updated
                } else {
                    flushBuffer()
                    out.append(makeToken(String(character)))
                }
                continue
            }
            buffer.append(character)
        }
        flushBuffer()
        return out
    }

    private static func makeToken(_ raw: String) -> CaptionToken {
        CaptionToken(
            display: raw,
            normalized: normalize(raw),
            runeWeight: max(CaptionText.wordRuneCount(raw), 1),
            isSentenceEnd: raw.last.map(CaptionText.isCueBoundary) ?? false
        )
    }

    /// Builds the matching key.
    ///
    /// 1. Fold case, width and diacritics so "Café" matches "cafe" and
    ///    fullwidth Latin matches ASCII.
    /// 2. Drop everything that isn't a content character, which removes edge
    ///    punctuation *and* internal apostrophes/hyphens — so "don't" matches
    ///    "dont" and "well-known" matches "well known". ASR punctuation choices
    ///    should never cost a match.
    ///
    /// Digits are kept as digits: both sides usually agree, and when they don't
    /// ("20" vs "twenty") the token simply fails to anchor and gets interpolated
    /// from its neighbours, which is the correct outcome.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return String(folded.filter { CaptionText.isWordRune($0) && $0 != ":" && $0 != "：" })
    }
}
