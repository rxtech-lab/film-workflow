import Foundation
import SwiftData

@Model
final class RemotionProject: GroupableProject {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var groupID: UUID?

    var text: String
    var durationSeconds: Double
    var themeColorHex: String
    var imagePaths: [String]
    var referenceImagePath: String?
    var audioFilePaths: [String] = []
    var prompt: String = ""

    var compositionWidth: Int = 1920
    var compositionHeight: Int = 1080
    var compositionFps: Int = 30

    var compositionSource: String

    /// True when the project was created through the MCP `create_project` tool,
    /// which seeds a default composition and boots Studio immediately. Such
    /// projects never show the "Generate Initial Composition" button.
    var createdViaMCP: Bool = false

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.groupID = nil
        self.text = ""
        self.durationSeconds = 5
        self.themeColorHex = "#1E1E1E"
        self.imagePaths = []
        self.referenceImagePath = nil
        self.audioFilePaths = []
        self.prompt = ""
        self.compositionWidth = 1920
        self.compositionHeight = 1080
        self.compositionFps = 30
        self.compositionSource = ""
        self.createdViaMCP = false
    }
}
