import Foundation
import SwiftData

/// One message in a caption project's assistant conversation.
///
/// Modelled on `RemotionMessage`: enums are stored as raw `String`s so adding a
/// case later is a purely additive schema change, and tool rows live in the same
/// table as text rows so the transcript is one ordered list.
@Model
final class CaptionAssistantMessage {
    var id: UUID = UUID()
    var role: String = CaptionAssistantRole.user.rawValue
    var content: String = ""
    var createdAt: Date = Date()

    var project: CaptionProject?

    var kind: String = CaptionAssistantMessageKind.text.rawValue

    /// Tool rows only.
    var toolName: String?
    var toolArgs: String?
    var toolResult: String?
    var toolStatus: String?
    var toolCallId: String?

    /// Proposal rows only: the encoded `CaptionEditProposal`, so a turn can be
    /// reviewed again after the sheet has been dismissed.
    var proposalJSON: String?

    /// True once this message's content has been folded into the project's
    /// rolling summary. Compacted rows stay visible in the UI but are no longer
    /// sent to the model.
    var isCompacted: Bool = false

    init(
        role: CaptionAssistantRole,
        content: String,
        kind: CaptionAssistantMessageKind = .text,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolResult: String? = nil,
        toolStatus: CaptionAssistantToolStatus? = nil,
        toolCallId: String? = nil,
        proposalJSON: String? = nil
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
        self.isCompacted = false
    }

    // MARK: - Enum accessors

    var roleEnum: CaptionAssistantRole {
        get { CaptionAssistantRole(rawValue: role) ?? .assistant }
        set { role = newValue.rawValue }
    }

    var kindEnum: CaptionAssistantMessageKind {
        get { CaptionAssistantMessageKind(rawValue: kind) ?? .text }
        set { kind = newValue.rawValue }
    }

    var toolStatusEnum: CaptionAssistantToolStatus? {
        get { toolStatus.flatMap(CaptionAssistantToolStatus.init(rawValue:)) }
        set { toolStatus = newValue?.rawValue }
    }

    var proposal: CaptionEditProposal? {
        guard let proposalJSON else { return nil }
        return CaptionEditProposal.decode(fromJSON: proposalJSON)
    }
}

nonisolated enum CaptionAssistantRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

nonisolated enum CaptionAssistantMessageKind: String, Codable, Sendable {
    case text
    case tool
    /// Carries a `CaptionEditProposal` for review.
    case proposal
}

nonisolated enum CaptionAssistantToolStatus: String, Codable, Sendable {
    case pending
    case ok
    case failed
}
