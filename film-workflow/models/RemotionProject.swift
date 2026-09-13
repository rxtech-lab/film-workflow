import Foundation
import SwiftData

@Model
final class RemotionProject: GroupableProject {
    var id: UUID
    var marketplaceItemId: String?
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

    /// True when the composition was created through the MCP `footage_create`
    /// tool, which seeds a default composition and starts the preview
    /// immediately. Such items never show the "Generate Initial Composition"
    /// button.
    var createdViaMCP: Bool = false

    /// On-disk Remotion project folder inside the film package.
    var projectDir: URL {
        ProjectStorage.for(model: self).remotionProjectDir(id: id)
    }

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
