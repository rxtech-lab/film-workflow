import Foundation
import SwiftData

@Model
final class NarrativeProject {
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var provider: String
    var sceneDescription: String
    var notes: String
    var context: String
    var azureOutputFormat: String = AzureAudioFormat.mp3.rawValue

    var speakers: [NarrativeSpeaker]
    var paragraphs: [NarrativeParagraph]

    @Relationship(deleteRule: .cascade, inverse: \GeneratedNarrative.project)
    var generatedFiles: [GeneratedNarrative]

    init(name: String) {
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.provider = NarrativeProvider.gemini.rawValue
        self.sceneDescription = ""
        self.notes = ""
        self.context = ""
        self.speakers = [
            NarrativeSpeaker(displayName: "Speaker 1", voice: GeminiVoice.achernar.rawValue)
        ]
        self.paragraphs = []
        self.generatedFiles = []
    }

    var providerEnum: NarrativeProvider {
        get { NarrativeProvider(rawValue: provider) ?? .gemini }
        set { provider = newValue.rawValue }
    }

    var azureOutputFormatEnum: AzureAudioFormat {
        get { AzureAudioFormat(rawValue: azureOutputFormat) ?? .mp3 }
        set { azureOutputFormat = newValue.rawValue }
    }
}
