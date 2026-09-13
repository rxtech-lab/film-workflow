import Foundation
import SwiftData

@MainActor
enum MusicGenerationService {
    @discardableResult
    static func generate(
        project: MusicProject,
        context: ModelContext,
        config: AppConfig
    ) async throws -> GeneratedMusic {
        let basePrompt = PromptBuilder.build(from: project)
        let prompt = project.inputModeEnum == .prompt
            ? basePrompt + "\n\nAdditional instructions:\n" + project.promptText
            : basePrompt

        let storage = ProjectStorage.forContainer(context.container)
        var imageDataPairs: [(mimeType: String, base64: String)] = []
        for path in project.referenceImagePaths {
            let url = storage.absoluteURL(for: path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mimeType = ext == "png" ? "image/png" : "image/jpeg"
            imageDataPairs.append((mimeType: mimeType, base64: data.base64EncodedString()))
        }

        try AIRoute.requireSubscription()
        let response = try await BackendMusicClient.generate(
            prompt: prompt,
            imageDataPairs: imageDataPairs,
            responseMimeType: project.outputFormatEnum.requestMimeType
        )

        let ext: String
        switch response.mimeType {
        case "audio/wav": ext = "wav"
        case "audio/mp3", "audio/mpeg": ext = "mp3"
        default: ext = "wav"
        }

        let relativePath = try storage.saveAudio(response.audioData, extension: ext, kind: .music)
        let durationSeconds = await AudioProbe.durationSeconds(of: storage.absoluteURL(for: relativePath))
        let generated = GeneratedMusic(
            audioFilePath: relativePath,
            lyricsText: response.lyricsText,
            project: project
        )
        generated.durationSeconds = durationSeconds
        context.insert(generated)
        project.updatedAt = Date()
        return generated
    }
}
