import Foundation
import UniformTypeIdentifiers

nonisolated struct CaptionExportOptions: Sendable, Equatable, Hashable {
    enum SpeakerStyle: String, CaseIterable, Codable, Identifiable, Sendable {
        /// No speaker information in the output.
        case none
        /// `Alice: text`
        case prefix
        /// `<v Alice>text` — WebVTT voice spans, which players can style.
        case vttVoiceTag

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "None"
            case .prefix: return "Name prefix"
            case .vttVoiceTag: return "WebVTT voice tag"
            }
        }
    }

    /// How a translation and its original share a cue.
    enum TranslationMode: String, CaseIterable, Codable, Identifiable, Sendable {
        /// Ignore translations entirely.
        case originalOnly
        /// Original on the first line, translation underneath — the shape
        /// bilingual subtitles take in the wild.
        case bilingual
        /// Translation alone.
        case translationOnly

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .originalOnly: return "Original only"
            case .bilingual: return "Original + translation"
            case .translationOnly: return "Translation only"
            }
        }
    }

    var format: CaptionExportFormat = .vtt
    var granularity: CaptionExportGranularity = .sentence
    var speakerStyle: SpeakerStyle = .prefix

    var translationMode: TranslationMode = .originalOnly

    /// BCP-47 code of the translation to render. Empty means original only,
    /// whatever `translationMode` says.
    var translationLanguage: String = ""

    /// Plain text only: prefix each line with `[mm:ss]`.
    var includeTimestampsInText: Bool = false

    var stripPunctuation: Bool = false

    /// Re-wrap sentence cues longer than this many grapheme clusters,
    /// distributing the cue's duration by weight. 0 disables re-wrapping.
    /// 44 mirrors a typical burn-in width.
    var maxRunesPerCue: Int = 0

    /// New parameters go at the end with defaults so existing call sites — and
    /// the exporter's golden-string tests — keep compiling untouched.
    init(
        format: CaptionExportFormat = .vtt,
        granularity: CaptionExportGranularity = .sentence,
        speakerStyle: SpeakerStyle = .prefix,
        includeTimestampsInText: Bool = false,
        stripPunctuation: Bool = false,
        maxRunesPerCue: Int = 0,
        translationMode: TranslationMode = .originalOnly,
        translationLanguage: String = ""
    ) {
        self.format = format
        self.granularity = granularity
        self.speakerStyle = speakerStyle
        self.includeTimestampsInText = includeTimestampsInText
        self.stripPunctuation = stripPunctuation
        self.maxRunesPerCue = maxRunesPerCue
        self.translationMode = translationMode
        self.translationLanguage = translationLanguage
    }

    /// Mode the options can actually express. Choosing a layout without picking
    /// a language means nothing, so it degrades to original-only — same
    /// tolerance as `effectiveGranularity`.
    var effectiveTranslationMode: TranslationMode {
        translationLanguage.isEmpty ? .originalOnly : translationMode
    }

    /// Granularity the format can actually express. Word-karaoke silently
    /// degrades to sentence for SRT/text/JSON rather than emitting VTT syntax
    /// into a file that can't hold it.
    var effectiveGranularity: CaptionExportGranularity {
        // Translations have no word timings, so there is nothing to karaoke and
        // nothing to cut per word. Sentence is the only honest granularity.
        if effectiveTranslationMode != .originalOnly { return .sentence }
        if granularity == .wordKaraoke, !format.supportsWordKaraoke { return .sentence }
        return granularity
    }

    var effectiveSpeakerStyle: SpeakerStyle {
        if speakerStyle == .vttVoiceTag, !format.supportsSpeakerVoiceTags { return .prefix }
        return speakerStyle
    }
}

nonisolated enum CaptionExportError: LocalizedError {
    case noSegments
    case noWordTimings
    case noTranslation(String)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "There are no captions to export."
        case .noWordTimings:
            return "This transcript has no word timings, so word-level export is unavailable."
        case .noTranslation(let language):
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            return "There is no \(name) translation to export. Run a translation pass first."
        }
    }
}

