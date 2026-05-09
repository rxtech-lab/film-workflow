import Foundation
import SwiftData

@Model
final class RemotionMessage {
    var id: UUID
    var role: String
    var content: String
    var createdAt: Date
    var project: RemotionProject?

    var kind: String = RemotionMessageKind.text.rawValue
    var toolName: String?
    var toolArgs: String?
    var toolResult: String?
    var toolStatus: String?
    var toolCallId: String?

    init(
        role: String,
        content: String,
        project: RemotionProject? = nil,
        kind: RemotionMessageKind = .text,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolResult: String? = nil,
        toolStatus: RemotionToolStatus? = nil,
        toolCallId: String? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.project = project
        self.kind = kind.rawValue
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolResult = toolResult
        self.toolStatus = toolStatus?.rawValue
        self.toolCallId = toolCallId
    }
}

enum RemotionMessageRole: String {
    case user
    case assistant
    case system
}

enum RemotionMessageKind: String {
    case text
    case tool
}

enum RemotionToolStatus: String {
    case pending
    case ok
    case failed
}
