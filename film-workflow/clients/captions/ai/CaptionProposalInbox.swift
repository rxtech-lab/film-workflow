import Foundation

/// Where a proposal from `caption_propose_edits` goes.
///
/// The MCP tool has one caller shape but two destinations. When the user is
/// chatting, a proposal belongs in the assistant window. When a batch task is
/// running — "Review Splits…" driven by Claude Code or Codex — the same tool
/// call is that task's *return value*, and posting it to the assistant window
/// would leave the caller waiting for something that never arrives.
///
/// So a batch task claims the project for the duration of its run, and anything
/// proposed while it holds the claim is collected here instead.
///
/// One claim per project: a second batch task on the same project can't start
/// while the first is running (the toolbar disables itself), and two agents
/// proposing into one inbox would interleave unreadably.
@MainActor
enum CaptionProposalInbox {

    private struct Claim {
        /// How strictly to judge what arrives — a split run may not change
        /// words, where a conversational edit is whatever the user asked for.
        var policy: CaptionProposalPolicy
        var collected: [CaptionEditProposal] = []
    }

    private static var claims: [UUID: Claim] = [:]

    /// Which engine is currently working on a project, so a proposal that
    /// arrives over MCP can say who made it. Set for chat turns as well as
    /// batch runs — the tool call looks identical either way, and by the time
    /// it lands the engine that made it is otherwise unknowable.
    private static var engineLabels: [UUID: String] = [:]

    static func setEngineLabel(_ label: String, for projectID: UUID) {
        engineLabels[projectID] = label
    }

    static func clearEngineLabel(for projectID: UUID) {
        engineLabels[projectID] = nil
    }

    static func engineLabel(for projectID: UUID) -> String {
        engineLabels[projectID] ?? ""
    }

    /// Collects proposals for this project until `finish` is called.
    static func claim(_ projectID: UUID, policy: CaptionProposalPolicy) {
        claims[projectID] = Claim(policy: policy)
    }

    /// Releases the claim and returns everything collected, merged.
    ///
    /// An agent working through a long transcript will call the tool several
    /// times — in batches, as the system prompt asks — and the user should see
    /// one review list, not one per batch.
    @discardableResult
    static func finish(_ projectID: UUID) -> CaptionEditProposal {
        guard let claim = claims.removeValue(forKey: projectID) else {
            return CaptionEditProposal()
        }
        var merged = CaptionEditProposal()
        merged.items = claim.collected.flatMap(\.items)
        merged.summary = claim.collected.first(where: { !$0.summary.isEmpty })?.summary ?? ""
        merged.engine = claim.collected.first(where: { !$0.engine.isEmpty })?.engine ?? ""
        return merged
    }

    /// The policy a batch task wants applied, or nil when nobody has claimed
    /// this project and the proposal should go to the assistant instead.
    static func policy(for projectID: UUID) -> CaptionProposalPolicy? {
        claims[projectID]?.policy
    }

    /// Hands a proposal to the running batch task. False when there isn't one.
    static func deliver(_ proposal: CaptionEditProposal, for projectID: UUID) -> Bool {
        guard var claim = claims[projectID] else { return false }
        claim.collected.append(proposal)
        claims[projectID] = claim
        return true
    }
}
