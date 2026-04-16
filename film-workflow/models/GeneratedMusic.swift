import Foundation
import SwiftData

@Model
final class GeneratedMusic {
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
        FileStorage.absoluteURL(for: audioFilePath)
    }

    var fileExtension: String {
        (audioFilePath as NSString).pathExtension
    }
}
