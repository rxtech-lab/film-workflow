import Foundation
import Testing

@testable import film_workflow

/// Covers the pieces narrative alignment depends on: reducing authored
/// paragraphs to spoken words, and tokenizing both sides comparably.
@Suite("Caption text and tokenization")
struct CaptionTextTests {

    // MARK: - Shortcode stripping

    @Test("Bare shortcodes vanish and wrapping shortcodes keep their payload")
    func plainSpeechText() {
        #expect(ShortcodeExpander.plainSpeechText("{{pause}}Hello {{whispers|there}}") == "Hello there")
        #expect(ShortcodeExpander.plainSpeechText("No markup here.") == "No markup here.")
        #expect(ShortcodeExpander.plainSpeechText("A{{break:250ms}}B") == "AB")
        #expect(ShortcodeExpander.plainSpeechText("{{emphasis:strong|Listen}} up.") == "Listen up.")
    }

    @Test("Dropped shortcodes do not leave double spaces behind")
    func plainSpeechCollapsesWhitespace() {
        #expect(ShortcodeExpander.plainSpeechText("one {{pause}} two") == "one  two"
            .replacingOccurrences(of: "  ", with: " "))
        #expect(ShortcodeExpander.plainSpeechText("  padded  ") == "padded")
    }

    @Test("Authored pauses are reported with their text offset")
    func plainSpeechWithPauses() {
        let result = ShortcodeExpander.plainSpeechWithPauses("Hi{{pause}}there{{break:250ms}}!")
        #expect(result.text == "Hithere!")
        #expect(result.pauses.count == 2)
        #expect(result.pauses[0].runeIndex == 2)
        #expect(result.pauses[0].ms == 500)
        #expect(result.pauses[1].ms == 250)
    }

    @Test("Break durations parse from ms, seconds and named strengths")
    func durationParsing() {
        #expect(ShortcodeExpander.parseDurationMs("250ms") == 250)
        #expect(ShortcodeExpander.parseDurationMs("1.5s") == 1500)
        #expect(ShortcodeExpander.parseDurationMs("weak") == 250)
        #expect(ShortcodeExpander.parseDurationMs("x-strong") == 1000)
        #expect(ShortcodeExpander.parseDurationMs("nonsense") == nil)
    }

    // MARK: - Tokenization

    @Test("Latin text tokenizes on whitespace")
    func latinTokenization() {
        let tokens = CaptionTokenizer.tokenize("Good afternoon, everyone.")
        #expect(tokens.map(\.display) == ["Good", "afternoon,", "everyone."])
        #expect(tokens.last?.isSentenceEnd == true)
        #expect(tokens[1].isSentenceEnd == false) // a comma is not a boundary
    }

    @Test("Each CJK glyph is its own token with punctuation attached")
    func cjkTokenization() {
        // Must match Azure's per-glyph word output so the two sides align.
        let tokens = CaptionTokenizer.tokenize("欢迎大家。")
        #expect(tokens.map(\.display) == ["欢", "迎", "大", "家。"])
        #expect(tokens.last?.isSentenceEnd == true)
    }

    @Test("Mixed scripts split at the script boundary")
    func mixedScriptTokenization() {
        let tokens = CaptionTokenizer.tokenize("Hello欢迎world")
        #expect(tokens.map(\.display) == ["Hello", "欢", "迎", "world"])
    }

    @Test("Normalization folds case, diacritics, width and internal punctuation")
    func normalization() {
        #expect(CaptionTokenizer.normalize("Café") == CaptionTokenizer.normalize("cafe"))
        #expect(CaptionTokenizer.normalize("don't") == "dont")
        #expect(CaptionTokenizer.normalize("well-known") == "wellknown")
        #expect(CaptionTokenizer.normalize("Hello,") == "hello")
        #expect(CaptionTokenizer.normalize("ＡＢＣ") == "abc")
        // Digits survive as digits.
        #expect(CaptionTokenizer.normalize("2026.") == "2026")
    }

    @Test("Punctuation-only tokens are kept but never anchor")
    func punctuationOnlyTokensAreNotAnchorable() {
        let tokens = CaptionTokenizer.tokenize("hello — world")
        let dash = tokens.first { $0.display == "—" }
        #expect(dash != nil)
        #expect(dash?.isAnchorable == false)
        #expect(tokens.first { $0.display == "hello" }?.isAnchorable == true)
    }

    @Test("Reference tokenization carries unit index and speaker through")
    func referenceTokenization() {
        let alice = UUID()
        let bob = UUID()
        let units = [
            CaptionReferenceUnit(paragraphId: UUID(), speakerId: alice, order: 0, plainText: "Hello there."),
            CaptionReferenceUnit(paragraphId: UUID(), speakerId: bob, order: 1, plainText: "Hi back."),
        ]
        let tokens = CaptionTokenizer.tokenizeReference(units)

        #expect(tokens.map(\.display) == ["Hello", "there.", "Hi", "back."])
        #expect(tokens[0].speakerId == alice)
        #expect(tokens[0].unitIndex == 0)
        #expect(tokens[3].speakerId == bob)
        #expect(tokens[3].unitIndex == 1)
    }

    @Test("Reference units are ordered by their order field, not array position")
    func referenceTokenizationRespectsOrder() {
        let units = [
            CaptionReferenceUnit(paragraphId: UUID(), speakerId: UUID(), order: 1, plainText: "second"),
            CaptionReferenceUnit(paragraphId: UUID(), speakerId: UUID(), order: 0, plainText: "first"),
        ]
        #expect(CaptionTokenizer.tokenizeReference(units).map(\.display) == ["first", "second"])
    }

    @Test("Hypothesis tokens point back at their originating timing")
    func hypothesisTokenization() {
        let timings = [
            CaptionWordTiming(text: "Good", offsetMs: 0, durationMs: 100),
            CaptionWordTiming(text: "欢迎", offsetMs: 100, durationMs: 200),
        ]
        let tokens = CaptionTokenizer.tokenizeHypothesis(timings)

        // A provider "word" holding two glyphs re-splits, and both halves still
        // resolve to timing index 1.
        #expect(tokens.map(\.display) == ["Good", "欢", "迎"])
        #expect(tokens[0].timingIndex == 0)
        #expect(tokens[1].timingIndex == 1)
        #expect(tokens[2].timingIndex == 1)
    }
}

