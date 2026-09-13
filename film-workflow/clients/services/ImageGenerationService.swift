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
        try AIRoute.requireSubscription()
        let result = try await BackendImageClient.generate(project: project, config: config)

        let relativePath = try ProjectStorage.forContainer(context.container).saveImage(result.imageData, fileExtension: result.fileExtension)
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
