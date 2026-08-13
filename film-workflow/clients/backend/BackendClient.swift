import Foundation

actor BackendClient {
    static let shared = BackendClient()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send(path: path, method: "GET", body: nil, query: query)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        try await send(
            path: path,
            method: "POST",
            body: try encoder.encode(body),
            idempotencyKey: idempotencyKey
        )
    }

    func data(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Data {
        try await perform(
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            idempotencyKey: idempotencyKey,
            retryingAuth: true
        )
    }

    func upload(
        _ path: String,
        fromFile fileURL: URL,
        contentType: String,
        idempotencyKey: String? = nil
    ) async throws -> Data {
        try await performUpload(
            path: path,
            fileURL: fileURL,
            contentType: contentType,
            idempotencyKey: idempotencyKey,
            retryingAuth: true
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        query: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> Response {
        let data = try await perform(
            path: path,
            method: method,
            body: body,
            query: query,
            contentType: body == nil ? nil : "application/json",
            idempotencyKey: idempotencyKey,
            retryingAuth: true
        )
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw BackendError.decoding(error) }
    }

    private func perform(
        path: String,
        method: String,
        body: Data?,
        query: [URLQueryItem] = [],
        contentType: String?,
        idempotencyKey: String?,
        retryingAuth: Bool
    ) async throws -> Data {
        guard let token = await AuthManager.shared.accessToken, !token.isEmpty else {
            throw BackendError.notSignedIn
        }
        var url = BackendConfig.apiBaseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.platform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(Self.appVersion, forHTTPHeaderField: "X-Client-Version")
        request.setValue(Self.deviceID, forHTTPHeaderField: "X-Client-Device-Id")
        request.setValue(ProcessInfo.processInfo.hostName, forHTTPHeaderField: "X-Client-Device-Name")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.server(0, nil) }
        if http.statusCode == 401, retryingAuth {
            do { try await AuthManager.shared.refreshAccessToken() }
            catch { throw BackendError.unauthorized }
            return try await perform(path: path, method: method, body: body, query: query, contentType: contentType, idempotencyKey: idempotencyKey, retryingAuth: false)
        }
        if http.statusCode == 402 {
            let payload = try? decoder.decode(CreditErrorPayload.self, from: data)
            throw BackendError.insufficientCredits(
                available: payload?.availablePoints ?? 0,
                required: payload?.requiredPoints ?? 0,
                creditsURL: payload?.creditsUrl.flatMap { URL(string: $0, relativeTo: BackendConfig.webBaseURL) }
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(ErrorPayload.self, from: data)
            if payload?.code == "price_not_found" { throw BackendError.priceUnavailable(payload?.error ?? "model") }
            if (400..<500).contains(http.statusCode) { throw BackendError.badRequest(payload?.error ?? "The request was rejected.") }
            throw BackendError.server(http.statusCode, payload?.error)
        }
        return data
    }

    private func performUpload(
        path: String,
        fileURL: URL,
        contentType: String,
        idempotencyKey: String?,
        retryingAuth: Bool
    ) async throws -> Data {
        guard let token = await AuthManager.shared.accessToken, !token.isEmpty else {
            throw BackendError.notSignedIn
        }
        let url = BackendConfig.apiBaseURL.appending(
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 * 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.platform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(Self.appVersion, forHTTPHeaderField: "X-Client-Version")
        request.setValue(Self.deviceID, forHTTPHeaderField: "X-Client-Device-Id")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else { throw BackendError.server(0, nil) }
        if http.statusCode == 401, retryingAuth {
            do { try await AuthManager.shared.refreshAccessToken() }
            catch { throw BackendError.unauthorized }
            return try await performUpload(
                path: path,
                fileURL: fileURL,
                contentType: contentType,
                idempotencyKey: idempotencyKey,
                retryingAuth: false
            )
        }
        try validate(data: data, response: http)
        return data
    }

    private func validate(data: Data, response http: HTTPURLResponse) throws {
        if http.statusCode == 402 {
            let payload = try? decoder.decode(CreditErrorPayload.self, from: data)
            throw BackendError.insufficientCredits(
                available: payload?.availablePoints ?? 0,
                required: payload?.requiredPoints ?? 0,
                creditsURL: payload?.creditsUrl.flatMap { URL(string: $0, relativeTo: BackendConfig.webBaseURL) }
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(ErrorPayload.self, from: data)
            if payload?.code == "price_not_found" {
                throw BackendError.priceUnavailable(payload?.error ?? "model")
            }
            if (400..<500).contains(http.statusCode) {
                throw BackendError.badRequest(payload?.error ?? "The request was rejected.")
            }
            throw BackendError.server(http.statusCode, payload?.error)
        }
    }

    private struct ErrorPayload: Decodable { let code: String?; let error: String? }
    private struct CreditErrorPayload: Decodable {
        let availablePoints: Int
        let requiredPoints: Int
        let creditsUrl: String?
    }

    private static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static var deviceID: String {
        let key = "subscription.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
