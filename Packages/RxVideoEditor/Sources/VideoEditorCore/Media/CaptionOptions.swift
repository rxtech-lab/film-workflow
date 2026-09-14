import Foundation

/// What a caption clip draws from its transcript: which languages, stacked in
/// which order, and whether punctuation is dropped.
///
/// These are the burn-in half of the caption export's choices, kept per clip
/// rather than per render so the viewer shows exactly what will be drawn, and
/// so two caption clips in one sequence can speak different languages.
public struct CaptionOptions: Codable, Sendable, Hashable {
    /// Languages drawn in one caption, top line first. `""` is the transcript
    /// itself; a code the project has no translation for falls back to it.
    /// Never empty — a caption with no language would draw nothing at all.
    public var languages: [String]

    /// Draw the text without punctuation, the way the caption exporter's
    /// strip-punctuation mode writes it.
    public var stripsPunctuation: Bool

    public init(languages: [String] = [""], stripsPunctuation: Bool = false) {
        self.languages = Self.normalized(languages)
        self.stripsPunctuation = stripsPunctuation
    }

    /// The transcript on its own, punctuation intact: what every caption clip
    /// drew before these options existed.
    public static let transcript = CaptionOptions()

    /// Repeats would draw the same line twice and an empty list nothing at
    /// all, so both are corrected on the way in rather than at draw time.
    static func normalized(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        let unique = languages.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [""] : unique
    }

    /// One cue's drawn text: a line per chosen language, punctuation applied.
    ///
    /// A language the cue lacks falls back to the transcript, and a line equal
    /// to the one above it is dropped — asking for original + a translation
    /// that hasn't been made yet should read as one line, not two identical
    /// ones.
    public func text(for cue: TextCue) -> String {
        var lines: [String] = []
        for code in languages {
            // A resolver that carries the transcript under "" lets a clip ask
            // for it by name even when the cue's own text is something else.
            let raw = cue.translations[code].flatMap { $0.isEmpty ? nil : $0 } ?? cue.text
            let line = stripsPunctuation ? CaptionPunctuation.strip(raw) : raw
            guard !line.isEmpty, lines.last != line else { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case languages, stripsPunctuation
    }

    /// Tolerant of clips saved before these options existed: they decode as
    /// the transcript, which is what they were drawing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        languages = Self.normalized(try c.decodeIfPresent([String].self, forKey: .languages) ?? [""])
        stripsPunctuation = try c.decodeIfPresent(Bool.self, forKey: .stripsPunctuation) ?? false
    }
}

/// Drops punctuation and stray symbols, collapsing what is left to single
/// spaces.
///
/// Deliberately the same rule as the app's caption exporter, so a burned-in
/// caption and a sidecar file written with the same option read alike: letters,
/// digits and CJK glyphs are content, colons survive because they are
/// structural ("Alice: …"), everything else becomes a separator.
public enum CaptionPunctuation {
    public static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if isContent(character) {
                out.append(character)
                pendingSpace = false
                continue
            }
            if !pendingSpace {
                out.append(" ")
                pendingSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A character a reader takes as part of a word.
    public static func isContent(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        if character == ":" || character == "：" { return true }
        // `isLetter` already covers Han, kana and hangul; naming them keeps a
        // future stdlib change from silently stripping CJK captions to spaces.
        guard let scalar = character.unicodeScalars.first else { return false }
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
}
