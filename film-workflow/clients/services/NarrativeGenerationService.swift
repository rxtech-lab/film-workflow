import Foundation
import SwiftData

/// Shared narrative generation flow used by `NarrativeTabView` and the MCP server.
@MainActor
enum NarrativeGenerationService {
    /// Runs TTS, persists the audio, and inserts a `GeneratedNarrative` into the supplied
    /// model context. Returns the inserted record (already linked to the project).
    @discardableResult
    static func generate(
        project: NarrativeProject,
        context: ModelContext,
        config: AppConfig
    ) async throws -> GeneratedNarrative {
        let summary = speakerSummary(for: project)

        switch project.providerEnum {
        case .gemini:
            let transcript = NarrativePromptBuilder.build(from: project)
            let response = try await GeminiTTSClient.generate(
                transcript: transcript,
                speakers: project.speakers,
                apiKey: config.googleAIKey
            )
            let relativePath = try FileStorage.saveAudio(response.audioData, extension: "wav")
            let generated = GeneratedNarrative(
                audioFilePath: relativePath,
                transcriptText: transcript,
                project: project,
                providerName: project.providerEnum.displayName,
                speakerSummary: summary
            )
            context.insert(generated)
            project.updatedAt = Date()
            return generated

        case .azure:
            let ssml = AzureSSMLBuilder.build(from: project)
            let response = try await AzureTTSClient.generate(
                project: project,
                apiKey: config.azureSpeechKey,
                endpoint: config.azureSpeechEndpoint,
                format: project.azureOutputFormatEnum
            )
            let relativePath = try FileStorage.saveAudio(
                response.audioData, extension: response.fileExtension)
            let generated = GeneratedNarrative(
                audioFilePath: relativePath,
                transcriptText: ssml,
                project: project,
                providerName: project.providerEnum.displayName,
                speakerSummary: summary
            )
            context.insert(generated)
            project.updatedAt = Date()
            return generated
        }
    }

    static func speakerSummary(for project: NarrativeProject) -> String {
        project.speakers
            .map { speaker -> String in
                let voiceName: String
                switch project.providerEnum {
                case .azure: voiceName = speaker.azureVoice
                case .gemini: voiceName = speaker.geminiVoice.isEmpty ? speaker.voice : speaker.geminiVoice
                }
                return voiceName.isEmpty ? speaker.displayName : "\(speaker.displayName) \(voiceName)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
