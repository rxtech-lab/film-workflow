import Foundation
import Testing

@testable import film_workflow

/// The assistant hands the model line *numbers*, never identifiers, so this is
/// the seam where a hallucinated reference has to be caught. These pin that
/// mapping down.
@Suite("Caption assistant edits")
@MainActor
struct CaptionAssistantTests {

    private func transcript(_ texts: [String]) -> CaptionTranscriptSnapshot {
        CaptionTranscriptSnapshot(
            projectName: "Test",
            audioDurationMs: 60_000,
            speakers: [],
            segments: texts.enumerated().map { index, text in
                CaptionSegmentSnapshot(
                    startMs: index * 1_000,
                    endMs: (index + 1) * 1_000,
                    text: text
                )
            }
        )
    }

    @Test("A line number maps onto the right segment")
    func numberMapsToSegment() throws {
        let source = transcript(["First.", "Second.", "Third."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = try #require(CaptionProposalMapping.proposal(
            from: [CaptionChatEdit(number: 2, kind: .replaceText, pieces: ["Second, revised."])],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        ))

        #expect(proposal.items.count == 1)
        #expect(proposal.items[0].before == "Second.")
        #expect(proposal.items[0].displayIndex == 2)
        if case .replaceText(let segment, _) = proposal.items[0].operation {
            #expect(segment == source.segments[1].id)
        } else {
            Issue.record("expected a replaceText operation")
        }
    }

    @Test("A number outside the transcript is dropped")
    func hallucinatedNumberDropped() {
        let source = transcript(["First.", "Second."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = CaptionProposalMapping.proposal(
            from: [CaptionChatEdit(number: 99, kind: .delete)],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        )
        #expect(proposal == nil)
    }

    @Test("Merging the last caption is dropped, since it has no successor")
    func mergeAtEndDropped() {
        let source = transcript(["First.", "Second."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = CaptionProposalMapping.proposal(
            from: [CaptionChatEdit(number: 2, kind: .mergeWithNext)],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        )
        #expect(proposal == nil)
    }

    @Test("Merge resolves to the following caption")
    func mergeResolvesNeighbour() throws {
        let source = transcript(["First.", "Second.", "Third."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = try #require(CaptionProposalMapping.proposal(
            from: [CaptionChatEdit(number: 1, kind: .mergeWithNext)],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        ))
        #expect(proposal.items.count == 1)
        #expect(proposal.items[0].after == "First. Second.")
        #expect(proposal.items[0].verdict.isOK)
    }

    @Test("A split needs at least two pieces")
    func splitNeedsTwoPieces() {
        let source = transcript(["One two three."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = CaptionProposalMapping.proposal(
            from: [CaptionChatEdit(number: 1, kind: .split, pieces: ["One two three."])],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        )
        #expect(proposal == nil)
    }

    @Test("Conversational text edits aren't content-checked")
    func chatEditsUseFreePolicy() throws {
        let source = transcript(["Wrong entirely."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = try #require(CaptionProposalMapping.proposal(
            from: [CaptionChatEdit(number: 1, kind: .replaceText, pieces: ["Something else."])],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        ))
        // The user asked for it in their own words, so rewriting is allowed.
        #expect(proposal.items[0].verdict.isOK)
    }

    @Test("Reasons from the model reach the review row")
    func reasonsSurvive() throws {
        let source = transcript(["First.", "Second."])
        let lines = CaptionAIContext.lines(from: source.segments)

        let proposal = try #require(CaptionProposalMapping.proposal(
            from: [
                CaptionChatEdit(
                    number: 1,
                    kind: .replaceText,
                    pieces: ["First, revised."],
                    reason: "you asked for a comma"
                )
            ],
            lines: lines,
            transcript: source,
            terms: [],
            maxRunes: 80
        ))
        #expect(proposal.items[0].reason == "you asked for a comma")
    }

    @Test("No edits means no proposal at all")
    func noEditsNoProposal() {
        let source = transcript(["First."])
        let lines = CaptionAIContext.lines(from: source.segments)

        #expect(
            CaptionProposalMapping.proposal(
                from: [],
                lines: lines,
                transcript: source,
                terms: [],
                maxRunes: 80
            ) == nil
        )
    }
}
