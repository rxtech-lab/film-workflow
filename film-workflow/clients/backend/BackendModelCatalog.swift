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
    /// The server catalog tracks the live gateway list, so a day-old snapshot
    /// hides models that already exist. Short enough to pick new ones up on the
    /// next visit, long enough that reopening a picker isn't a round trip.
    private let ttl: TimeInterval = 60 * 60
    private var memory: ModelCatalogCache?
    private var inFlight: Task<[PickableModel], Error>?

    func models(capability: AICapability, forceRefresh: Bool = false) async throws -> [PickableModel] {
        let cache = currentCache()
        if !forceRefresh, let cache, Date().timeIntervalSince(cache.fetchedAt) < ttl {
            return cache.models.filter { $0.capability == capability.rawValue }
        }
        do {
            return try await fetch().filter { $0.capability == capability.rawValue }
        } catch {
            // A failed refresh must not empty a picker that already has a list.
            guard let cache else { throw error }
            return cache.models.filter { $0.capability == capability.rawValue }
        }
    }

    /// One request however many capabilities ask at once — the settings pane
    /// loads chat, image and transcription in parallel off a single catalog.
    private func fetch() async throws -> [PickableModel] {
        if let inFlight { return try await inFlight.value }
        let task = Task {
            let response: ModelCatalogResponse = try await BackendClient.shared.get("api/v1/models")
            return response.models
        }
        inFlight = task
        defer { inFlight = nil }
        let models = try await task.value
        let cache = ModelCatalogCache(fetchedAt: Date(), models: models)
        memory = cache
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: key) }
        return models
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
