import Foundation
import SwiftData

@Model
final class RemotionMessage {
    var id: UUID
    var role: String
    var content: String
    var createdAt: Date
    var project: RemotionProject?

    init(role: String, content: String, project: RemotionProject? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.project = project
    }
}

enum RemotionMessageRole: String {
    case user
    case assistant
    case system
}
