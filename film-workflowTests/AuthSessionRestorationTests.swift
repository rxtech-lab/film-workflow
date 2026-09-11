import AppKit
import Foundation
import SwiftUI
import RxAuthSwift
import Testing
@testable import film_workflow

@Suite(.serialized)
@MainActor
struct AuthSessionRestorationTests {
    private let configuration = RxAuthConfiguration(
        issuer: "https://auth.session.test", clientID: "test-client", redirectURI: "filmstudio://callback"
    )

    @Test("A temporary refresh failure preserves the session across restart")
    func offlineRestartPreservesTokens() async throws {
        let storage = InMemoryTokenStorage()
        try storage.saveAccessToken("test-access")
        try storage.saveRefreshToken("test-refresh")
        try storage.saveExpiresAt(.distantPast)
        AuthSessionURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let manager = makeManager(storage: storage)

        await manager.checkExistingAuth()

        #expect(storage.getAccessToken() == "test-access")
        #expect(storage.getRefreshToken() == "test-refresh")
        #expect(manager.isRestoring)
        #expect(!manager.isAuthenticated)

        // Relaunch against the same durable storage after the network returns.
        let restarted = makeManager(storage: storage)
        AuthSessionURLProtocol.handler = successfulResponse
        await restarted.checkExistingAuth()
        #expect(restarted.isAuthenticated)
        #expect(restarted.currentUser?.id == "test-user")
        await manager.signOut()
        await restarted.signOut()
    }

    private func makeManager(storage: InMemoryTokenStorage) -> AuthManager {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [AuthSessionURLProtocol.self]
        return AuthManager(configuration: configuration, tokenStorage: storage,
                           session: URLSession(configuration: settings), refreshCredits: {})
    }

    private func savedSession(expired: Bool = false) throws -> InMemoryTokenStorage {
        let storage = InMemoryTokenStorage()
        try storage.saveAccessToken("test-access")
        try storage.saveRefreshToken("test-refresh")
        try storage.saveExpiresAt(expired ? .distantPast : Date().addingTimeInterval(3600))
        return storage
    }

