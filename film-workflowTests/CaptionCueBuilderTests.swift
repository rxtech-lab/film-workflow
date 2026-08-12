import Foundation
import Testing

@testable import film_workflow

/// Ported from `debate-bot/internal/stt/cues_test.go` plus the CJK response
/// fixture in `internal/stt/azure_test.go`. These lock in the two subtleties
/// that are easy to get wrong when porting: commas must not split a cue, and
/// the last piece of a proportional split must land on the phrase's exact end.
@Suite("Caption cue building")
struct CaptionCueBuilderTests {

    // MARK: - Helpers

    private func words(_ items: [(String, Int, Int)]) -> [CaptionWordTiming] {
        items.map { CaptionWordTiming(text: $0.0, offsetMs: $0.1, durationMs: $0.2) }
    }

    /// The two-speaker, two-language phrase pair from the Azure fixture.
    private var azureFixture: CaptionTranscript {
        CaptionTranscript(
            durationMs: 182_439,
            phrases: [
                CaptionPhrase(
                    speaker: 1,
                    offsetMs: 960,
                    durationMs: 640,
                    text: "Good afternoon.",
                    locale: "en-US",
                    words: words([("Good", 960, 240), ("afternoon.", 1200, 400)])
                ),
                CaptionPhrase(
                    speaker: 2,
                    offsetMs: 10_080,
                    durationMs: 24_920,
                    text: "欢迎大家。",
                    locale: "zh-CN",
                    words: words([
                        ("欢", 10_080, 120), ("迎", 10_200, 120),
                        ("大", 10_320, 120), ("家。", 10_440, 120),
                    ])
                ),
            ]
        )
    }

    // MARK: - Word-timed cues

    @Test("Azure fixture yields one cue per sentence with exact text and spans")
    func azureFixtureCues() async {
        let cues = await CaptionCueBuilder.sentenceCues(from: azureFixture)

        #expect(cues.count == 2)

        #expect(cues[0].text == "Good afternoon.")
        #expect(cues[0].speaker == 1)
        #expect(cues[0].startMs == 960)
        #expect(cues[0].endMs == 1600)

        // CJK must reconstruct without inserted spaces, and the trailing full
        // stop stays attached to the final glyph.
        #expect(cues[1].text == "欢迎大家。")
        #expect(cues[1].speaker == 2)
        #expect(cues[1].startMs == 10_080)
        #expect(cues[1].endMs == 10_560)
    }

    @Test("Latin words rejoin with spaces, CJK glyphs without")
    func spacingIsScriptAware() async {
        let transcript = CaptionTranscript(
            durationMs: 5000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 2000,
                    text: "",
                    words: words([("Hello", 0, 500), ("there", 500, 500), ("world.", 1000, 500)])
                )
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello there world.")
    }

