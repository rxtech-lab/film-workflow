import Foundation
import SwiftData

@Model
final class GeneratedImage {
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
        FileStorage.absoluteURL(for: imageFilePath)
    }

    var fileExtension: String {
        (imageFilePath as NSString).pathExtension
    }
}
