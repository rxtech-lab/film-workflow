import Foundation

enum BackendImageClient {
    private struct Request: Encodable {
        let model: String
        let prompt: String
        let n: Int
        let aspectRatio: String?
        let resolution: String?
        let size: String?
        let quality: String?
        let format: String?
        let compression: Int?
        let background: String?
    }

    private struct Response: Decodable {
        struct Image: Decodable { let b64Json: String; let mimeType: String }
        struct Usage: Decodable { let chargedPoints: Int; let availablePoints: Int }
        let images: [Image]
        let usage: Usage
    }

    static func generate(project: ImageGenProject, config: AppConfig) async throws -> ImageGenResult {
        let model = project.subscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.subscriptionImageModel
            : project.subscriptionModel
        guard !model.isEmpty else { throw BackendError.badRequest("Select a subscription image model.") }
        // The catalog says which provider the backend calls: Google models run on
        // AI Studio and take aspect ratio and resolution, gateway models take the
        // OpenAI-style size/quality/format controls. Fall back to the id only when
        // the catalog is unreachable.
        let catalog = (try? await BackendModelCatalog.shared.models(capability: .image)) ?? []
        let provider = catalog.first { $0.id == model }?.provider
        let googleStyle = provider == "google"
            || (provider == nil && model.lowercased().contains("imagen"))
        let customSize = project.openAISizeEnum == .custom
            ? "\(project.openAICustomWidth)x\(project.openAICustomHeight)"
            : project.openAISizeEnum.apiValue
        let response: Response = try await BackendClient.shared.post(
            "api/v1/ai/images",
            body: Request(
                model: model,
                prompt: project.prompt,
                n: 1,
                aspectRatio: googleStyle ? project.googleAspectRatioEnum.rawValue : nil,
                resolution: googleStyle ? project.googleResolutionEnum.rawValue : nil,
                size: googleStyle ? nil : customSize,
                quality: googleStyle ? nil : project.openAIQualityEnum.rawValue,
                format: googleStyle ? nil : project.openAIFormatEnum.rawValue,
                compression: googleStyle ? nil : project.openAICompression,
                background: googleStyle ? nil : (project.openAITransparent ? "transparent" : project.openAIBackgroundEnum.rawValue)
            ),
            idempotencyKey: "image:\(UUID().uuidString)"
        )
        guard let image = response.images.first,
              let data = Data(base64Encoded: image.b64Json)
        else { throw BackendError.decoding(ImageGenError.noImageInResponse) }
        CreditBalanceStore.shared.apply(available: response.usage.availablePoints)
        let fileExtension: String
        switch image.mimeType.lowercased() {
        case let value where value.contains("jpeg"): fileExtension = "jpg"
        case let value where value.contains("webp"): fileExtension = "webp"
        default: fileExtension = "png"
        }
        return ImageGenResult(imageData: data, fileExtension: fileExtension)
    }
}
