import Foundation
import Testing

@testable import film_workflow

/// Tests for narrative caption alignment.
///
/// The load-bearing guarantee, asserted repeatedly below: **the emitted caption
/// text is character-identical to the author's script**, no matter how badly the
/// speech service mis-heard the audio. Timings may degrade; wording must not.
@Suite("Narrative caption alignment")
struct CaptionAlignerTests {

    private let alice = UUID()
    private let bob = UUID()

    // MARK: - Helpers

    private func units(_ texts: [(String, UUID)]) -> [CaptionReferenceUnit] {
        texts.enumerated().map { index, pair in
            CaptionReferenceUnit(
                paragraphId: UUID(),
                speakerId: pair.1,
                order: index,
                plainText: pair.0
            )
        }
    }

    /// Builds a synthetic ASR hypothesis: evenly spaced word timings over
    /// `durationMs`, from whatever text the "recognizer" produced.
    private func hypothesis(
        _ text: String,
        durationMs: Int
    ) -> (tokens: [CaptionToken], timings: [CaptionWordTiming]) {
        let pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let spans = CaptionText.distribute(
            weights: pieces.map { max(CaptionText.wordRuneCount($0), 1) },
            fromMs: 0,
            toMs: durationMs
        )
        let timings = zip(pieces, spans).map { piece, span in
            CaptionWordTiming(
                text: piece,
                offsetMs: span.startMs,
                durationMs: max(span.endMs - span.startMs, 1),
                confidence: 0.9
            )
        }
        return (CaptionTokenizer.tokenizeHypothesis(timings), timings)
    }

    private func align(
        reference referenceUnits: [CaptionReferenceUnit],
        heard: String,
        durationMs: Int = 10_000,
        minConfidence: Double = 0.75
    ) async -> CaptionAlignmentResult {
        let referenceTokens = CaptionTokenizer.tokenizeReference(referenceUnits)
        let hyp = hypothesis(heard, durationMs: durationMs)
        return await CaptionAligner.align(
            reference: referenceTokens,
            hypothesis: hyp.tokens,
            hypothesisTimings: hyp.timings,
            audioDurationMs: durationMs,
            minConfidence: minConfidence
        )
    }

    /// Concatenated reference wording, which every cue set must reproduce.
    private func expectedWording(_ referenceUnits: [CaptionReferenceUnit]) -> String {
        CaptionTokenizer.tokenizeReference(referenceUnits)
            .map(\.display)
            .reduce(into: "") { CaptionText.appendWord($1, to: &$0) }
    }

    private func cueWording(_ cues: [CaptionCue]) -> String {
        cues.map(\.text).reduce(into: "") { CaptionText.appendWord($1, to: &$0) }
    }

    // MARK: - Perfect transcription