/// Renders a caption transcript to VTT, SRT, plain text, or JSON.
///
/// Ported from `debate-bot/internal/content_creator/subtitle.go`. One deliberate
/// deviation: the Go server transcoded VTT→SRT as text because its source of
/// truth was a `.vtt` file on disk. Here the source of truth is `[CaptionCue]`,
/// so SRT renders directly from cues — no re-parsing, and none of the cue-
/// settings/CRLF/renumbering bugs that came with it.
nonisolated struct CaptionExporter {

    @concurrent
    static func render(
        _ snapshot: CaptionTranscriptSnapshot,
        options: CaptionExportOptions
    ) async throws -> Data {
        guard !snapshot.segments.isEmpty else { throw CaptionExportError.noSegments }

        // A translation-only export of a transcript that was never translated
        // would be a file of blank cues. Fail loudly instead.
        if options.effectiveTranslationMode == .translationOnly,
           !snapshot.hasTranslation(options.translationLanguage) {
            throw CaptionExportError.noTranslation(options.translationLanguage)
        }

        if options.format == .json {
            return try renderJSON(snapshot)
        }

        let cues = cues(from: snapshot, options: options)
        guard !cues.isEmpty else { throw CaptionExportError.noSegments }

        let text: String
        switch options.format {
        case .vtt: text = renderVTT(cues, snapshot: snapshot, options: options)
        case .srt: text = renderSRT(cues, snapshot: snapshot, options: options)
        case .text: text = renderText(cues, snapshot: snapshot, options: options)
        case .json: text = ""
        }
        return Data(text.utf8)
    }

    // MARK: - Cue generation

    /// Expands the stored segments into the cue list the chosen granularity
    /// implies. Word cues come from stored word timings; when a segment has
    /// none, its duration is split proportionally so word export still works
    /// for providers like Gemini.
    static func cues(
        from snapshot: CaptionTranscriptSnapshot,
        options: CaptionExportOptions
    ) -> [CaptionCue] {
        switch options.effectiveGranularity {
        case .sentence, .wordKaraoke:
            let base = snapshot.segments.map { segment in
                CaptionCue(
                    speakerId: segment.speakerId,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    words: segment.words,
                    isEstimatedTiming: segment.isEstimatedTiming,
                    translation: segment.translation(options.translationLanguage)
                )
            }
            guard options.maxRunesPerCue > 0, options.effectiveGranularity == .sentence else {
                return base
            }
            // Re-wrapping cuts a cue by rune weight. There is no principled way
            // to cut its translation to match — the two languages don't break at
            // the same points — so a translated export keeps whole cues.
            guard options.effectiveTranslationMode == .originalOnly else { return base }
            return base.flatMap { rewrap($0, maxRunes: options.maxRunesPerCue) }

        case .word:
            return snapshot.segments.flatMap { segment -> [CaptionCue] in
                let words = wordsForExport(of: segment)
                return words.map { word in
                    CaptionCue(
                        speakerId: segment.speakerId,
                        startMs: word.offsetMs,
                        endMs: word.endMs,
                        text: word.text,
                        isEstimatedTiming: segment.isEstimatedTiming || word.isEstimated
                    )
                }
            }
        }
    }

    /// Stored words, or a proportional split of the segment when the provider
    /// gave none.
    static func wordsForExport(of segment: CaptionSegmentSnapshot) -> [CaptionWord] {
        if !segment.words.isEmpty { return segment.words }

        let pieces = segment.text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !pieces.isEmpty else { return [] }

        let spans = CaptionText.distribute(
            weights: pieces.map { CaptionText.wordRuneCount($0) },
            fromMs: segment.startMs,
            toMs: segment.endMs
        )
        return zip(pieces, spans).map { piece, span in
            CaptionWord(
                text: piece,
                offsetMs: span.startMs,
                durationMs: max(span.endMs - span.startMs, 0),
                isEstimated: true
            )
        }
    }

    /// Splits an over-long cue into pieces, distributing its duration by weight.
    static func rewrap(_ cue: CaptionCue, maxRunes: Int) -> [CaptionCue] {
        guard cue.text.count > maxRunes else { return [cue] }
        let pieces = CaptionText.splitAtBoundaries(cue.text, maxRunes: maxRunes)
        guard pieces.count > 1 else { return [cue] }

        let spans = CaptionText.distribute(
            weights: pieces.map { CaptionText.wordRuneCount($0) },
            fromMs: cue.startMs,
            toMs: cue.endMs
        )
        return zip(pieces, spans).map { piece, span in
            var copy = cue
            copy.text = piece
            copy.startMs = span.startMs
            copy.endMs = span.endMs
            copy.words = cue.words.filter { $0.offsetMs >= span.startMs && $0.endMs <= span.endMs }
            return copy
        }
    }

    // MARK: - Bilingual bodies

    /// The lines one cue contributes, before escaping.
    ///
    /// A cue with no translation falls back to its original in
    /// `.translationOnly` rather than emitting an empty body — players render an
    /// empty cue as a visible blank flash, which is worse than an untranslated
    /// line the user can spot and fix. `render` has already rejected the case
    /// where *nothing* was translated, so this only covers the ragged tail.
    static func bodyLines(_ cue: CaptionCue, options: CaptionExportOptions) -> [String] {
        let original = displayText(cue.text, options: options)
        guard options.effectiveTranslationMode != .originalOnly else { return [original] }

        let translated = displayText(cue.translation, options: options)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return [original] }

        switch options.effectiveTranslationMode {
        case .originalOnly: return [original]
        case .translationOnly: return [translated]
        case .bilingual: return [original, translated]
        }
    }

    // MARK: - Renderers

    static func renderVTT(
        _ cues: [CaptionCue],
        snapshot: CaptionTranscriptSnapshot,
        options: CaptionExportOptions
    ) -> String {
        var out = "WEBVTT\n\n"
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(vttTimestamp(cue.startMs)) --> \(vttTimestamp(cue.endMs))\n"
            out += vttPayload(cue, snapshot: snapshot, options: options)
            out += "\n\n"
        }
        return out
    }

    private static func vttPayload(
        _ cue: CaptionCue,
        snapshot: CaptionTranscriptSnapshot,
        options: CaptionExportOptions
    ) -> String {
        let label = snapshot.speakerLabel(cue.speakerId)

        if options.effectiveGranularity == .wordKaraoke, !cue.words.isEmpty {
            // Standard karaoke form: the cue starts with the first word, then
            // each later word is preceded by its own timestamp tag.
            var body = ""
            for (index, word) in cue.words.enumerated() {
                let text = escapeVTT(displayText(word.text, options: options))
                if text.isEmpty { continue }
                if index == 0 {
                    body += text
                } else {
                    body += " <\(vttTimestamp(word.offsetMs))>\(text)"
                }
            }
            return decorate(body, label: label, options: options)
        }

        // Each line is escaped separately and joined with a raw newline: WebVTT
        // genuinely supports multi-line cue payloads, and the speaker decoration
        // belongs on the first line only.
        let lines = bodyLines(cue, options: options).map { escapeVTT($0) }
        guard let first = lines.first else { return "" }
        let head = decorate(first, label: label, options: options)
        return ([head] + lines.dropFirst()).joined(separator: "\n")
    }

    private static func decorate(
        _ body: String,
        label: String,
        options: CaptionExportOptions
    ) -> String {
        guard !label.isEmpty else { return body }
        switch options.effectiveSpeakerStyle {
        case .none: return body
        case .prefix: return "\(label): \(body)"
        case .vttVoiceTag: return "<v \(escapeVTT(label))>\(body)"
        }
    }

    static func renderSRT(
        _ cues: [CaptionCue],
        snapshot: CaptionTranscriptSnapshot,
        options: CaptionExportOptions
    ) -> String {
        var out = ""
        for (index, cue) in cues.enumerated() {
            let label = snapshot.speakerLabel(cue.speakerId)
            var lines = bodyLines(cue, options: options).map { escapeSRT($0) }
            if !label.isEmpty, options.effectiveSpeakerStyle != .none, !lines.isEmpty {
                lines[0] = "\(label): \(lines[0])"
            }
            // SRT conventionally uses CRLF line endings — including between the
            // two lines of a bilingual cue, which is exactly the two-line shape
            // bilingual subtitles use in the wild.
            out += "\(index + 1)\r\n"
            out += "\(srtTimestamp(cue.startMs)) --> \(srtTimestamp(cue.endMs))\r\n"
            out += "\(lines.joined(separator: "\r\n"))\r\n\r\n"
        }
        return out
    }

    static func renderText(
        _ cues: [CaptionCue],
        snapshot: CaptionTranscriptSnapshot,
        options: CaptionExportOptions
    ) -> String {
        var out = ""
        var lastLabel: String?

        for cue in cues {
            let label = snapshot.speakerLabel(cue.speakerId)
            var prefix = ""

            if options.includeTimestampsInText {
                prefix += "[\(shortTimestamp(cue.startMs))] "
            }
            // Only repeat the speaker name when it changes, so a monologue
            // reads as prose instead of a wall of "Alice:".
            if !label.isEmpty, options.effectiveSpeakerStyle != .none, label != lastLabel {
                prefix += "\(label): "
            }
            // One output line per body line; the prefix goes on the original
            // only, so a bilingual transcript still reads as prose.
            for (index, body) in bodyLines(cue, options: options).enumerated() {
                out += (index == 0 ? prefix : "") + body + "\n"
            }
            lastLabel = label.isEmpty ? lastLabel : label
        }
        return out
    }

    static func renderJSON(_ snapshot: CaptionTranscriptSnapshot) throws -> Data {
        struct WordDTO: Encodable {
            let text: String
            let offsetMs: Int
            let durationMs: Int
            let confidence: Double
            let isEstimated: Bool
        }
        struct SegmentDTO: Encodable {
            let startMs: Int
            let endMs: Int
            let text: String
            let speaker: String
            let isEstimatedTiming: Bool
            let translations: [String: String]
            let words: [WordDTO]
        }
        struct DocumentDTO: Encodable {
            let name: String
            let durationMs: Int
            let alignmentQuality: String
            let sourceLanguage: String
            let version: Int
            let translationLanguages: [String]
            let speakers: [String]
            let segments: [SegmentDTO]
        }

        // JSON deliberately ignores `translationMode` and emits every language,
        // for the same reason it already ignores granularity and speaker style:
        // it is a data format, and those are presentation choices.
        let document = DocumentDTO(
            name: snapshot.projectName,
            durationMs: snapshot.audioDurationMs,
            alignmentQuality: snapshot.alignmentQuality.rawValue,
            sourceLanguage: snapshot.sourceLanguage,
            version: snapshot.versionNumber,
            translationLanguages: snapshot.availableTranslations,
            speakers: snapshot.speakers.map(\.label),
            segments: snapshot.segments.map { segment in
                SegmentDTO(
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    speaker: segment.speakerLabel,
                    isEstimatedTiming: segment.isEstimatedTiming,
                    translations: segment.translations,
                    words: segment.words.map {
                        WordDTO(
                            text: $0.text,
                            offsetMs: $0.offsetMs,
                            durationMs: $0.durationMs,
                            confidence: $0.confidence,
                            isEstimated: $0.isEstimated
                        )
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    // MARK: - Formatting primitives

    private static func displayText(_ text: String, options: CaptionExportOptions) -> String {
        options.stripPunctuation ? CaptionText.stripPunctuation(text) : text
    }

    /// `HH:MM:SS.mmm` — the canonical WebVTT timestamp. Negatives clamp to zero.
    static func vttTimestamp(_ ms: Int) -> String {
        let (h, m, s, milli) = components(ms)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, milli)
    }

    /// `HH:MM:SS,mmm` — SRT uses a comma for the decimal separator.
    static func srtTimestamp(_ ms: Int) -> String {
        let (h, m, s, milli) = components(ms)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }

    /// `mm:ss`, or `h:mm:ss` past an hour — for plain-text line prefixes.
    static func shortTimestamp(_ ms: Int) -> String {
        let (h, m, s, _) = components(ms)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private static func components(_ ms: Int) -> (Int, Int, Int, Int) {
        var total = max(ms, 0)
        let hours = total / 3_600_000
        total -= hours * 3_600_000
        let minutes = total / 60_000
        total -= minutes * 60_000
        let seconds = total / 1_000
        let millis = total - seconds * 1_000
        return (hours, minutes, seconds, millis)
    }

    /// Minimal WebVTT escaping.
    ///
    /// Newlines are collapsed to spaces: callers pass one line at a time, so a
    /// newline inside the text is stray data that would split the cue block.
    /// Bilingual output composes multi-line payloads by escaping each line and
    /// joining them itself — see `vttPayload`.
    static func escapeVTT(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SRT has no markup, so only newline normalization is needed — a stray
    /// newline would otherwise split one cue into two malformed blocks.
    static func escapeSRT(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        out = out.replacingOccurrences(of: "\n", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filenames

    /// `{project}_{language}[.words].{ext}`.
    ///
    /// The language code is what makes a multi-language export unambiguous once
    /// several files land in the same folder. It is omitted when empty, so the
    /// single-file case keeps the name it has always had.
    static func defaultFilename(
        projectName: String,
        options: CaptionExportOptions,
        languageCode: String = ""
    ) -> String {
        let base = sanitize(projectName.isEmpty ? "captions" : projectName)
        let language = languageCode.isEmpty ? "" : "_\(sanitize(languageCode))"
        let suffix: String
        switch options.effectiveGranularity {
        case .sentence: suffix = ""
        case .word: suffix = ".words"
        case .wordKaraoke: suffix = ".karaoke"
        }
        return "\(base)\(language)\(suffix).\(options.format.fileExtension)"
    }

    /// The code that belongs in a single file's name for these options: the
    /// translation target when one is selected, and nothing otherwise.
    ///
    /// Deliberately *not* falling back to `snapshot.sourceLanguage` — that would
    /// rename every ordinary export from `Talk.srt` to `Talk_en.srt` for no
    /// reason. The multi-file path passes the source language explicitly, where
    /// it is needed to keep the original from colliding with its translations.
    static func filenameLanguageCode(options: CaptionExportOptions) -> String {
        options.translationLanguage
    }

    /// Keeps filenames safe on every platform: alphanumerics, spaces, dashes
    /// and underscores survive; everything else becomes a dash.
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_"))
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        var collapsed = mapped
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        collapsed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "captions" : collapsed
    }
}

extension CaptionExportFormat {
    /// `UTType(mimeType:)` can return nil for `text/vtt` on some systems; the
    /// filename extension carries the real intent, so falling back to plain
    /// text is safe.
    var utType: UTType {
        switch self {
        case .vtt: return UTType(filenameExtension: "vtt") ?? .plainText
        case .srt: return UTType(filenameExtension: "srt") ?? .plainText
        case .text: return .plainText
        case .json: return .json
        }
    }
}
