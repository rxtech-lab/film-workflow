import Foundation
import SwiftData

@Model
final class GeneratedImage {
    /// Stable identity for MCP, agent targets and timeline references.
    /// A `PersistentIdentifier` is neither stable across launches nor
    /// representable in a scene payload.
    var id: UUID = UUID()

    var imageFilePath: String
    var prompt: String
    var createdAt: Date
    var project: ImageGenProject?

    init(imageFilePath: String, prompt: String, project: ImageGenProject) {
        self.imageFilePath = imageFilePath
        self.prompt = prompt
        self.createdAt = Date()
        self.project = project
    }

    var imageURL: URL {
        ProjectStorage.for(model: self).absoluteURL(for: imageFilePath)
    }

    var fileExtension: String {
        (imageFilePath as NSString).pathExtension
    }
}
