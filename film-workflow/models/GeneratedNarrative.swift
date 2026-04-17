import Foundation
import SwiftData

@Model
final class GeneratedNarrative {
    var audioFilePath: String
    var transcriptText: String
    var createdAt: Date
    var providerName: String = ""
    var speakerSummary: String = ""
    var project: NarrativeProject?

    init(
        audioFilePath: String,
        transcriptText: String,
        project: NarrativeProject,
        providerName: String = "",
        speakerSummary: String = ""
    ) {
        self.audioFilePath = audioFilePath
        self.transcriptText = transcriptText
        self.createdAt = Date()
        self.providerName = providerName
        self.speakerSummary = speakerSummary
        self.project = project
    }

    var audioURL: URL {
        FileStorage.absoluteURL(for: audioFilePath)
    }

    var fileExtension: String {
        (audioFilePath as NSString).pathExtension
    }
}
