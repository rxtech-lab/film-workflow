import Foundation
import Testing

@testable import film_workflow

/// A stand-in engine, so the splitter can be tested without a model.
private struct StubCaptionAIEngine: CaptionAIEngine {
    var backend: AgentBackend = .openAICompatible
    var plan: (@Sendable (CaptionSplitRequest) throws -> CaptionSplitPlan)?
    var review: (@Sendable (CaptionTermReviewRequest) throws -> CaptionTermReviewResult)?

    func planSplit(_ request: CaptionSplitRequest) async throws -> CaptionSplitPlan {
        guard let plan else { return CaptionSplitPlan(pieces: [request.text]) }
        return try plan(request)
    }

    func reviewTerms(_ request: CaptionTermReviewRequest) async throws -> CaptionTermReviewResult {
        guard let review else { return CaptionTermReviewResult(corrections: []) }
        return try review(request)
    }

    func converse(_ request: CaptionChatRequest) async throws -> CaptionChatReply {
        CaptionChatReply(assistantText: "")
    }
}

private struct StubEngineError: Error {}

@Suite("AI caption splitting")
struct CaptionAISplitterTests {

    // MARK: - Helpers

    /// A cue whose words are one per space-separated token, 100 ms each.
    private func cue(_ text: String, startMs: Int = 0) -> CaptionCue {
        let pieces = text.split(separator: " ").map(String.init)
        var words: [CaptionWord] = []
        var offset = startMs
        for piece in pieces {
            words.append(CaptionWord(text: piece, offsetMs: offset, durationMs: 100))
            offset += 100
        }
        return CaptionCue(
            startMs: startMs,
            endMs: offset,
            text: text,
            words: words
        )
    }

    private var longCue: CaptionCue {
        cue("we shipped the release on friday and then everyone went home happy")
    }

    // MARK: - Cue surgery

