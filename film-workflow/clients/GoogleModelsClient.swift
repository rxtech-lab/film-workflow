import Foundation

enum GoogleModelsError: LocalizedError {
    case missingConfig
    case invalidResponse
    case apiError(String)
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Google AI API key is not configured. Set it in Settings."
        case .invalidResponse:
            return "Invalid response from the Gemini models endpoint."
        case .apiError(let message):
            return "Google error: \(message)"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            }
            return "HTTP error: \(code)"
        }
    }
}

struct GoogleModelInfo: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let supportedGenerationMethods: [String]

    var supportsImagenPredict: Bool {
        id.lowercased().contains("imagen")
            && supportedGenerationMethods.contains("predict")
    }
}

struct GoogleModelsCacheEntry: Codable {
    let fetchedAt: Date
    let models: [GoogleModelInfo]
}

actor GoogleModelsClient {
    static let shared = GoogleModelsClient()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let userDefaultsPrefix = "google.modelsCache."
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    private var memoryCache: [String: GoogleModelsCacheEntry] = [:]

    private init() {}

    func models(apiKey: String, forceRefresh: Bool = false) async throws -> [GoogleModelInfo] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GoogleModelsError.missingConfig }

        let key = Self.cacheKey(apiKey: trimmedKey)

        if !forceRefresh, let cached = currentCache(for: key), !Self.isExpired(cached) {
            return cached.models
        }

        let fresh = try await fetch(apiKey: trimmedKey)
        let entry = GoogleModelsCacheEntry(fetchedAt: Date(), models: fresh)
        memoryCache[key] = entry
        Self.persist(entry: entry, key: key)
        return fresh
    }

    func imagenModels(apiKey: String, forceRefresh: Bool = false) async throws -> [GoogleModelInfo] {
        let all = try await models(apiKey: apiKey, forceRefresh: forceRefresh)
        return all
            .filter { $0.supportsImagenPredict }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    // MARK: - Private

    private func currentCache(for key: String) -> GoogleModelsCacheEntry? {
        if let entry = memoryCache[key] { return entry }
        if let entry = Self.loadFromUserDefaults(key: key) {
            memoryCache[key] = entry
            return entry
        }
        return nil
    }

    private func fetch(apiKey: String) async throws -> [GoogleModelInfo] {
        guard let url = URL(string: Self.endpoint) else {
            throw GoogleModelsError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw GoogleModelsError.apiError(message)
            }
            throw GoogleModelsError.httpError(http.statusCode, bodyString)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawList = json["models"] as? [[String: Any]] else {
            throw GoogleModelsError.invalidResponse
        }

        return rawList.compactMap { entry -> GoogleModelInfo? in
            guard let rawName = entry["name"] as? String else { return nil }
            let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            let methods = (entry["supportedGenerationMethods"] as? [String]) ?? []
            return GoogleModelInfo(id: id, supportedGenerationMethods: methods)
        }
    }

    private static func isExpired(_ entry: GoogleModelsCacheEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) > cacheTTL
    }

    private static func cacheKey(apiKey: String) -> String {
        String(apiKey.hashValue)
    }

    private static func userDefaultsKey(_ key: String) -> String {
        userDefaultsPrefix + key
    }

    private static func loadFromUserDefaults(key: String) -> GoogleModelsCacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey(key)) else { return nil }
        return try? JSONDecoder().decode(GoogleModelsCacheEntry.self, from: data)
    }

    private static func persist(entry: GoogleModelsCacheEntry, key: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey(key))
    }
}
