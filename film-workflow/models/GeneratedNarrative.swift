import Foundation
import SwiftData

@Model
final class GeneratedNarrative {
    /// Stable identity for MCP, agent targets and timeline references.
    /// A `PersistentIdentifier` is neither stable across launches nor
    /// representable in a scene payload.
    var id: UUID = UUID()

    var audioFilePath: String
    var transcriptText: String
    var createdAt: Date
    var providerName: String = ""
    var speakerSummary: String = ""
    /// Weak link to the `CaptionProject` generated for this audio, if any. A
    /// plain `UUID?` rather than a relationship so the schema change stays
    /// additive and a hand-edited caption project outlives this record.
    var captionProjectID: UUID?
    /// Why captions were degraded or skipped. Empty when all went well.
    var captionWarning: String = ""
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
        ProjectStorage.for(model: self).absoluteURL(for: audioFilePath)
    }

    var fileExtension: String {
        (audioFilePath as NSString).pathExtension
    }
}
