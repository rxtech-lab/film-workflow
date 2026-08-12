import Foundation
import Testing

@testable import film_workflow

/// Golden-string tests for the export layer. The exact byte layout matters:
/// players are unforgiving about VTT/SRT framing, so these assert whole
/// documents rather than substrings.
@Suite("Caption export")
struct CaptionExporterTests {

    private let alice = CaptionSpeaker(label: "Alice", providerSpeakerNumber: 1)
    private let bob = CaptionSpeaker(label: "Bob", providerSpeakerNumber: 2)

    private func snapshot(
        segments: [CaptionSegmentSnapshot],
        speakers: [CaptionSpeaker]? = nil,
        durationMs: Int = 60_000
    ) -> CaptionTranscriptSnapshot {
        CaptionTranscriptSnapshot(
            projectName: "Episode 12",
            audioDurationMs: durationMs,
            speakers: speakers ?? [alice, bob],
            segments: segments
        )
    }

    /// The Azure fixture's first phrase, as an edited segment.
    private var goodAfternoon: CaptionSegmentSnapshot {
        CaptionSegmentSnapshot(
            startMs: 960,
            endMs: 1600,
            text: "Good afternoon.",
            speakerId: alice.id,
            speakerLabel: "Alice",
            words: [
                CaptionWord(text: "Good", offsetMs: 960, durationMs: 240),
                CaptionWord(text: "afternoon.", offsetMs: 1200, durationMs: 400),
            ]
        )
    }

    // MARK: - WebVTT

    @Test("Sentence VTT matches the canonical layout")
    func sentenceVTT() async throws {
        let data = try await CaptionExporter.render(
            snapshot(segments: [goodAfternoon]),
            options: .init(format: .vtt, granularity: .sentence, speakerStyle: .none)
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == """
        WEBVTT

        1
        00:00:00.960 --> 00:00:01.600
        Good afternoon.


        """)
    }

    @Test("Speaker prefix and VTT voice tags render distinctly")
    func vttSpeakerStyles() async throws {
        let prefixed = try await CaptionExporter.render(
            snapshot(segments: [goodAfternoon]),
            options: .init(format: .vtt, speakerStyle: .prefix)
        )
        #expect(String(decoding: prefixed, as: UTF8.self).contains("Alice: Good afternoon."))

        let tagged = try await CaptionExporter.render(
            snapshot(segments: [goodAfternoon]),
            options: .init(format: .vtt, speakerStyle: .vttVoiceTag)
        )
        #expect(String(decoding: tagged, as: UTF8.self).contains("<v Alice>Good afternoon."))
    }

    @Test("Karaoke VTT emits inline word timestamps after the first word")
    func karaokeVTT() async throws {
        let data = try await CaptionExporter.render(
            snapshot(segments: [goodAfternoon]),
            options: .init(format: .vtt, granularity: .wordKaraoke, speakerStyle: .none)
        )
        let text = String(decoding: data, as: UTF8.self)
        // First word is bare; later words carry their own timestamp tag.
        #expect(text.contains("Good <00:00:01.200>afternoon."))
        #expect(!text.contains("<00:00:00.960>Good"))
    }

