import Foundation

/// The two calls the marketplace needs from the backend, so a test can hand
/// the client canned responses instead of a network.
protocol MarketplaceTransport: Sendable {
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response
    func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, idempotencyKey: String?) async throws -> Response
}

extension BackendClient: MarketplaceTransport {}

nonisolated struct MarketplaceEmptyBody: Encodable {}

/// Thin wrapper over `api/v1/marketplace/*`.
///
/// The catalog itself is public: when there is no account, `items` falls back
/// to an anonymous request so a signed-out user can still browse.
actor MarketplaceClient {
    private let transport: any MarketplaceTransport

    init(transport: any MarketplaceTransport = BackendClient.shared) {
        self.transport = transport
    }

    func items(kind: MarketplaceKind?, category: String?, query: String, page: Int) async throws -> MarketplaceCatalogPage {
        var parameters: [URLQueryItem] = [URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: "catalog_version", value: "2")]
        if let kind { parameters.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        if let category, !category.isEmpty { parameters.append(URLQueryItem(name: "category", value: category)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parameters.append(URLQueryItem(name: "q", value: String(trimmed.prefix(100)))) }
        do {
            return try await transport.get("api/v1/marketplace/items", query: parameters)
        } catch BackendError.notSignedIn {
            return try await Self.anonymousGet("api/v1/marketplace/items", query: parameters)
        }
    }

    /// The sidebar: kinds with their labels and symbols, categories with theirs.
    /// Public like the catalog, so a signed-out browse still gets it.
    func taxonomy() async throws -> MarketplaceTaxonomy {
        let parameters = [URLQueryItem(name: "catalog_version", value: "2")]
        do {
            return try await transport.get("api/v1/marketplace/taxonomy", query: parameters)
        } catch BackendError.notSignedIn {
            return try await Self.anonymousGet("api/v1/marketplace/taxonomy", query: parameters)
        }
    }

    func item(_ id: String) async throws -> MarketplaceItem {
        do {
            return try await transport.get("api/v1/marketplace/items/\(id)", query: [])
        } catch BackendError.notSignedIn {
            return try await Self.anonymousGet("api/v1/marketplace/items/\(id)", query: [])
        }
    }

    func purchase(_ id: String) async throws -> MarketplacePurchaseResponse {
        try await transport.post("api/v1/marketplace/items/\(id)/purchase", body: MarketplaceEmptyBody(), idempotencyKey: "marketplace:\(id)")
    }

    /// Short-lived; call it right before downloading, never ahead of time.
    func downloadURL(_ id: String) async throws -> MarketplaceDownloadResponse {
        try await transport.get("api/v1/marketplace/items/\(id)/download", query: [])
    }

    func purchases() async throws -> [MarketplacePurchaseRecord] {
        let response: MarketplacePurchasesResponse = try await transport.get("api/v1/marketplace/purchases", query: [URLQueryItem(name: "catalog_version", value: "2")])
        return response.purchases
    }

    // MARK: - Anonymous access

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func anonymousGet<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        var url = BackendConfig.apiBaseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.server(0, nil) }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(ErrorPayload.self, from: data)
            if (400..<500).contains(http.statusCode) { throw BackendError.badRequest(payload?.error ?? "The request was rejected.") }
            throw BackendError.server(http.statusCode, payload?.error)
        }
        do { return try decoder.decode(Response.self, from: data) } catch { throw BackendError.decoding(error) }
    }

    private struct ErrorPayload: Decodable { let code: String?; let error: String? }
}
