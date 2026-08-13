import Foundation
import SwiftData

@MainActor
enum ImageGenerationService {
    @discardableResult
    static func generate(
        project: ImageGenProject,
        context: ModelContext,
        config: AppConfig
    ) async throws -> GeneratedImage {
        let result: ImageGenResult
        switch try AIRoute.resolve(config, for: .image) {
        case .subscription:
            result = try await BackendImageClient.generate(project: project, config: config)
        case .byok:
        if project.providerEnum == .google {
            guard !config.googleAIKey.isEmpty, !project.googleModel.isEmpty else {
                throw ImageGenError.missingConfig
            }
            result = try await ImageGenClient.generateGoogle(
                prompt: project.prompt,
                model: project.googleModel,
                aspectRatio: project.googleAspectRatioEnum,
                resolution: project.googleResolutionEnum,
                apiKey: config.googleAIKey
            )
        } else {
            guard !config.openAIEndpoint.isEmpty,
                  !config.openAIKey.isEmpty,
                  !project.openAIModel.isEmpty else {
                throw ImageGenError.missingConfig
            }
            let modelHasGoogle = project.openAIModel.lowercased().contains("google")
            if modelHasGoogle {
                result = try await ImageGenClient.generateOpenAI(
                    prompt: project.prompt,
                    model: project.openAIModel,
                    endpoint: config.openAIEndpoint,
                    apiKey: config.openAIKey,
                    aspectRatio: project.googleAspectRatioEnum,
                    resolution: project.googleResolutionEnum
                )
            } else {
                let customSize: String? = project.openAISizeEnum == .custom
                    ? "\(project.openAICustomWidth)x\(project.openAICustomHeight)"
                    : nil
                result = try await ImageGenClient.generateImage(
                    prompt: project.prompt,
                    model: project.openAIModel,
                    endpoint: config.openAIEndpoint,
                    apiKey: config.openAIKey,
                    size: project.openAISizeEnum,
                    customSize: customSize,
                    quality: project.openAIQualityEnum,
                    format: project.openAIFormatEnum,
                    compression: project.openAICompression,
                    background: project.openAIBackgroundEnum,
                    transparent: project.openAITransparent
                )
            }
        }
        }

        let relativePath = try FileStorage.saveImage(result.imageData, fileExtension: result.fileExtension)
        let generated = GeneratedImage(
            imageFilePath: relativePath,
            prompt: project.prompt,
            project: project
        )
        context.insert(generated)
        project.updatedAt = Date()
        return generated
    }
}