    @Test("Karaoke degrades to sentence for formats that cannot express it")
    func karaokeDegradesForSRT() async throws {
        let options = CaptionExportOptions(format: .srt, granularity: .wordKaraoke)
        #expect(options.effectiveGranularity == .sentence)

        let data = try await CaptionExporter.render(snapshot(segments: [goodAfternoon]), options: options)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("<00:"))
    }

    // MARK: - SubRip

    @Test("SRT uses comma decimals and CRLF framing")
    func sentenceSRT() async throws {
        let data = try await CaptionExporter.render(
            snapshot(segments: [goodAfternoon]),
            options: .init(format: .srt, speakerStyle: .none)
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "1\r\n00:00:00,960 --> 00:00:01,600\r\nGood afternoon.\r\n\r\n")
    }

    @Test("SRT renumbers cues from one")
    func srtRenumbers() async throws {
        let segments = (0..<3).map { index in
            CaptionSegmentSnapshot(
                startMs: index * 1000,
                endMs: index * 1000 + 500,
                text: "Line \(index).",
                speakerId: alice.id,
                speakerLabel: "Alice"
            )
        }
        let data = try await CaptionExporter.render(
            snapshot(segments: segments),
            options: .init(format: .srt, speakerStyle: .none)
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("1\r\n"))
        #expect(text.contains("\r\n2\r\n"))
        #expect(text.contains("\r\n3\r\n"))
    }

    // MARK: - Word granularity

    @Test("Word granularity emits one cue per stored word timing")
    func wordGranularity() async throws {
        let data = try await CaptionExporter.render(
            snapshot(segments: [goodAfternoon]),
            options: .init(format: .vtt, granularity: .word, speakerStyle: .none)
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == """
        WEBVTT

        1
        00:00:00.960 --> 00:00:01.200
        Good

        2
        00:00:01.200 --> 00:00:01.600
        afternoon.


        """)
    }

    @Test("Word granularity falls back to a proportional split with no word timings")
    func wordGranularityWithoutTimings() async throws {
        // The Gemini case: phrase offsets only, no words.
        let segment = CaptionSegmentSnapshot(
            startMs: 0, endMs: 900, text: "aaa bbb ccc",
            speakerId: alice.id, speakerLabel: "Alice"
        )
        let words = CaptionExporter.wordsForExport(of: segment)

        #expect(words.map(\.text) == ["aaa", "bbb", "ccc"])
        #expect(words.allSatisfy { $0.isEstimated })
        // Equal weights split evenly and the last word lands on the segment end.
        #expect(words[0].offsetMs == 0)
        #expect(words.last?.endMs == 900)
        for index in 0..<(words.count - 1) {
            #expect(words[index].endMs == words[index + 1].offsetMs)
        }
    }

    // MARK: - Plain text

    @Test("Plain text prints a speaker label only when it changes")
    func plainTextCollapsesRepeatedSpeakers() async throws {
        let segments = [
            CaptionSegmentSnapshot(startMs: 0, endMs: 500, text: "One.", speakerId: alice.id, speakerLabel: "Alice"),
            CaptionSegmentSnapshot(startMs: 500, endMs: 1000, text: "Two.", speakerId: alice.id, speakerLabel: "Alice"),
            CaptionSegmentSnapshot(startMs: 1000, endMs: 1500, text: "Three.", speakerId: bob.id, speakerLabel: "Bob"),
        ]
        let data = try await CaptionExporter.render(
            snapshot(segments: segments),
            options: .init(format: .text, speakerStyle: .prefix)
        )
        #expect(String(decoding: data, as: UTF8.self) == """
        Alice: One.
        Two.
        Bob: Three.

        """)
    }

    @Test("Plain text can prefix timestamps")
    func plainTextTimestamps() async throws {
        let segment = CaptionSegmentSnapshot(
            startMs: 65_000, endMs: 66_000, text: "Later.",
            speakerId: alice.id, speakerLabel: "Alice"
        )
        let data = try await CaptionExporter.render(
            snapshot(segments: [segment], durationMs: 120_000),
            options: .init(format: .text, speakerStyle: .none, includeTimestampsInText: true)
        )
        #expect(String(decoding: data, as: UTF8.self) == "[01:05] Later.\n")
    }

    // MARK: - Escaping and timestamps

    @Test("VTT escaping neutralizes markup and collapses newlines")
    func vttEscaping() {
        #expect(CaptionExporter.escapeVTT("a & b < c > d") == "a &amp; b &lt; c &gt; d")
        #expect(CaptionExporter.escapeVTT("one\r\ntwo\rthree\nfour") == "one two three four")
    }

    @Test("Timestamps format hours, and negatives clamp to zero")
    func timestampFormatting() {
        #expect(CaptionExporter.vttTimestamp(0) == "00:00:00.000")
        #expect(CaptionExporter.vttTimestamp(3_661_001) == "01:01:01.001")
        #expect(CaptionExporter.srtTimestamp(3_661_001) == "01:01:01,001")
        #expect(CaptionExporter.vttTimestamp(-5) == "00:00:00.000")
        #expect(CaptionExporter.shortTimestamp(65_000) == "01:05")
        #expect(CaptionExporter.shortTimestamp(3_665_000) == "1:01:05")
    }

    @Test("Strip punctuation keeps words and collapses separators")
    func stripPunctuation() {
        #expect(CaptionText.stripPunctuation("Hello, world!") == "Hello world")
        // CJK has no inter-glyph spaces to preserve.
        #expect(CaptionText.stripPunctuation("欢迎大家。") == "欢迎大家")
    }

    // MARK: - Filenames

    @Test("Filenames are sanitized and carry a granularity suffix")
    func filenames() {
        #expect(CaptionExporter.defaultFilename(
            projectName: "Episode 12", options: .init(format: .vtt, granularity: .sentence)
        ) == "Episode-12.vtt")

        #expect(CaptionExporter.defaultFilename(
            projectName: "Episode 12", options: .init(format: .srt, granularity: .word)
        ) == "Episode-12.words.srt")

        // Path separators and other unsafe characters must not survive.
        #expect(!CaptionExporter.sanitize("a/b:c*d").contains("/"))
        #expect(CaptionExporter.sanitize("") == "captions")
        #expect(CaptionExporter.sanitize("!!!") == "captions")
    }

    @Test("Exporting with no segments fails loudly")
    func emptyExportThrows() async {
        await #expect(throws: CaptionExportError.self) {
            _ = try await CaptionExporter.render(snapshot(segments: []), options: .init())
        }
    }

    // MARK: - Translations

    /// Two captions, the second of which was never translated — the ragged tail
    /// a partial translation pass leaves behind.
    private var bilingualSegments: [CaptionSegmentSnapshot] {
        [
            CaptionSegmentSnapshot(
                startMs: 960,
                endMs: 1600,
                text: "Good afternoon.",
                speakerId: alice.id,
                speakerLabel: "Alice",
                translations: ["zh-Hans": "下午好。"]
            ),
            CaptionSegmentSnapshot(
                startMs: 1600,
                endMs: 2400,
                text: "Let's begin.",
                speakerId: alice.id,
                speakerLabel: "Alice"
            ),
        ]
    }

    private func bilingualSnapshot() -> CaptionTranscriptSnapshot {
        CaptionTranscriptSnapshot(
            projectName: "Episode 12",
            audioDurationMs: 60_000,
            speakers: [alice, bob],
            segments: bilingualSegments,
            sourceLanguage: "en",
            versionNumber: 2,
            availableTranslations: ["zh-Hans"]
        )
    }

    @Test("Bilingual VTT puts the translation on its own line, decorated once")
    func bilingualVTT() async throws {
        let data = try await CaptionExporter.render(
            bilingualSnapshot(),
            options: .init(
                format: .vtt,
                speakerStyle: .vttVoiceTag,
                translationMode: .bilingual,
                translationLanguage: "zh-Hans"
            )
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == """
        WEBVTT

        1
        00:00:00.960 --> 00:00:01.600
        <v Alice>Good afternoon.
        下午好。

        2
        00:00:01.600 --> 00:00:02.400
        <v Alice>Let's begin.


        """)
    }

    @Test("Bilingual SRT uses CRLF between the two lines of a cue")
    func bilingualSRT() async throws {
        let data = try await CaptionExporter.render(
            bilingualSnapshot(),
            options: .init(
                format: .srt,
                speakerStyle: .none,
                translationMode: .bilingual,
                translationLanguage: "zh-Hans"
            )
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Good afternoon.\r\n下午好。\r\n\r\n"))
        #expect(text.contains("Let's begin.\r\n\r\n"))
    }

    @Test("Translation-only falls back to the original rather than an empty cue")
    func translationOnlyFallsBack() async throws {
        let data = try await CaptionExporter.render(
            bilingualSnapshot(),
            options: .init(
                format: .srt,
                speakerStyle: .none,
                translationMode: .translationOnly,
                translationLanguage: "zh-Hans"
            )
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("下午好。"))
        #expect(!text.contains("Good afternoon."))
        // The untranslated caption keeps its original — a blank cue would flash
        // visibly in a player.
        #expect(text.contains("Let's begin."))
    }

    @Test("Translation-only against an untranslated transcript throws")
    func translationOnlyWithoutTranslationThrows() async {
        await #expect(throws: CaptionExportError.self) {
            _ = try await CaptionExporter.render(
                snapshot(segments: [goodAfternoon]),
                options: .init(translationMode: .translationOnly, translationLanguage: "zh-Hans")
            )
        }
    }

    @Test("Bilingual plain text prefixes the original line only")
    func bilingualText() async throws {
        let data = try await CaptionExporter.render(
            bilingualSnapshot(),
            options: .init(
                format: .text,
                speakerStyle: .prefix,
                includeTimestampsInText: true,
                translationMode: .bilingual,
                translationLanguage: "zh-Hans"
            )
        )
        let text = String(decoding: data, as: UTF8.self)
        // The timestamp and the speaker name sit on the original only; the
        // speaker is dropped on cue 2 because it hasn't changed.
        #expect(text == """
        [00:00] Alice: Good afternoon.
        下午好。
        [00:01] Let's begin.

        """)
    }

    @Test("A translated export degrades to sentence cues and skips re-wrapping")
    func translationForcesSentenceCues() async throws {
        var options = CaptionExportOptions(
            format: .vtt,
            granularity: .wordKaraoke,
            speakerStyle: .none,
            maxRunesPerCue: 4,
            translationMode: .bilingual,
            translationLanguage: "zh-Hans"
        )
        #expect(options.effectiveGranularity == .sentence)

        let cues = CaptionExporter.cues(from: bilingualSnapshot(), options: options)
        #expect(cues.count == 2)

        // With no translation selected the same options do re-wrap.
        options.translationLanguage = ""
        options.granularity = .sentence
        #expect(CaptionExporter.cues(from: bilingualSnapshot(), options: options).count > 2)
    }

    @Test("JSON carries every translation plus the version and source language")
    func jsonIncludesTranslations() async throws {
        let data = try await CaptionExporter.render(
            bilingualSnapshot(),
            options: .init(format: .json)
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["sourceLanguage"] as? String == "en")
        #expect(object["version"] as? Int == 2)
        #expect(object["translationLanguages"] as? [String] == ["zh-Hans"])

        let segments = try #require(object["segments"] as? [[String: Any]])
        let first = try #require(segments.first?["translations"] as? [String: String])
        #expect(first["zh-Hans"] == "下午好。")
    }

    @Test("A language code lands in the filename")
    func translatedFilename() {
        #expect(CaptionExporter.defaultFilename(
            projectName: "My Talk",
            options: .init(format: .srt),
            languageCode: "zh-Hans"
        ) == "My-Talk_zh-Hans.srt")

        // Omitted when empty, so an ordinary export keeps the name it had.
        #expect(CaptionExporter.defaultFilename(
            projectName: "My Talk", options: .init(format: .srt), languageCode: ""
        ) == "My-Talk.srt")

        #expect(CaptionExporter.filenameLanguageCode(
            options: .init(translationLanguage: "es")
        ) == "es")
        #expect(CaptionExporter.filenameLanguageCode(options: .init()).isEmpty)
    }
}
