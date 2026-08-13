import Foundation

nonisolated struct PickableModel: Codable, Identifiable, Hashable, Sendable {
    struct Estimate: Codable, Hashable, Sendable {
        let unit: String
        let pointsPerUnit: Int
    }

    let id: String
    let provider: String
    let displayName: String
    let capability: String
    let estimate: Estimate?

    var pickerLabel: String {
        guard let estimate else { return displayName }
        let unit = estimate.unit
            .replacingOccurrences(of: "audio_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return "\(displayName) · ≈\(estimate.pointsPerUnit) credits/\(unit)"
    }
}

nonisolated private struct ModelCatalogResponse: Codable { let models: [PickableModel] }
nonisolated private struct ModelCatalogCache: Codable { let fetchedAt: Date; let models: [PickableModel] }

actor BackendModelCatalog {
    static let shared = BackendModelCatalog()

    private let key = "subscription.modelCatalog"
    private let ttl: TimeInterval = 24 * 60 * 60
    private var memory: ModelCatalogCache?

    func models(capability: AICapability, forceRefresh: Bool = false) async throws -> [PickableModel] {
        if !forceRefresh, let cache = currentCache(), Date().timeIntervalSince(cache.fetchedAt) < ttl {
            return cache.models.filter { $0.capability == capability.rawValue }
        }
        let response: ModelCatalogResponse = try await BackendClient.shared.get("api/v1/models")
        let cache = ModelCatalogCache(fetchedAt: Date(), models: response.models)
        memory = cache
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: key) }
        return response.models.filter { $0.capability == capability.rawValue }
    }

    private func currentCache() -> ModelCatalogCache? {
        if let memory { return memory }
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(ModelCatalogCache.self, from: data)
        else { return nil }
        memory = value
        return value
    }
}

@MainActor
enum AIModelPickerSource {
    static func models(
        capability: AICapability,
        config: AppConfig,
        forceRefresh: Bool = false
    ) async throws -> [PickableModel] {
        if config.usesSubscription {
            return try await BackendModelCatalog.shared.models(
                capability: capability,
                forceRefresh: forceRefresh
            )
        }
        switch capability {
        case .chat:
            return try await OpenAIModelsClient.shared.chatModels(
                endpoint: config.openAIEndpoint,
                apiKey: config.openAIKey,
                forceRefresh: forceRefresh
            ).map { PickableModel(id: $0.id, provider: "byok", displayName: $0.id, capability: capability.rawValue, estimate: nil) }
        case .image:
            return try await OpenAIModelsClient.shared.imageModels(
                endpoint: config.openAIEndpoint,
                apiKey: config.openAIKey,
                forceRefresh: forceRefresh
            ).map { PickableModel(id: $0.id, provider: "byok", displayName: $0.id, capability: capability.rawValue, estimate: nil) }
        case .transcription:
            return try await OpenAIModelsClient.shared.transcriptionModels(
                endpoint: config.openAIEndpoint,
                apiKey: config.openAIKey,
                forceRefresh: forceRefresh
            ).map { PickableModel(id: $0.id, provider: "byok", displayName: $0.id, capability: capability.rawValue, estimate: nil) }
        case .speech, .music:
            return []
        }
    }
}
