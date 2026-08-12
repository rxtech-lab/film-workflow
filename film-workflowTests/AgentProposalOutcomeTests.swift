import Foundation
import SwiftData
import Testing

@testable import film_workflow

/// What the agent window does once a proposal has been reviewed.
///
/// The review sheet used to close in silence: the card still read "Review 1
/// change…", nothing said whether anything had been written, and the model was
/// never told either — so the next turn went on describing applied work as
/// pending. These lock in both halves of the fix.
@Suite("Agent proposal outcomes")
@MainActor
struct AgentProposalOutcomeTests {

    private func makeThread() throws -> (AgentThread, AgentMessage, ModelContext) {
        let schema = Schema([AgentThread.self, AgentMessage.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let projectUUID = UUID()
        let thread = AgentThread(target: AgentTarget(kind: .caption, projectUUID: projectUUID))
        context.insert(thread)

        let proposal = CaptionEditProposal(
            summary: "Reword the closing tagline",
            items: [
                CaptionEditProposalItem(
                    operation: .setTranslation(
                        segment: UUID(), language: "zh-Hans", text: "身份随行。"
                    ),
                    displayIndex: 26,
                    startMs: 1_000,
                    before: "Carry your identity.",
                    after: "身份随行。"
                )
            ]
        )
        let row = AgentMessage(
            role: .assistant,
            content: proposal.summary,
            kind: .proposal,
            proposalJSON: proposal.encodedJSON(),
            proposalProjectUUID: projectUUID
        )
        row.thread = thread
        context.insert(row)
        thread.messages.append(row)
        try context.save()

        return (thread, row, context)
    }

    @Test("Applying is recorded on the card and told to the model")
    func applyingIsRecorded() throws {
        let (thread, row, context) = try makeThread()
        #expect(row.proposalAppliedCount == nil)

        AgentController.shared.recordProposalOutcome(applied: 1, for: row, context: context)

        // The card can stop offering an unreviewed batch.
        #expect(row.proposalAppliedCount == 1)
        // And the transcript carries the outcome, as a replayable turn: text
        // rows are what `liveTextMessages` sends on the next request.
        let notes = thread.liveTextMessages.filter { $0.roleEnum == .system }
        #expect(notes.count == 1)
        #expect(notes[0].content.contains("applied 1 of 1"))
    }

    @Test("Rejecting everything is recorded too, rather than looking unreviewed")
    func rejectingIsRecorded() throws {
        let (thread, row, context) = try makeThread()

        AgentController.shared.recordProposalOutcome(applied: 0, for: row, context: context)

        // Zero is a decision, not the absence of one — hence Int? rather than a
        // count that starts at zero.
        #expect(row.proposalAppliedCount == 0)
        let notes = thread.liveTextMessages.filter { $0.roleEnum == .system }
        #expect(notes.count == 1)
        #expect(notes[0].content.contains("none"))
    }

    @Test("The pending proposal is cleared from the project it was proposed against")
    func applyingClearsThePendingProposal() throws {
        let (thread, row, context) = try makeThread()
        let projectUUID = try #require(row.proposalProjectUUID)

        let proposal = try #require(row.proposal)
        AgentController.shared.setPendingProposal(proposal, forProjectUUID: projectUUID)
        #expect(AgentController.shared.pendingProposal(forProjectUUID: projectUUID) != nil)

        // Cleared by the row's own project id, so a thread that retargeted
        // mid-life still releases the right one.
        thread.target = AgentTarget(kind: .none, projectUUID: nil)
        AgentController.shared.recordProposalOutcome(applied: 1, for: row, context: context)
        #expect(AgentController.shared.pendingProposal(forProjectUUID: projectUUID) == nil)
    }
}