@Suite("Caption timing validation")
struct CaptionValidatorTests {

    private func transcript(_ phrases: [CaptionPhrase], durationMs: Int = 10_000) -> CaptionTranscript {
        CaptionTranscript(durationMs: durationMs, phrases: phrases)
    }

    @Test("A well-formed transcript validates")
    func validTranscript() throws {
        try CaptionTranscriptValidator.validateTiming(transcript([
            CaptionPhrase(offsetMs: 0, durationMs: 1000, text: "One."),
            CaptionPhrase(offsetMs: 1000, durationMs: 1000, text: "Two."),
        ]))
    }

    @Test("Backwards offsets are rejected — the Gemini failure mode")
    func rejectsNonMonotonicOffsets() {
        #expect(throws: CaptionTimingError.self) {
            try CaptionTranscriptValidator.validateTiming(transcript([
                CaptionPhrase(offsetMs: 5000, durationMs: 1000, text: "Later."),
                CaptionPhrase(offsetMs: 1000, durationMs: 1000, text: "Earlier."),
            ]))
        }
    }

    @Test("Non-positive durations are rejected")
    func rejectsNonPositiveDuration() {
        #expect(throws: CaptionTimingError.self) {
            try CaptionTranscriptValidator.validateTiming(transcript([
                CaptionPhrase(offsetMs: 0, durationMs: 0, text: "Empty.")
            ]))
        }
    }

    @Test("A phrase running past the audio end is rejected")
    func rejectsOverrun() {
        #expect(throws: CaptionTimingError.self) {
            try CaptionTranscriptValidator.validateTiming(transcript([
                CaptionPhrase(offsetMs: 9000, durationMs: 5000, text: "Too long.")
            ], durationMs: 10_000))
        }
    }

    @Test("An unknown audio duration is rejected")
    func rejectsUnknownDuration() {
        #expect(throws: CaptionTimingError.self) {
            try CaptionTranscriptValidator.validateTiming(transcript([
                CaptionPhrase(offsetMs: 0, durationMs: 100, text: "Hi.")
            ], durationMs: 0))
        }
    }

    @Test("Editor issues are advisory findings, not exceptions")
    func editorIssues() {
        let speaker = CaptionSpeaker(label: "Alice")
        let snapshot = CaptionTranscriptSnapshot(
            projectName: "P",
            audioDurationMs: 5000,
            speakers: [speaker],
            segments: [
                // Inverted range and empty text: the user must still be able to save.
                CaptionSegmentSnapshot(startMs: 2000, endMs: 1000, text: "   "),
                // Overlaps nothing, but runs past the end of the audio.
                CaptionSegmentSnapshot(
                    startMs: 4000, endMs: 6000, text: "Past the end.",
                    speakerId: speaker.id, speakerLabel: "Alice"
                ),
            ]
        )
        let issues = CaptionTranscriptValidator.issues(in: snapshot)
        let kinds = Set(issues.map(\.kind))

        #expect(kinds.contains(.emptyText))
        #expect(kinds.contains(.nonPositiveDuration))
        #expect(kinds.contains(.missingSpeaker))
        #expect(kinds.contains(.exceedsAudioDuration))
        // Only genuine timing breakage blocks.
        #expect(issues.contains { $0.isBlocking })
    }

    @Test("A word outside its segment is reported against that word")
    func wordOutsideSegment() {
        let snapshot = CaptionTranscriptSnapshot(
            projectName: "P",
            audioDurationMs: 5000,
            speakers: [],
            segments: [
                CaptionSegmentSnapshot(
                    startMs: 1000, endMs: 2000, text: "Hi",
                    words: [CaptionWord(text: "Hi", offsetMs: 3000, durationMs: 100)]
                )
            ]
        )
        let issues = CaptionTranscriptValidator.issues(in: snapshot)
        #expect(issues.contains { $0.kind == .wordOutsideSegment && $0.wordIndex == 0 })
    }

    @Test("Editor row issues are grouped once by stable segment id")
    func rowIssuesAreGroupedBySegmentID() {
        let emptyID = UUID()
        let wordOnlyID = UUID()
        let snapshot = CaptionTranscriptSnapshot(
            projectName: "P",
            audioDurationMs: 5000,
            speakers: [],
            segments: [
                CaptionSegmentSnapshot(id: emptyID, startMs: 0, endMs: 1000, text: ""),
                CaptionSegmentSnapshot(
                    id: wordOnlyID,
                    startMs: 1000,
                    endMs: 2000,
                    text: "Hi",
                    words: [CaptionWord(text: "Hi", offsetMs: 3000, durationMs: 100)]
                ),
            ]
        )

        let grouped = CaptionTranscriptValidator.rowIssuesBySegmentID(in: snapshot)

        #expect(grouped[emptyID]?.map(\.kind) == [.emptyText])
        #expect(grouped[wordOnlyID] == nil)
    }
}
