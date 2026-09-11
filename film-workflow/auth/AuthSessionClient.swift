import Foundation
import RxAuthSwift

/// Restores and refreshes the saved session without treating a transport or
/// server failure as a revoked login. RxAuthSwift 1.2.1 clears tokens for both.
@MainActor
final class AuthSessionClient {
    enum SessionError: LocalizedError {
        case rejected
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .rejected: String(localized: "Your session expired. Please sign in again.")
            case .server(let status): "Account service returned HTTP \(status)."
            }
        }
    }

    private let configuration: RxAuthConfiguration
    private let storage: any TokenStorageProtocol
    private let session: URLSession
    private var pending: (id: UUID, task: Task<User?, Error>)?

    init(configuration: RxAuthConfiguration, storage: any TokenStorageProtocol, session: URLSession? = nil) {
        self.configuration = configuration
        self.storage = storage
        if let session {
            self.session = session
        } else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 10
            settings.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: settings)
        }
    }

    func restore(forceRefresh: Bool = false) async throws -> User? {
        if let pending { return try await pending.task.value }
        let id = UUID()
        let task = Task { try await self.loadUser(forceRefresh: forceRefresh) }
        pending = (id, task)
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
    }

    private func loadUser(forceRefresh: Bool) async throws -> User? {
        guard storage.getAccessToken() != nil || storage.getRefreshToken() != nil else { return nil }
        var refreshed = false
        if forceRefresh || storage.getAccessToken() == nil || (storage.getExpiresAt()?.timeIntervalSinceNow ?? 0) <= 30 {
            try await refreshTokens()
            refreshed = true
        }
        do {
            return try await fetchUser()
        } catch SessionError.rejected where !refreshed && storage.getRefreshToken() != nil {
            // A server can reject a token before its locally recorded expiry.
            try await refreshTokens()
            return try await fetchUser()
        }
    }

    private func refreshTokens() async throws {
        guard let refreshToken = storage.getRefreshToken() else { throw SessionError.rejected }
        guard let url = configuration.tokenURL else { throw OAuthError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", configuration.clientID),
        ].map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(TokenFailure.self, from: data)
            if [400, 401].contains(response.statusCode), failure?.error == "invalid_grant" {
                throw SessionError.rejected
            }
            throw SessionError.server(response.statusCode)
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !tokens.accessToken.isEmpty else { throw OAuthError.tokenRefreshFailed("Empty access token") }
        // Save a rotated refresh token before fetching the profile, so a
        // profile outage cannot discard the only usable refresh credential.
        if let refreshToken = tokens.refreshToken { try storage.saveRefreshToken(refreshToken) }
        try storage.saveAccessToken(tokens.accessToken)
        try storage.saveExpiresAt(tokens.expiresIn.map { Date().addingTimeInterval($0) } ?? .distantPast)
    }

    private func fetchUser() async throws -> User {
        guard let token = storage.getAccessToken(), let url = configuration.userInfoURL else {
            throw SessionError.rejected
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        if response.statusCode == 401 { throw SessionError.rejected }
        guard response.statusCode == 200 else { throw SessionError.server(response.statusCode) }
        return try JSONDecoder().decode(User.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        // A sign-out may have cancelled restoration while the response arrived.
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    private struct TokenFailure: Decodable { let error: String }
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }
}

/// Interactive sign-in still uses RxAuthSwift. The app owns refreshes so the
/// SDK's private timer cannot delete the saved login after an HTTP 5xx error.
nonisolated final class InteractiveAuthTokenStorage: TokenStorageProtocol {
    private let storage: any TokenStorageProtocol
    init(storage: any TokenStorageProtocol) { self.storage = storage }
    func saveAccessToken(_ token: String) throws { try storage.saveAccessToken(token) }
    func getAccessToken() -> String? { storage.getAccessToken() }
    func deleteAccessToken() throws { try storage.deleteAccessToken() }
    func saveRefreshToken(_ token: String) throws { try storage.saveRefreshToken(token) }
    func getRefreshToken() -> String? { nil }
    func deleteRefreshToken() throws { try storage.deleteRefreshToken() }
    func saveExpiresAt(_ date: Date) throws { try storage.saveExpiresAt(date) }
    func getExpiresAt() -> Date? { storage.getExpiresAt() }
    func isTokenExpired() -> Bool { storage.isTokenExpired() }
    func clearAll() throws { try storage.clearAll() }
}
