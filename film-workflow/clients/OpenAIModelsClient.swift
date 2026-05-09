import Foundation

enum OpenAIModelsError: LocalizedError {
    case missingConfig
    case invalidEndpoint
    case invalidResponse
    case apiError(String)
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "OpenAI endpoint or key is not configured. Set it in Settings."
        case .invalidEndpoint:
            return "OpenAI endpoint URL is invalid."
        case .invalidResponse:
            return "Invalid response from the OpenAI-compatible endpoint."
        case .apiError(let message):
            return "OpenAI error: \(message)"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP error: \(code)"
        }
    }
}

struct OpenAIModelInfo: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let type: String?
    let tags: [String]?

    var isImageModel: Bool {
        if let type, type.lowercased() == "image" { return true }
        if let tags, tags.contains(where: { $0.lowercased() == "image-generation" }) { return true }
        return false
    }
}

struct OpenAIModelsCacheEntry: Codable {
    let fetchedAt: Date
    let models: [OpenAIModelInfo]
}

actor OpenAIModelsClient {
    static let shared = OpenAIModelsClient()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let userDefaultsPrefix = "openai.modelsCache."

    private var memoryCache: [String: OpenAIModelsCacheEntry] = [:]

    private init() {}

    func models(
        endpoint: String,
        apiKey: String,
        forceRefresh: Bool = false
    ) async throws -> [OpenAIModelInfo] {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty, !trimmedKey.isEmpty else {
            throw OpenAIModelsError.missingConfig
        }

        let key = Self.cacheKey(endpoint: trimmedEndpoint, apiKey: trimmedKey)

        if !forceRefresh, let cached = currentCache(for: key), !Self.isExpired(cached) {
            return cached.models
        }

        let fresh = try await fetch(endpoint: trimmedEndpoint, apiKey: trimmedKey)
        let entry = OpenAIModelsCacheEntry(fetchedAt: Date(), models: fresh)
        memoryCache[key] = entry
        Self.persist(entry: entry, key: key)
        return fresh
    }

    func chatModels(
        endpoint: String,
        apiKey: String,
        forceRefresh: Bool = false
    ) async throws -> [OpenAIModelInfo] {
        let all = try await models(endpoint: endpoint, apiKey: apiKey, forceRefresh: forceRefresh)
        return all
            .filter { !$0.isImageModel }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    func imageModels(
        endpoint: String,
        apiKey: String,
        forceRefresh: Bool = false
    ) async throws -> [OpenAIModelInfo] {
        let all = try await models(endpoint: endpoint, apiKey: apiKey, forceRefresh: forceRefresh)
        return all
            .filter { $0.isImageModel }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Returns cached models without making a network call. Useful for synchronous UI prefill.
    nonisolated func cachedModels(endpoint: String, apiKey: String) -> [OpenAIModelInfo]? {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty, !trimmedKey.isEmpty else { return nil }
        let key = Self.cacheKey(endpoint: trimmedEndpoint, apiKey: trimmedKey)
        if let entry = Self.loadFromUserDefaults(key: key), !Self.isExpired(entry) {
            return entry.models
        }
        return nil
    }

    // MARK: - Private

    private func currentCache(for key: String) -> OpenAIModelsCacheEntry? {
        if let entry = memoryCache[key] { return entry }
        if let entry = Self.loadFromUserDefaults(key: key) {
            memoryCache[key] = entry
            return entry
        }
        return nil
    }

    private func fetch(endpoint: String, apiKey: String) async throws -> [OpenAIModelInfo] {
        let url = try Self.resolveModelsURL(from: endpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw OpenAIModelsError.apiError(message)
            }
            throw OpenAIModelsError.httpError(http.statusCode, bodyString)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIModelsError.invalidResponse
        }

        // Standard OpenAI shape: { "data": [...] }. Some gateways return the raw array.
        let rawList: [[String: Any]]
        if let dataArr = json["data"] as? [[String: Any]] {
            rawList = dataArr
        } else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            rawList = arr
        } else {
            throw OpenAIModelsError.invalidResponse
        }

        return rawList.compactMap { entry -> OpenAIModelInfo? in
            guard let id = entry["id"] as? String else { return nil }
            let type = entry["type"] as? String
            let tags = entry["tags"] as? [String]
            return OpenAIModelInfo(id: id, type: type, tags: tags)
        }
    }

    private static func resolveModelsURL(from endpoint: String) throws -> URL {
        var trimmed = endpoint
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        let candidate: String
        if trimmed.hasSuffix("/models") {
            candidate = trimmed
        } else if trimmed.hasSuffix("/v1") || trimmed.contains("/v1/") {
            candidate = trimmed + "/models"
        } else {
            candidate = trimmed + "/v1/models"
        }

        guard let url = URL(string: candidate) else {
            throw OpenAIModelsError.invalidEndpoint
        }
        return url
    }

    private static func isExpired(_ entry: OpenAIModelsCacheEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) > cacheTTL
    }

    private static func cacheKey(endpoint: String, apiKey: String) -> String {
        // Hash endpoint+apiKey so the cache is per-credential without persisting the key itself.
        let combined = endpoint + "|" + apiKey
        return String(combined.hashValue)
    }

    private static func userDefaultsKey(_ key: String) -> String {
        userDefaultsPrefix + key
    }

    private static func loadFromUserDefaults(key: String) -> OpenAIModelsCacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey(key)) else { return nil }
        return try? JSONDecoder().decode(OpenAIModelsCacheEntry.self, from: data)
    }

    private static func persist(entry: OpenAIModelsCacheEntry, key: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey(key))
    }
}
