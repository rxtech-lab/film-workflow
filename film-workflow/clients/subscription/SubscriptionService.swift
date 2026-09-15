import Foundation
import RxAuthSwift
import RxSubscriptionIOS

/// Builds the RxSubscription client the paywall, plan catalog and top-ups run on.
///
/// The client is publishable-key based: the key ships in the binary and proves
/// nothing by itself, so every request also carries the signed-in user's access
/// token. `rxlabUserID` is baked in at init, which is why the built client is
/// cached against the user it was built for and dropped when that changes —
/// otherwise the next account's requests would go out under the previous
/// account's id and be refused server-side.
@MainActor
final class SubscriptionService {
    static let shared = SubscriptionService()

    private let session: URLSession
    private var cached: (userID: String, client: Client)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool { BackendConfig.hasSubscriptionConfiguration }

    /// `nil` when the app has no publishable key, or nobody is signed in.
    /// Callers treat that as "subscription features are unavailable" rather
    /// than as an error: the app predates this service and still works without
    /// it.
    func client() -> Client? {
        guard isConfigured,
              let user = AuthManager.shared.currentUser,
              !user.id.isEmpty else { return nil }
        if let cached, cached.userID == user.id { return cached.client }
        let client = Client(
            serverURL: BackendConfig.subscriptionURL,
            publishableKey: BackendConfig.subscriptionPublishableKey,
            rxlabUserID: user.id,
            email: user.email,
            displayName: user.name,
            userToken: { forceRefresh in
                try await Self.accessToken(forceRefresh: forceRefresh)
            },
            session: session
        )
        cached = (user.id, client)
        return client
    }

    /// Drops the cached client so the next call rebuilds it. Called on sign-out.
    func invalidate() {
        cached = nil
    }

    /// The token provider handed to `Client`. It is `@Sendable` and
    /// nonisolated, so it hops to the main actor to reach `AuthManager`.
    /// `forceRefresh` is the client telling us a 401 came back, which is
    /// exactly what `refreshAccessToken()` already handles for `BackendClient`.
    @MainActor
    private static func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh {
            try await AuthManager.shared.refreshAccessToken()
        }
        guard let token = AuthManager.shared.accessToken, !token.isEmpty else {
            throw BackendError.notSignedIn
        }
        return token
    }
}