    @Test("A perfect transcription yields word-aligned timings and exact wording")
    func perfectMatch() async {
        let reference = units([("Good afternoon, everyone.", alice)])
        let result = await align(reference: reference, heard: "Good afternoon, everyone.")

        #expect(result.quality == .wordAligned)
        #expect(result.matchRatio == 1.0)

        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 10_000)
        #expect(cueWording(cues) == expectedWording(reference))
        #expect(cues.count == 1)
        #expect(cues[0].speakerId == alice)
    }

    // MARK: - The central guarantee

    @Test("The ASR hypothesis never replaces the author's wording")
    func hypothesisTextIsDiscarded() async {
        // The script says "colour"; the recognizer heard "color", plus a wrong
        // word and an inserted one.
        let reference = units([("The colour of the sky is remarkable today.", alice)])
        let result = await align(
            reference: reference,
            heard: "The color of the sky is umm remarkable to day."
        )

        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 10_000)
        let text = cueWording(cues)

        // Character-identical to the script.
        #expect(text == expectedWording(reference))
        // And specifically none of the recognizer's variants leaked in.
        #expect(text.contains("colour"))
        #expect(!text.contains("color "))
        #expect(!text.contains("umm"))
    }

    @Test("Wording survives even a total mismatch, falling back to estimated timings")
    func wordingSurvivesTotalMismatch() async {
        let reference = units([("Precise scripted narration goes here.", alice)])
        let result = await align(
            reference: reference,
            heard: "completely unrelated audio content nothing alike"
        )

        #expect(result.quality == .estimated)

        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 10_000)
        #expect(cueWording(cues) == expectedWording(reference))
    }

    @Test("Wording survives when the provider returns no word timings at all")
    func wordingSurvivesWithoutWordTimings() async {
        // The Gemini case.
        let reference = units([("One. Two. Three.", alice)])
        let referenceTokens = CaptionTokenizer.tokenizeReference(reference)

        let result = await CaptionAligner.align(
            reference: referenceTokens,
            hypothesis: [],
            hypothesisTimings: [],
            audioDurationMs: 9000,
            minConfidence: 0.75
        )

        #expect(result.quality == .estimated)
        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 9000)
        #expect(cueWording(cues) == expectedWording(reference))
        // Still cut into sentences, and still spanning the whole audio.
        #expect(cues.count == 3)
        #expect(cues.last?.endMs == 9000)
    }

    // MARK: - Timing invariants

    @Test("Timings are non-decreasing and bounded by the audio duration")
    func timingInvariants() async {
        let reference = units([
            ("First sentence here.", alice),
            ("Second sentence follows.", bob),
            ("And a third one.", alice),
        ])
        let result = await align(
            reference: reference,
            heard: "First sentence here Second sentence follows And a third one",
            durationMs: 12_000
        )
        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 12_000)

        #expect(!cues.isEmpty)
        for index in 0..<(cues.count - 1) {
            #expect(cues[index].startMs <= cues[index + 1].startMs)
            // clampCueOverlaps guarantees no cue runs into the next.
            #expect(cues[index].endMs <= cues[index + 1].startMs)
        }
        for cue in cues {
            #expect(cue.startMs >= 0)
            #expect(cue.endMs > cue.startMs)
            #expect(cue.endMs <= 12_000)
        }
    }

    @Test("Word timings stay inside their cue and in order")
    func wordTimingsWithinCues() async {
        let reference = units([("Alpha bravo charlie delta.", alice)])
        let result = await align(reference: reference, heard: "Alpha bravo charlie delta.")
        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 10_000)

        for cue in cues {
            var previousEnd = cue.startMs
            for word in cue.words {
                #expect(word.offsetMs >= cue.startMs)
                #expect(word.endMs <= cue.endMs)
                #expect(word.offsetMs >= previousEnd - 1)
                previousEnd = word.endMs
            }
        }
    }

    // MARK: - Degradation tiers

    @Test("Match ratio degrades through the tiers as recognition worsens")
    func degradationLadder() async {
        let reference = units([
            (
                "The quick brown fox jumps over the lazy dog while nine birds watch from a tall tree.",
                alice
            )
        ])

        // Clean: every word matches.
        let clean = await align(
            reference: reference,
            heard: "The quick brown fox jumps over the lazy dog while nine birds watch from a tall tree."
        )
        #expect(clean.quality == .wordAligned)

        // Roughly half the words replaced → anchors exist but aren't dense enough.
        let noisy = await align(
            reference: reference,
            heard: "The quick zzz xxx jumps over the yyy dog while qqq birds vvv from a www tree."
        )
        #expect(noisy.matchRatio < clean.matchRatio)
        #expect(noisy.quality == .sentenceAnchored || noisy.quality == .wordAligned)

        // Nothing in common → estimated.
        let garbage = await align(
            reference: reference,
            heard: "aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq"
        )
        #expect(garbage.quality == .estimated)

        // Wording is preserved at every tier.
        for result in [clean, noisy, garbage] {
            let cues = CaptionAligner.cues(from: result, maxRunes: 200, audioDurationMs: 10_000)
            #expect(cueWording(cues) == expectedWording(reference))
        }
    }

    @Test("Near-misses still anchor")
    func nearMatchesAnchor() async {
        // Realistic ASR slips: a missing letter, a plural, a contraction.
        let reference = units([("The recognizer doesn't handle everything perfectly.", alice)])
        let result = await align(
            reference: reference,
            heard: "The recognizers does not handle everthing perfectly."
        )
        // Loose matching should still find most anchors here.
        #expect(result.matchRatio > 0.5)
    }

    @Test("Levenshtein-at-most-one accepts single edits and rejects more")
    func levenshtein() {
        #expect(CaptionAligner.levenshteinAtMostOne("colour", "color"))
        #expect(CaptionAligner.levenshteinAtMostOne("cat", "cot"))
        #expect(CaptionAligner.levenshteinAtMostOne("word", "words"))
        #expect(!CaptionAligner.levenshteinAtMostOne("colour", "colr"))
        #expect(!CaptionAligner.levenshteinAtMostOne("abc", "xyz"))
    }

    // MARK: - Speakers

    @Test("Speakers come from the script, and a cue never spans two of them")
    func speakerBoundaries() async {
        let reference = units([
            ("Hello there", alice),
            ("Hi back", bob),
        ])
        // No sentence punctuation anywhere, so only the speaker change can split.
        let result = await align(reference: reference, heard: "Hello there Hi back")
        let cues = CaptionAligner.cues(from: result, maxRunes: 200, audioDurationMs: 10_000)

        #expect(cues.count == 2)
        #expect(cues[0].speakerId == alice)
        #expect(cues[1].speakerId == bob)
        #expect(cues[0].text == "Hello there")
        #expect(cues[1].text == "Hi back")
        // Diarization is unused: the provider speaker number stays 0 throughout.
        #expect(cues.allSatisfy { $0.speaker == 0 })
    }

    // MARK: - CJK

    @Test("CJK aligns per glyph and keeps its wording")
    func cjkAlignment() async {
        let reference = units([("欢迎大家。今天天气很好。", alice)])
        let result = await align(reference: reference, heard: "欢迎大家 今天天气很好", durationMs: 8000)

        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 8000)
        #expect(cueWording(cues) == expectedWording(reference))
        // Two sentences, split on the ideographic full stop.
        #expect(cues.count == 2)
        // No spaces inserted between glyphs.
        #expect(cues[0].text == "欢迎大家。")
        #expect(!cues[0].text.contains(" "))
    }

    // MARK: - Cue splitting

    @Test("Long unpunctuated runs split at maxRunes")
    func longRunSplits() async {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let reference = units([(long, alice)])
        let result = await align(reference: reference, heard: long, durationMs: 20_000)

        let cues = CaptionAligner.cues(from: result, maxRunes: 40, audioDurationMs: 20_000)
        #expect(cues.count > 1)
        #expect(cueWording(cues) == expectedWording(reference))
    }

    // MARK: - Empty inputs

    @Test("An empty script produces nothing rather than crashing")
    func emptyReference() async {
        let result = await CaptionAligner.align(
            reference: [],
            hypothesis: [],
            hypothesisTimings: [],
            audioDurationMs: 1000,
            minConfidence: 0.75
        )
        #expect(result.timedTokens.isEmpty)
        #expect(result.quality == .none)
        #expect(CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 1000).isEmpty)
    }

    // MARK: - Shortcode integration

    @Test("Reference text is the spoken words, with markup already stripped")
    func referenceExcludesMarkup() async {
        // What a narrative paragraph actually looks like.
        let raw = "{{pause}}Welcome back, {{whispers|quietly}} everyone."
        let stripped = ShortcodeExpander.plainSpeechText(raw)
        let reference = units([(stripped, alice)])

        let result = await align(reference: reference, heard: stripped)
        let cues = CaptionAligner.cues(from: result, maxRunes: 80, audioDurationMs: 10_000)
        let text = cueWording(cues)

        #expect(!text.contains("{{"))
        #expect(!text.contains("pause"))
        #expect(text.contains("quietly"))
        #expect(text == expectedWording(reference))
    }

    // MARK: - Band width

    @Test("Band width scales with input size but never below the floor")
    func bandWidth() {
        #expect(CaptionAligner.bandWidth(referenceCount: 10, hypothesisCount: 10) == 64)
        #expect(CaptionAligner.bandWidth(referenceCount: 20_000, hypothesisCount: 20_000) == 1000)
    }

    @Test("A 15k-token alignment completes quickly", .timeLimit(.minutes(1)))
    func largeAlignmentPerformance() async {
        // Roughly a one-hour CJK transcript, the worst realistic case.
        let text = Array(repeating: "这是一个测试句子。", count: 1500).joined()
        let reference = units([(text, alice)])
        let referenceTokens = CaptionTokenizer.tokenizeReference(reference)
        #expect(referenceTokens.count > 10_000)

        let hyp = hypothesis(text, durationMs: 3_600_000)
        let result = await CaptionAligner.align(
            reference: referenceTokens,
            hypothesis: hyp.tokens,
            hypothesisTimings: hyp.timings,
            audioDurationMs: 3_600_000,
            minConfidence: 0.75
        )
        #expect(!result.timedTokens.isEmpty)
        #expect(result.timedTokens.count == referenceTokens.count)
    }
}
