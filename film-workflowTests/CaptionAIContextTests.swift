import Foundation
import Testing

@testable import film_workflow

/// Context assembly is what makes the on-device model usable at all — its window
/// is roughly 4k tokens shared between prompt and response, so these lock in
/// that nothing ever hands it more than it asked for.
@Suite("Caption AI context")
struct CaptionAIContextTests {

    private func lines(_ count: Int, text: String = "A caption of ordinary length.") -> [CaptionAILine] {
        (1...count).map { number in
            CaptionAILine(
                number: number,
                segmentID: UUID(),
                startMs: number * 1_000,
                speaker: "",
                text: text
            )
        }
    }

    // MARK: - Batching

    @Test("Batches never exceed the budget")
    func batchesRespectBudget() {
        let budget = 200
        let batches = CaptionAIContext.batches(lines(40), budget: budget)

        #expect(batches.count > 1)
        for batch in batches {
            let cost = batch.reduce(0) { $0 + $1.prompt.count + 1 }
            // One line may exceed the budget on its own; more than one may not.
            #expect(batch.count == 1 || cost <= budget)
        }
    }

    @Test("Every line survives batching, in order")
    func batchingLosesNothing() {
        let source = lines(37)
        let flattened = CaptionAIContext.batches(source, budget: 300).flatMap { $0 }

        #expect(flattened.count == source.count)
        #expect(flattened.map(\.number) == source.map(\.number))
    }

    @Test("A single oversized line still gets through")
    func oversizedLineIsNotDropped() {
        let huge = lines(1, text: String(repeating: "x", count: 5_000))
        let batches = CaptionAIContext.batches(huge, budget: 200)

        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
    }

    @Test("An empty transcript produces no batches")
    func emptyProducesNoBatches() {
        #expect(CaptionAIContext.batches([], budget: 1_000).isEmpty)
    }

    // MARK: - Retrieval

    @Test("A #12 reference pulls in that caption and its neighbours")
    func explicitReferenceRetrieved() {
        let all = lines(30)
        let found = CaptionAIContext.retrieve(
            query: "please fix #12",
            lines: all,
            budget: 10_000
        )
        let numbers = Set(found.map(\.number))

        #expect(numbers.contains(12))
        #expect(numbers.contains(11))
        #expect(numbers.contains(13))
        #expect(!numbers.contains(20))
    }

    @Test("Reference numbers outside the transcript are ignored")
    func outOfRangeReferenceIgnored() {
        let all = lines(5)
        let found = CaptionAIContext.retrieve(query: "fix #900", lines: all, budget: 10_000)
        // Falls back to the head rather than returning nothing at all.
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.number <= 5 })
    }

    @Test("Keyword matches beat position")
    func keywordRetrieval() {
        var all = lines(30)
        all[17].text = "Welcome to RxLab, everyone."

        let found = CaptionAIContext.retrieve(
            query: "fix the RxLab spelling",
            lines: all,
            budget: 10_000
        )
        #expect(found.contains { $0.number == 18 })
    }

    @Test("The editor's selection is always included")
    func selectionRetrieved() {
        let all = lines(30)
        let target = all[24]

        let found = CaptionAIContext.retrieve(
            query: "make this shorter",
            lines: all,
            selection: [target.segmentID],
            budget: 10_000
        )
        #expect(found.contains { $0.number == target.number })
    }

    @Test("With nothing to go on, the head of the transcript is used")
    func fallsBackToHead() {
        let all = lines(100)
        let found = CaptionAIContext.retrieve(
            query: "tidy things up",
            lines: all,
            budget: 10_000
        )
        #expect(!found.isEmpty)
        #expect(found.first?.number == 1)
    }

    @Test("Retrieval obeys the budget")
    func retrievalRespectsBudget() {
        let all = lines(200)
        let found = CaptionAIContext.retrieve(query: "tidy things up", lines: all, budget: 300)
        let cost = found.reduce(0) { $0 + $1.prompt.count + 1 }

        #expect(cost <= 300 || found.count == 1)
    }

    // MARK: - Conversation compaction

    @Test("Only the tail of a conversation is kept verbatim")
    func partitionKeepsTail() {
        let turns = (1...10).map { CaptionChatTurn(role: "user", content: "turn \($0)") }
        let (older, recent) = CaptionAIContext.partition(turns: turns)

        #expect(recent.count == CaptionAIContext.verbatimTurns)
        #expect(older.count == 10 - CaptionAIContext.verbatimTurns)
        #expect(recent.last?.content == "turn 10")
        #expect(older.first?.content == "turn 1")
    }

    @Test("A short conversation is never compacted")
    func shortConversationUntouched() {
        let turns = (1...3).map { CaptionChatTurn(role: "user", content: "turn \($0)") }
        let (older, recent) = CaptionAIContext.partition(turns: turns)

        #expect(older.isEmpty)
        #expect(recent.count == 3)
    }

    // MARK: - Line rendering

    @Test("A line renders with its number and speaker")
    func lineRendering() {
        let line = CaptionAILine(
            number: 7,
            segmentID: UUID(),
            startMs: 0,
            speaker: "Alice",
            text: "Hello."
        )
        #expect(line.prompt == "7. [Alice] Hello.")
        #expect(line.compactPrompt == "7. Hello.")
    }

    @Test("The on-device budget is much smaller than the hosted one")
    func budgetsDiffer() {
        #expect(
            CaptionAIBackend.appleIntelligence.contextBudgetCharacters
                < CaptionAIBackend.openAICompatible.contextBudgetCharacters
        )
    }
}