    @Test("Splitting carries word timings into both halves")
    func splitPreservesWordTimings() throws {
        let source = longCue
        let parts = try #require(CaptionAISplitter.split(
            source,
            into: ["We shipped the release on Friday,", "and then everyone went home happy."]
        ))

        #expect(parts.count == 2)
        #expect(parts[0].words.count + parts[1].words.count == source.words.count)
        #expect(parts[0].startMs == source.startMs)
        #expect(parts[1].endMs == source.endMs)
        // No gap and no overlap at the seam.
        #expect(parts[0].endMs <= parts[1].startMs)
    }

    @Test("Splitting keeps the model's punctuation")
    func splitKeepsPunctuation() throws {
        let parts = try #require(CaptionAISplitter.split(
            longCue,
            into: ["We shipped the release on Friday,", "and then everyone went home happy."]
        ))
        #expect(parts[0].text == "We shipped the release on Friday,")
    }

    @Test("Pieces that don't match the words refuse to split")
    func splitRejectsMismatch() {
        #expect(CaptionAISplitter.split(longCue, into: ["Something", "else"]) == nil)
    }

    @Test("A cue with no word timings splits by content weight")
    func splitByWeightWhenNoWords() throws {
        let source = CaptionCue(
            startMs: 0,
            endMs: 4_000,
            text: "one two three four",
            isEstimatedTiming: true
        )
        let parts = try #require(CaptionAISplitter.split(source, into: ["one two", "three four"]))

        #expect(parts.count == 2)
        #expect(parts[0].startMs == 0)
        #expect(parts[1].endMs == 4_000)
        #expect(parts.allSatisfy { $0.isEstimatedTiming })
    }

    // MARK: - Refinement

    @Test("Only over-long cues are sent to the model")
    func shortCuesAreLeftAlone() async {
        let short = cue("short enough")
        let engine = StubCaptionAIEngine { _ in
            Issue.record("the model should not have been called")
            return CaptionSplitPlan(pieces: [])
        }

        let out = await CaptionAISplitter.refine(
            cues: [short],
            maxRunes: 80,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(out.count == 1)
        #expect(out[0].text == short.text)
    }

    @Test("A model that declines to split is obeyed")
    func decliningToSplitIsHonoured() async {
        let source = longCue
        let engine = StubCaptionAIEngine { request in
            CaptionSplitPlan(pieces: [request.text], reason: "no good break point")
        }

        let out = await CaptionAISplitter.refine(
            cues: [source],
            maxRunes: 20,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(out.count == 1)
        #expect(out[0].text == source.text)
    }

    @Test("A model that shreds a line into words falls back to the character split")
    func shreddingFallsBack() async {
        let source = longCue
        // The regression from the field: the model returned one word per piece
        // and every caption became a single word.
        let engine = StubCaptionAIEngine { request in
            CaptionSplitPlan(pieces: request.text.split(separator: " ").map(String.init))
        }

        let out = await CaptionAISplitter.refine(
            cues: [source],
            maxRunes: 40,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(out.count == CaptionAISplitter.characterSplit(source, maxRunes: 40).count)
        // Nowhere near one caption per word.
        #expect(out.count < source.words.count / 2)
        #expect(out.flatMap(\.words).count == source.words.count)
    }

    @Test("A rejected answer is retried with the reason, and the retry is used")
    func retryRecoversFromShredding() async {
        let attempts = Counter()
        let engine = StubCaptionAIEngine { request in
            attempts.record(total: 0)
            // First answer is the shredding users reported; the second is what
            // the model produces once it is told so.
            guard !request.retryNote.isEmpty else {
                return CaptionSplitPlan(pieces: request.text.split(separator: " ").map(String.init))
            }
            return CaptionSplitPlan(pieces: [
                "we shipped the release on friday",
                "and then everyone went home happy",
            ])
        }

        let out = await CaptionAISplitter.refine(
            cues: [longCue],
            maxRunes: 40,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(attempts.calls == 2)
        #expect(out.count == 2)
        #expect(out[0].text == "we shipped the release on friday")
    }

    // MARK: - Reply format

    @Test("A marked-up reply becomes pieces")
    func parseSplitsOnMarkers() {
        let plan = CaptionSplitPlan.parse(markedLine: "We shipped it, | and went home.")
        #expect(plan.pieces == ["We shipped it,", "and went home."])
    }

    @Test("A reply with no marker means leave the line alone")
    func parseWithoutMarkerKeepsOnePiece() {
        #expect(CaptionSplitPlan.parse(markedLine: "We shipped it and went home.").pieces.count == 1)
    }

    @Test("A model that lays the parts out on separate lines is understood")
    func parseTreatsNewlinesAsMarkers() {
        let plan = CaptionSplitPlan.parse(markedLine: "We shipped it,\nand went home.")
        #expect(plan.pieces == ["We shipped it,", "and went home."])
    }

    @Test("The piece budget reaches the model, not just the validator")
    func requestCarriesPieceBudget() async {
        let budget = Budget()
        let engine = StubCaptionAIEngine { request in
            budget.record(request.maxPieces)
            return CaptionSplitPlan(pieces: [request.text])
        }

        _ = await CaptionAISplitter.refine(
            cues: [longCue],
            maxRunes: 40,
            terms: [],
            languageHint: "",
            engine: engine
        )
        // Telling the model the number up front is what stops the shredding
        // before validation has to.
        #expect(budget.value >= 2)
        #expect(budget.value <= 4)
    }

    @Test("A plan that changes words falls back to the character split")
    func invalidPlanFallsBack() async {
        let source = longCue
        let engine = StubCaptionAIEngine { _ in
            CaptionSplitPlan(pieces: ["Totally different", "words entirely"])
        }

        let out = await CaptionAISplitter.refine(
            cues: [source],
            maxRunes: 20,
            terms: [],
            languageHint: "",
            engine: engine
        )
        let expected = CaptionAISplitter.characterSplit(source, maxRunes: 20)

        #expect(out.map(\.text) == expected.map(\.text))
        // And no word was lost on the way.
        #expect(out.flatMap(\.words).count == source.words.count)
    }

    @Test("An engine that throws falls back to the character split")
    func engineFailureFallsBack() async {
        let source = longCue
        let engine = StubCaptionAIEngine { _ in throw StubEngineError() }

        let out = await CaptionAISplitter.refine(
            cues: [source],
            maxRunes: 20,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(out.map(\.text) == CaptionAISplitter.characterSplit(source, maxRunes: 20).map(\.text))
    }

    @Test("A cue too big for the engine's window is never sent")
    func oversizedCueSkipsTheModel() async {
        let source = cue(Array(repeating: "word", count: 20_000).joined(separator: " "))
        let engine = StubCaptionAIEngine { _ in
            Issue.record("a cue past the context budget should not be sent")
            return CaptionSplitPlan(pieces: [])
        }

        let out = await CaptionAISplitter.refine(
            cues: [source],
            maxRunes: 80,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(out.count > 1)
    }

    @Test("A valid plan is applied")
    func validPlanIsApplied() async {
        let engine = StubCaptionAIEngine { _ in
            CaptionSplitPlan(pieces: [
                "We shipped the release on Friday,",
                "and then everyone went home happy.",
            ])
        }

        let out = await CaptionAISplitter.refine(
            cues: [longCue],
            maxRunes: 20,
            terms: [],
            languageHint: "",
            engine: engine
        )
        #expect(out.count == 2)
        #expect(out[0].text == "We shipped the release on Friday,")
        #expect(out[1].text == "and then everyone went home happy.")
    }

    @Test("Progress is reported once per over-long cue")
    func progressCountsOverlongCues() async {
        let cues = [longCue, cue("short"), longCue]
        let counter = Counter()
        let engine = StubCaptionAIEngine { request in
            CaptionSplitPlan(pieces: [request.text])
        }

        _ = await CaptionAISplitter.refine(
            cues: cues,
            maxRunes: 20,
            terms: [],
            languageHint: "",
            engine: engine,
            onProgress: { _, total in counter.record(total: total) }
        )
        #expect(counter.calls == 2)
        #expect(counter.lastTotal == 2)
    }

    // MARK: - Cue building ceiling

    @Test("AI mode raises the cue-building ceiling well above the user's limit")
    func aiModeUsesAGenerousCeiling() {
        #expect(CaptionAISplitter.rawCueCeiling(maxRunes: 80) > 80)
        // Still bounded, so a long unpunctuated run can't produce a cue the
        // model can't read.
        #expect(CaptionAISplitter.rawCueCeiling(maxRunes: 80) < 1_000)
    }
}

/// Captures a value produced inside a `@Sendable` stub closure.
private final class Budget: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int { lock.withLock { _value } }
    func record(_ newValue: Int) { lock.withLock { _value = newValue } }
}

/// Thread-safe tally for the progress callback, which arrives off the test's
/// own isolation.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _lastTotal = 0

    var calls: Int { lock.withLock { _calls } }
    var lastTotal: Int { lock.withLock { _lastTotal } }

    func record(total: Int) {
        lock.withLock {
            _calls += 1
            _lastTotal = total
        }
    }
}

// MARK: - Stub sugar

extension StubCaptionAIEngine {
    init(plan: @escaping @Sendable (CaptionSplitRequest) throws -> CaptionSplitPlan) {
        self.init(backend: .openAICompatible, plan: plan, review: nil)
    }
}
