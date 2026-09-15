import Foundation

/// Optional timed lyrics, one track per language. Times refer to the full song.
nonisolated struct MarketplaceLyricTrack: Codable, Hashable, Sendable, Identifiable {
    var language: String
    var cues: [Cue]
    var id: String { language.lowercased() }
    var displayName: String {
        if language.isEmpty || language.lowercased() == "und" { return String(localized: "Original") }
        return Locale.current.localizedString(forIdentifier: language) ?? language
    }

    static func setLanguage(_ language: String, for trackID: String, in tracks: inout [Self]) throws {
        let code = try CaptionLanguage.normalized(language)
        let stored = code.isEmpty ? "und" : code
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard !tracks.enumerated().contains(where: { $0.offset != index && $0.element.id == stored.lowercased() }) else {
            throw MarketplaceAuthoringError.invalid("A lyrics track already uses this language. Choose a different language.")
        }
        tracks[index].language = stored
    }

    struct Cue: Codable, Hashable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    func text(at time: Double) -> String {
        cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
    }

    static func parse(_ source: String, language: String) throws -> Self {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language.range(of: "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil else {
            throw MarketplaceAuthoringError.invalid("Use a language code such as en or zh-Hans.")
        }
        guard source.utf8.count <= 512_000 else { throw MarketplaceAuthoringError.invalid("Caption files must be under 500 KB.") }
        let normalized = source.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n[ \\t]*\n", with: "\n\n", options: .regularExpression)
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") where !block.isEmpty {
            let lines = block.components(separatedBy: "\n")
            guard let first = lines.first else { continue }
            if first.range(of: "^(WEBVTT(?:\\s|$)|NOTE(?:\\s|$)|STYLE$|REGION$)", options: .regularExpression) != nil { continue }
            let index = first.contains("-->") ? 0 : 1
            guard lines.indices.contains(index) else { throw invalidCaptions }
            let timing = lines[index].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = timestamp(timing[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = timing[1].split(whereSeparator: \.isWhitespace).first,
                  let end = timestamp(String(endToken)), end > start, end <= 86_400 else { throw invalidCaptions }
            let text = lines.dropFirst(index + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 2000 else { throw invalidCaptions }
            cues.append(Cue(start: start, end: end, text: text))
        }
        guard !cues.isEmpty, cues.count <= 2000 else { throw invalidCaptions }
        return Self(language: language, cues: cues.sorted { $0.start < $1.start })
    }

    private static var invalidCaptions: MarketplaceAuthoringError {
        .invalid("Use an SRT or VTT file with valid timed captions.")
    }

    private static func timestamp(_ text: String) -> Double? {
        guard text.range(of: "^(?:\\d{2,}:)?\\d{2}:\\d{2}[.,]\\d{3}$", options: .regularExpression) != nil else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count), let seconds = parts.last, seconds < 60, parts[parts.count - 2] < 60 else { return nil }
        return (parts.count == 3 ? parts[0] * 3600 : 0) + parts[parts.count - 2] * 60 + seconds
    }
}