    nonisolated private func successfulResponse(_ request: URLRequest) throws -> (Int, String) {
        if request.url?.path == "/api/oauth/token" {
            return (200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
        }
        return (200, #"{"sub":"test-user","name":"Test Account"}"#)
    }

    @Test("Valid saved credentials restore with only one bounded profile request")
    func validSessionSkipsPreflightAndRefresh() async throws {
        let storage = try savedSession()
        // The SDK considers a token expired ten minutes early; this one still
        // has five minutes left and should restore without a token exchange.
        try storage.saveExpiresAt(Date().addingTimeInterval(300))
        let requests = RequestRecorder()
        AuthSessionURLProtocol.handler = { request in
            requests.append(request)
            return try successfulResponse(request)
        }
        let manager = makeManager(storage: storage)
        #expect(manager.isRestoring)
        await manager.checkExistingAuth()
        #expect(manager.isAuthenticated)
        #expect(!manager.isRestoring)
        #expect(requests.values.map { $0.url!.path } == ["/api/oauth/userinfo"])
        #expect(requests.values.allSatisfy { $0.timeoutInterval <= 10 })
        #expect(storage.getRefreshToken() == "test-refresh")
        await manager.signOut()
    }

    @Test("Timeouts, rate limits, server errors, and client configuration errors retain credentials",
          arguments: [0, 429, 500, 503, 401])
    func transientErrorsPreserveSession(status: Int) async throws {
        let storage = try savedSession(expired: true)
        AuthSessionURLProtocol.handler = { _ in
            if status == 0 { throw URLError(.timedOut) }
            return (status, #"{"error":"invalid_client"}"#)
        }
        let manager = makeManager(storage: storage)
        await manager.checkExistingAuth()
        #expect(storage.getRefreshToken() == "test-refresh")
        #expect(manager.isRestoring)
        #expect(manager.restoreError != nil)
        await manager.signOut()
    }

    @Test("A revoked refresh token ends restoration and requires sign-in")
    func rejectedSessionIsCleared() async throws {
        let storage = try savedSession(expired: true)
        AuthSessionURLProtocol.handler = { _ in (400, #"{"error":"invalid_grant"}"#) }
        let manager = makeManager(storage: storage)
        await manager.checkExistingAuth()
        #expect(!manager.isRestoring)
        #expect(!manager.isAuthenticated)
        #expect(storage.getAccessToken() == nil)
        #expect(storage.getRefreshToken() == nil)
        #expect(manager.error != nil)
    }

    @Test("An early access-token rejection refreshes once and restores the account")
    func rejectedAccessTokenRefreshes() async throws {
        let storage = try savedSession()
        let requests = RequestRecorder()
        AuthSessionURLProtocol.handler = { request in
            requests.append(request)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access" { return (401, "{}") }
            return try successfulResponse(request)
        }
        let manager = makeManager(storage: storage)
        await manager.checkExistingAuth()
        #expect(manager.isAuthenticated)
        #expect(requests.values.map { $0.url!.path } == ["/api/oauth/userinfo", "/api/oauth/token", "/api/oauth/userinfo"])
        await manager.signOut()
    }

    @Test("A profile failure retains rotated credentials for the next restore")
    func profileFailureAfterRotation() async throws {
        let storage = try savedSession(expired: true)
        AuthSessionURLProtocol.handler = { request in
            if request.url?.path == "/api/oauth/userinfo" { throw URLError(.timedOut) }
            return try successfulResponse(request)
        }
        let manager = makeManager(storage: storage)
        await manager.checkExistingAuth()
        #expect(storage.getRefreshToken() == "new-refresh")
        #expect(manager.isRestoring)
        AuthSessionURLProtocol.handler = successfulResponse
        await manager.checkExistingAuth()
        #expect(manager.isAuthenticated)
        await manager.signOut()
    }

    @Test("A fresh installation becomes signed out without any network request")
    func noStoredSession() async {
        AuthSessionURLProtocol.handler = { _ in
            Issue.record("No request should be made without saved credentials")
            throw URLError(.badURL)
        }
        let manager = makeManager(storage: InMemoryTokenStorage())
        await manager.checkExistingAuth()
        #expect(!manager.isRestoring)
        #expect(!manager.isAuthenticated)
        #expect(manager.error == nil)
    }

    @Test("The SDK cannot independently refresh and erase the app's credentials")
    func sdkRefreshIsDisabled() async throws {
        let storage = try savedSession()
        let adapter = InteractiveAuthTokenStorage(storage: storage)
        let sdk = OAuthManager(configuration: configuration, tokenStorage: adapter)
        await #expect(throws: OAuthError.self) { try await sdk.refreshTokenIfNeeded() }
        #expect(storage.getRefreshToken() == "test-refresh")
        // New interactive credentials still persist to the original storage.
        try adapter.saveRefreshToken("signed-in-refresh")
        #expect(storage.getRefreshToken() == "signed-in-refresh")
        await sdk.logout()
        #expect(storage.getRefreshToken() == nil)
    }

    @Test("Sign-out during a delayed restore cannot revive the account")
    func signOutCancelsRestore() async throws {
        let storage = try savedSession(expired: true)
        let requests = RequestRecorder()
        AuthSessionURLProtocol.handler = { request in
            requests.append(request)
            Thread.sleep(forTimeInterval: 0.3)
            return try successfulResponse(request)
        }
        let manager = makeManager(storage: storage)
        let restore = Task { await manager.checkExistingAuth() }
        for _ in 0..<100 where requests.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!requests.values.isEmpty)
        await manager.signOut()
        await restore.value
        #expect(!manager.isAuthenticated)
        #expect(!manager.isRestoring)
        #expect(manager.restoreError == nil)
        #expect(storage.getAccessToken() == nil)
        #expect(storage.getRefreshToken() == nil)
    }

    @Test("Concurrent refresh requests share one token rotation")
    func concurrentRefreshes() async throws {
        let storage = try savedSession()
        let requests = RequestRecorder()
        AuthSessionURLProtocol.handler = { request in
            requests.append(request)
            return try successfulResponse(request)
        }
        let manager = makeManager(storage: storage)
        async let first: Void = manager.refreshAccessToken()
        async let second: Void = manager.refreshAccessToken()
        try await first
        try await second
        #expect(requests.values.filter { $0.url?.path == "/api/oauth/token" }.count == 1)
        await manager.signOut()
    }

    @Test("The account control displays restoration, then the restored account")
    func accountControlRestorationUI() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let storage = try savedSession()
        AuthSessionURLProtocol.handler = successfulResponse
        let manager = makeManager(storage: storage)
        let host = NSHostingView(rootView: AccountControl(placement: .sidebarFooter, auth: manager))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func labels() -> [String] {
            hostedAccessibilityDescendants(host).flatMap {
                [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 }
            }
        }
        func savePreview(_ name: String) throws {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/film-auth-\(name).png"))
        }
        try savePreview("restoring")
        let restoringLabel = String(localized: "Restoring account…")
        #expect(labels().contains { $0.contains(restoringLabel) }, "Accessibility text: \(labels())")
        #expect(!labels().contains { $0 == String(localized: "Sign in") })
        await manager.checkExistingAuth()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        try savePreview("restored")
        #expect(labels().contains { $0.contains("Test Account") }, "Accessibility text: \(labels())")
        #expect(!labels().contains { $0.contains(restoringLabel) })
        await manager.signOut()
    }
}

private final class AuthSessionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "auth.session.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { requests } }
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}
