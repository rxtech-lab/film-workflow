import Foundation
import SwiftData

/// One row in an agent thread's transcript.
///
/// Merges the two message models this replaces — `RemotionMessage` and
/// `CaptionAssistantMessage` — which had converged on the same shape anyway.
/// Enums are stored as raw `String`s so adding a case later stays a purely
/// additive schema change, and tool rows live in the same table as text rows so
/// the transcript is one ordered list rather than two that have to be merged at
/// render time.
@Model
final class AgentMessage {
    var id: UUID = UUID()
    var role: String = AgentMessageRole.user.rawValue
    var content: String = ""
    var createdAt: Date = Date()

    var thread: AgentThread?

    var kind: String = AgentMessageKind.text.rawValue

    // MARK: - Tool rows only

    var toolName: String?
    var toolArgs: String?
    var toolResult: String?
    var toolStatus: String?
    var toolCallId: String?

    // MARK: - Proposal rows only

    /// The encoded `CaptionEditProposal`, so a turn can be reviewed again after
    /// the sheet has been dismissed.
    var proposalJSON: String?

    /// The project the proposal applies to. A thread can retarget mid-life, so
    /// the row has to remember which project it was proposed against rather than
    /// reading the thread's current target.
    var proposalProjectUUID: UUID?

    /// How many of this proposal's changes the user actually applied, or nil
    /// while it is still waiting to be reviewed.
    ///
    /// Stored on the row rather than kept in view state because the answer has
    /// to survive scrolling, relaunching and re-opening the sheet: a card that
    /// still says "Review 1 change…" after the change has been applied is the
    /// only feedback the window gives, and it is wrong.
    var proposalAppliedCount: Int?

    /// True once this row's content has been folded into the thread's rolling
    /// summary. Compacted rows stay visible in the UI but are no longer sent.
    var isCompacted: Bool = false

    init(
        role: AgentMessageRole,
        content: String,
        kind: AgentMessageKind = .text,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolResult: String? = nil,
        toolStatus: AgentToolStatus? = nil,
        toolCallId: String? = nil,
        proposalJSON: String? = nil,
        proposalProjectUUID: UUID? = nil
    ) {
        self.id = UUID()
        self.role = role.rawValue
        self.content = content
        self.createdAt = Date()
        self.kind = kind.rawValue
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolResult = toolResult
        self.toolStatus = toolStatus?.rawValue
        self.toolCallId = toolCallId
        self.proposalJSON = proposalJSON
        self.proposalProjectUUID = proposalProjectUUID
        self.proposalAppliedCount = nil
        self.isCompacted = false
    }

    // MARK: - Enum accessors

    var roleEnum: AgentMessageRole {
        get { AgentMessageRole(rawValue: role) ?? .assistant }
        set { role = newValue.rawValue }
    }

    var kindEnum: AgentMessageKind {
        get { AgentMessageKind(rawValue: kind) ?? .text }
        set { kind = newValue.rawValue }
    }

    var toolStatusEnum: AgentToolStatus? {
        get { toolStatus.flatMap(AgentToolStatus.init(rawValue:)) }
        set { toolStatus = newValue?.rawValue }
    }

    var proposal: CaptionEditProposal? {
        guard let proposalJSON else { return nil }
        return CaptionEditProposal.decode(fromJSON: proposalJSON)
    }
}

extension AgentMessage: MessageListItem {
    var messageID: UUID { id }
    var isUserMessage: Bool { roleEnum == .user }
}

nonisolated enum AgentMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

nonisolated enum AgentMessageKind: String, Codable, Sendable {
    case text
    case tool
    /// Carries a `CaptionEditProposal` for review.
    case proposal
}

nonisolated enum AgentToolStatus: String, Codable, Sendable {
    case pending
    case ok
    case failed
}
