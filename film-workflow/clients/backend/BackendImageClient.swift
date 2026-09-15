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

    // MARK: - Choosing the model

    /// The image model a generation will actually be billed against.
    ///
    /// The catalog is curated server-side and the saved id is not: Settings
    /// keeps whatever was picked in the Keychain forever, and a Simple mode run
    /// never visits Settings at all. So the saved id is routinely empty or
    /// names a model the catalog has since dropped — and the backend answers
    /// both with a 400, never with a substitution. Use the saved id only while
    /// the catalog still offers it; otherwise take the catalog's own default,
    /// or its first entry.
    ///
    /// Returns the id unchanged when the catalog cannot be reached, so an
    /// offline picker's choice is still attempted rather than blanked.
    static func resolvedModel(preferred: String, forceRefresh: Bool = false) async -> String {
        let saved = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = await catalog(forceRefresh: forceRefresh)
        if catalog.isEmpty { return saved }
        if catalog.contains(where: { $0.id == saved }) { return saved }
        return (catalog.first(where: \.isPreferred) ?? catalog.first)?.id ?? saved
    }

    private static func catalog(forceRefresh: Bool = false) async -> [PickableModel] {
        (try? await BackendModelCatalog.shared.models(capability: .image, forceRefresh: forceRefresh)) ?? []
    }

    /// The catalog says which provider the backend calls: Google models run on
    /// AI Studio and take aspect ratio and resolution, gateway models take the
    /// OpenAI-style size/quality/format controls. Fall back to the id only when
    /// the catalog is unreachable.
    private static func isGoogleStyle(_ model: String) async -> Bool {
        let provider = await catalog().first { $0.id == model }?.provider
        return provider == "google" || (provider == nil && model.lowercased().contains("imagen"))
    }

    // MARK: - Generating

    static func generate(project: ImageGenProject, config: AppConfig) async throws -> ImageGenResult {
        let preferred = project.subscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.subscriptionImageModel
            : project.subscriptionModel
        let customSize = project.openAISizeEnum == .custom
            ? "\(project.openAICustomWidth)x\(project.openAICustomHeight)"
            : project.openAISizeEnum.apiValue
        return try await generating(preferred: preferred) { model, googleStyle in
            Request(
                model: model,
                prompt: project.prompt,
                n: 1,
                aspectRatio: googleStyle ? project.googleAspectRatioEnum.rawValue : nil,
                resolution: googleStyle ? project.googleResolutionEnum.rawValue : nil,
                size: googleStyle ? nil : customSize,
                quality: googleStyle ? nil : project.openAIQualityEnum.rawValue,
                format: googleStyle ? nil : project.openAIFormatEnum.rawValue,
                compression: !googleStyle && project.openAIFormatEnum.supportsCompression ? project.openAICompression : nil,
                background: googleStyle ? nil : (project.openAITransparent ? "transparent" : project.openAIBackgroundEnum.rawValue)
            )
        }
    }

    /// One image from a prompt alone, for tools that have no project to read
    /// parameters from — the Remotion image tool.
    ///
    /// `transparent` is only meaningful to the gateway's OpenAI-style models;
    /// the server ignores it for Google ones, and the caller reports whether
    /// it took (see `RemotionTools.generateImage`).
    static func generate(
        prompt: String,
        model: String,
        transparent: Bool,
        format: ImageFormat
    ) async throws -> ImageGenResult {
        try await generating(preferred: model) { model, googleStyle in
            Request(
                model: model,
                prompt: prompt,
                n: 1,
                aspectRatio: nil,
                resolution: nil,
                size: nil,
                quality: nil,
                format: googleStyle ? nil : format.rawValue,
                compression: nil,
                background: googleStyle || !transparent ? nil : "transparent"
            )
        }
    }

    /// Sends one image request, re-resolving the model against a refreshed
    /// catalog when the backend rejects the first choice.
    ///
    /// The rejection is the only way to tell a retired model from a request
    /// this account genuinely cannot make: the cached catalog can still be
    /// listing an id the server has stopped offering. One refreshed retry
    /// covers that; a second rejection is reported with the id that was tried
    /// and the ids that would have worked, because the message the server
    /// sends back names neither.
    private static func generating(
        preferred: String,
        _ makeRequest: @escaping (_ model: String, _ googleStyle: Bool) -> Request
    ) async throws -> ImageGenResult {
        let model = await resolvedModel(preferred: preferred)
        guard !model.isEmpty else { throw Self.noModelAvailable }
        do {
            return try await send(makeRequest(model, await isGoogleStyle(model)))
        } catch let error as BackendError {
            switch error {
            case .badRequest, .priceUnavailable, .modelUnavailable: break
            default: throw error
            }
            let refreshed = await resolvedModel(preferred: preferred, forceRefresh: true)
            guard !refreshed.isEmpty, refreshed != model else { throw await explained(error, model: model) }
            do {
                return try await send(makeRequest(refreshed, await isGoogleStyle(refreshed)))
            } catch let retry as BackendError {
                throw await explained(retry, model: refreshed)
            }
        }
    }

    private static func send(_ request: Request) async throws -> ImageGenResult {
        let response: Response = try await BackendClient.shared.post(
            "api/v1/ai/images",
            body: request,
            idempotencyKey: "image:\(UUID().uuidString)"
        )
        return try decode(response)
    }

    /// Names the model that was refused and the ones on offer.
    ///
    /// The server's own text ("This model is not available for the selected
    /// capability") says neither, which leaves a caller — a person or the
    /// agent — retrying model ids it has no list of. Anything that is not a
    /// rejected request passes through untouched.
    private static func explained(_ error: BackendError, model: String) async -> BackendError {
        // A refusal of the model itself is the one case the user can act on, so
        // it keeps its own shape — naming the id lets the alert offer the
        // picker that chose it instead of a list to retype from.
        if case .modelUnavailable = error { return error.namingModel(model, capability: .image) }
        guard case .badRequest(let message) = error else { return error }
        let ids = await catalog().map(\.id)
        let available = ids.isEmpty
            ? "none are listed for this account"
            : ids.joined(separator: ", ")
        return .badRequest("\(message) Tried \(model); available image models: \(available).")
    }

    private static let noModelAvailable = BackendError.badRequest(
        "No image model is available for this account. Sign in, then pick one in Settings \u{25B8} AI."
    )

    private static func decode(_ response: Response) throws -> ImageGenResult {
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
