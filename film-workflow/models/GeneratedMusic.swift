import Foundation
import SwiftData

@Model
final class GeneratedMusic {
    /// Stable identity for MCP, agent targets and timeline references.
    /// A `PersistentIdentifier` is neither stable across launches nor
    /// representable in a scene payload.
    var id: UUID = UUID()

    var audioFilePath: String
    var lyricsText: String?
    var createdAt: Date
    var project: MusicProject?

    init(audioFilePath: String, lyricsText: String?, project: MusicProject) {
        self.audioFilePath = audioFilePath
        self.lyricsText = lyricsText
        self.createdAt = Date()
        self.project = project
    }

    var audioURL: URL {
        ProjectStorage.for(model: self).absoluteURL(for: audioFilePath)
    }

    var fileExtension: String {
        (audioFilePath as NSString).pathExtension
    }
}
