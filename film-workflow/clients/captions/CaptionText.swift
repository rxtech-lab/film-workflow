import Foundation

/// Text primitives shared by cue building, tokenization, alignment and export.
///
/// Ported from `debate-bot/internal/stt/cues.go` and
/// `internal/subtitleutil/strip.go`. One deliberate difference from the Go
/// original: Go iterates `rune` (Unicode scalars) while these operate on Swift
/// `Character` (grapheme clusters). That is the correct unit here — cue length
/// limits and duration weights should count what a reader sees, so an emoji
/// with a skin-tone modifier or a combining accent counts once, not twice.
/// Scalar-range tests therefore look at a character's first scalar.
nonisolated struct CaptionText {

    // MARK: - Character classes

    /// Ends a sentence-level cue.
    ///
    /// Commas are deliberately absent: a comma-separated sentence must stay
    /// attached to one audio range instead of becoming several independently
    /// timed rows.
    static func isCueBoundary(_ c: Character) -> Bool {
        switch c {
        case ".", "!", "?", ";",
             "。", "！", "？", "；", "…":
            return true
        default:
            return false
        }
    }

    /// Trailing punctuation that means the provider cut mid-sentence.
    static func isClauseContinuation(_ c: Character) -> Bool {
        switch c {
        case ",", ":", "，", "、", "：":
            return true
        default:
            return false
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        let v = scalar.value
        switch v {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // CJK Unified Ext A
             0x20000...0x2A6DF, // CJK Unified Ext B
             0x3000...0x303F,   // CJK punctuation
             0xFF00...0xFFEF,   // Fullwidth forms
             0x3040...0x30FF,   // Hiragana + Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    /// A content character that should appear in a rendered caption and count
    /// toward duration weight. Colons are kept because they are usually
    /// structural ("Alice: …", "今晚的题目：归途").
    ///
    /// Deliberately *narrower* than `isCJK`: that predicate answers "does this
    /// script use inter-word spaces", so it includes CJK punctuation and
    /// fullwidth forms. This one answers "is this a readable word character",
    /// so `。` and `、` must fall through — otherwise stripped captions keep
    /// their punctuation and duration weights count separators as content.
    /// Matches `subtitleutil.isWordRune` in the Go reference.
    static func isWordRune(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        if c == ":" || c == "：" { return true }

        // `isLetter` already covers Han, kana and hangul, but be explicit so a
        // future stdlib change can't silently drop them.
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // CJK Unified Ext A
             0x20000...0x2A6DF, // CJK Unified Ext B
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    /// Whether reconstructing text from two adjacent words needs a separating
    /// space. Latin words do; CJK glyphs, and anything attaching to CJK, don't.
    static func needsSpace(_ prev: Character?, _ next: Character?) -> Bool {
        guard let prev, let next else { return false }
        if isCJK(prev) || isCJK(next) { return false }
        if next.isPunctuation { return false }
        return true
    }

    // MARK: - String helpers

    /// Count of content characters, used as duration-distribution weight.
    static func wordRuneCount(_ s: some StringProtocol) -> Int {
        s.count(where: isWordRune)
    }

    /// Appends `addition` to `base`, inserting a space only where the scripts
    /// require one.
    static func appendWord(_ addition: some StringProtocol, to base: inout String) {
        let trimmed = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !base.isEmpty, needsSpace(base.last, trimmed.first) {
            base.append(" ")
        }
        base.append(trimmed)
    }

    /// Joins two text runs with script-aware spacing.
    static func join(_ lhs: String, _ rhs: String) -> String {
        var out = lhs
        appendWord(rhs, to: &out)
        return out
    }

    /// Removes punctuation and stray symbols, collapsing everything else to
    /// single spaces. Port of `subtitleutil.StripPunct` — used by the exporter's
    /// optional "strip punctuation" mode for burn-in style captions.
    static func stripPunctuation(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var prevSpace = false
        for c in s {
            if isWordRune(c) {
                out.append(c)
                prevSpace = false
                continue
            }
            if !prevSpace {
                out.append(" ")
                prevSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Duration distribution

    /// Splits `[fromMs, toMs)` across `weights`, pinning the final slice to
    /// `toMs` so integer division never leaves a gap.
    ///
    /// The shared primitive behind `cuesFromText`, word rescaling, and the
    /// aligner's gap filling. A non-positive weight is treated as 1 so a
    /// punctuation-only token still gets a slice rather than collapsing.
    static func distribute(weights: [Int], fromMs: Int, toMs: Int) -> [(startMs: Int, endMs: Int)] {
        guard !weights.isEmpty else { return [] }
        let safeWeights = weights.map { max($0, 1) }
        let total = safeWeights.reduce(0, +)
        let span = max(toMs - fromMs, 0)

        var out: [(startMs: Int, endMs: Int)] = []
        out.reserveCapacity(safeWeights.count)
        var cursor = fromMs
        var consumed = 0

        for (index, weight) in safeWeights.enumerated() {
            let end: Int
            if index == safeWeights.count - 1 {
                end = toMs
            } else {
                consumed += weight
                end = fromMs + span * consumed / total
            }
            out.append((startMs: cursor, endMs: max(end, cursor)))
            cursor = max(end, cursor)
        }
        return out
    }

    /// Cuts text after every boundary character, hard-splitting boundary-free
    /// runs at `maxRunes`. Pieces are trimmed; empty pieces are dropped.
    static func splitAtBoundaries(_ text: String, maxRunes: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var runes = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
            runes = 0
        }

        for c in text {
            current.append(c)
            runes += 1
            if isCueBoundary(c) || (maxRunes > 0 && runes >= maxRunes) {
                flush()
            }
        }
        flush()
        return pieces
    }
}
