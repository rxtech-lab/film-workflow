import Foundation
import SwiftData

@Model
final class RemotionProject {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var text: String
    var durationSeconds: Double
    var themeColorHex: String
    var imagePaths: [String]
    var referenceImagePath: String?
    var musicFilePath: String?
    var prompt: String = ""

    var compositionSource: String

    @Relationship(deleteRule: .cascade, inverse: \RemotionMessage.project)
    var messages: [RemotionMessage]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.text = ""
        self.durationSeconds = 5
        self.themeColorHex = "#1E1E1E"
        self.imagePaths = []
        self.referenceImagePath = nil
        self.musicFilePath = nil
        self.prompt = ""
        self.compositionSource = ""
        self.messages = []
    }
}