    @Test("Commas do not close a cue")
    func commasDoNotSplit() async {
        let transcript = CaptionTranscript(
            durationMs: 10_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 3000,
                    text: "",
                    words: words([
                        ("First,", 0, 500), ("second,", 500, 500),
                        ("and", 1000, 500), ("third.", 1500, 500),
                    ])
                )
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)
        #expect(cues.count == 1)
        #expect(cues[0].text == "First, second, and third.")
    }

    @Test("Sentence punctuation closes a cue")
    func sentencePunctuationSplits() async {
        let transcript = CaptionTranscript(
            durationMs: 10_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 2000,
                    text: "",
                    words: words([
                        ("One.", 0, 500), ("Two?", 500, 500),
                        ("Three!", 1000, 500), ("Four", 1500, 500),
                    ])
                )
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)
        #expect(cues.map(\.text) == ["One.", "Two?", "Three!", "Four"])
    }

    @Test("A boundary-free run is hard split at maxRunes")
    func maxRunesForcesSplit() async {
        // 20 words of 5 characters, no punctuation at all.
        let items = (0..<20).map { index in ("aaaaa", index * 100, 100) }
        let transcript = CaptionTranscript(
            durationMs: 2000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 2000, text: "", words: words(items)
                )
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript, maxRunes: 20)
        #expect(cues.count > 1)
        // Every cue except possibly the last must have reached the limit.
        for cue in cues.dropLast() {
            #expect(cue.text.count >= 20)
        }
    }

    // MARK: - Text-only cues (no word timings)

    @Test("Text-only phrases split proportionally and pin the last piece to the phrase end")
    func textOnlyPinsFinalEnd() async {
        let transcript = CaptionTranscript(
            durationMs: 10_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1,
                    offsetMs: 1000,
                    durationMs: 3001, // deliberately indivisible by 3
                    text: "One. Two. Three."
                )
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)

        #expect(cues.count == 3)
        #expect(cues.map(\.text) == ["One.", "Two.", "Three."])
        // No gap and no overrun: the final piece lands exactly on the phrase end.
        #expect(cues[0].startMs == 1000)
        #expect(cues.last?.endMs == 4001)
        // Spans are contiguous.
        for index in 0..<(cues.count - 1) {
            #expect(cues[index].endMs == cues[index + 1].startMs)
        }
        // Derived, not measured.
        #expect(cues.allSatisfy { $0.isEstimatedTiming })
    }

    @Test("distribute pins the final slice to the exact end")
    func distributePinsEnd() {
        let spans = CaptionText.distribute(weights: [1, 1, 1], fromMs: 0, toMs: 100)
        #expect(spans.count == 3)
        #expect(spans[0].startMs == 0)
        #expect(spans.last?.endMs == 100)
        for index in 0..<(spans.count - 1) {
            #expect(spans[index].endMs == spans[index + 1].startMs)
        }
    }

    @Test("distribute treats zero weights as one so no slice collapses")
    func distributeHandlesZeroWeights() {
        let spans = CaptionText.distribute(weights: [0, 0], fromMs: 0, toMs: 10)
        #expect(spans.count == 2)
        #expect(spans.last?.endMs == 10)
    }

    // MARK: - Post-passes

    @Test("Clause-cut phrases from the same speaker are rejoined")
    func mergesClauseContinuations() async {
        let transcript = CaptionTranscript(
            durationMs: 10_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 1000, text: "",
                    words: words([("Because,", 0, 1000)])
                ),
                CaptionPhrase(
                    speaker: 1, offsetMs: 1200, durationMs: 1000, text: "",
                    words: words([("naturally.", 1200, 1000)])
                ),
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Because, naturally.")
        #expect(cues[0].endMs == 2200)
    }

    @Test("A clause continuation is not merged across a speaker change")
    func doesNotMergeAcrossSpeakers() async {
        let transcript = CaptionTranscript(
            durationMs: 10_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 1000, text: "",
                    words: words([("Because,", 0, 1000)])
                ),
                CaptionPhrase(
                    speaker: 2, offsetMs: 1200, durationMs: 1000, text: "",
                    words: words([("naturally.", 1200, 1000)])
                ),
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)
        #expect(cues.count == 2)
    }

    @Test("A clause continuation is not merged across a long gap")
    func doesNotMergeAcrossLongGap() async {
        let transcript = CaptionTranscript(
            durationMs: 20_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 1000, text: "",
                    words: words([("Because,", 0, 1000)])
                ),
                CaptionPhrase(
                    speaker: 1, offsetMs: 9000, durationMs: 1000, text: "",
                    words: words([("naturally.", 9000, 1000)])
                ),
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(from: transcript)
        #expect(cues.count == 2)
    }

    @Test("mergeContinuations: false leaves author sentence structure intact")
    func mergeCanBeDisabledForNarrative() async {
        let transcript = CaptionTranscript(
            durationMs: 10_000,
            phrases: [
                CaptionPhrase(
                    speaker: 1, offsetMs: 0, durationMs: 1000, text: "",
                    words: words([("Because,", 0, 1000)])
                ),
                CaptionPhrase(
                    speaker: 1, offsetMs: 1200, durationMs: 1000, text: "",
                    words: words([("naturally.", 1200, 1000)])
                ),
            ]
        )
        let cues = await CaptionCueBuilder.sentenceCues(
            from: transcript, mergeContinuations: false
        )
        #expect(cues.count == 2)
    }

    @Test("An overrunning cue is trimmed to the next cue's start")
    func clampsOverlap() {
        let cues = [
            CaptionCue(startMs: 0, endMs: 5000, text: "First."),
            CaptionCue(startMs: 3000, endMs: 6000, text: "Second."),
        ]
        let clamped = CaptionCueBuilder.clampCueOverlaps(cues)
        #expect(clamped.count == 2)
        #expect(clamped[0].endMs == 3000)
    }

    @Test("A cue that collapses under clamping folds its text forward")
    func collapsedCueMergesForward() {
        let cues = [
            CaptionCue(startMs: 1000, endMs: 5000, text: "Lost?"),
            CaptionCue(startMs: 1000, endMs: 6000, text: "Kept."),
        ]
        let clamped = CaptionCueBuilder.clampCueOverlaps(cues)
        #expect(clamped.count == 1)
        // No words are dropped, and the surviving cue owns the wider span.
        #expect(clamped[0].text == "Lost? Kept.")
        #expect(clamped[0].startMs == 1000)
    }

    // MARK: - Character classification

    @Test("Cue boundaries cover Latin and CJK sentence punctuation but never commas")
    func boundaryClassification() {
        for c in [".", "!", "?", ";", "。", "！", "？", "；", "…"] {
            #expect(CaptionText.isCueBoundary(Character(c)))
        }
        for c in [",", "，", "、", ":", "：", "a", "字"] {
            #expect(!CaptionText.isCueBoundary(Character(c)))
        }
    }

    @Test("Rune weight counts grapheme clusters, not UTF-8 bytes")
    func runeWeightUsesGraphemeClusters() {
        // 5 CJK glyphs = 15 UTF-8 bytes. Counting bytes would triple the weight
        // and wreck CJK cue lengths.
        #expect(CaptionText.wordRuneCount("欢迎大家们") == 5)
        // A flag emoji is one grapheme cluster but not a content character.
        #expect(CaptionText.wordRuneCount("hi🇯🇵") == 2)
    }

    @Test("CJK detection covers Han, kana, hangul and fullwidth forms")
    func cjkDetection() {
        for c in ["欢", "。", "ア", "あ", "한", "Ａ"] {
            #expect(CaptionText.isCJK(Character(c)))
        }
        for c in ["a", "1", ".", " "] {
            #expect(!CaptionText.isCJK(Character(c)))
        }
    }
}
