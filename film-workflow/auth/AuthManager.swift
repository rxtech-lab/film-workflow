import Foundation
import Observation
import RxAuthSwift

@Observable
@MainActor
final class AuthManager {
    static let shared = AuthManager()

    private let tokenStorage = KeychainTokenStorage(serviceName: "com.rxlab.film-workflow.auth")
    let oauthManager: OAuthManager?

    private(set) var isLoading = false
    private(set) var error: String?

    private init() {
        guard BackendConfig.hasOAuthConfiguration else {
            oauthManager = nil
            return
        }
        oauthManager = OAuthManager(
            configuration: RxAuthConfiguration(
                issuer: BackendConfig.oidcIssuer,
                clientID: BackendConfig.clientID,
                redirectURI: BackendConfig.redirectURI,
                scopes: BackendConfig.scopes,
                // Without these paths every passkey capability flag on
                // OAuthManager stays false and the SDK reports "Passkey sign in
                // is not configured for this app".
                passkeyChallengePath: "/api/oauth/passkey/authenticate/options",
                passkeyVerificationPath: "/api/oauth/passkey/authenticate/verify",
                passkeyRegistrationChallengePath: "/api/oauth/passkey/register/options",
                passkeyRegistrationVerificationPath: "/api/oauth/passkey/register/verify",
                passkeyUpgradeChallengePath: "/api/oauth/passkey/upgrade/options",
                passkeyUpgradeVerificationPath: "/api/oauth/passkey/upgrade/verify",
                passkeyAccountCreationOptionsPath: "/api/oauth/passkey/account-creation/options",
                passkeyAccountCreationVerifyPath: "/api/oauth/passkey/account-creation/verify",
                // Must match the `webcredentials:rxlab.app` entitlement and the
                // AASA served at https://rxlab.app/.well-known/apple-app-site-association.
                // Pinned rather than left nil: the SDK would otherwise fall back
                // to the issuer host (auth.rxlab.app), which the AASA does not
                // cover, and every assertion would fail.
                passkeyRelyingPartyIdentifier: "rxlab.app",
                keychainServiceName: "com.rxlab.film-workflow.auth"
            ),
            tokenStorage: tokenStorage
        )
    }

    var authState: AuthenticationState {
        oauthManager?.authState ?? .unauthenticated
    }

    var isAuthenticated: Bool {
        if case .authenticated = authState { return true }
        return false
    }

    var currentUser: User? { oauthManager?.currentUser }
    var accessToken: String? { tokenStorage.getAccessToken() }

    func checkExistingAuth() async {
        guard let oauthManager else {
            error = "RxLab sign-in is not configured (\(BackendConfig.diagnostics))."
            return
        }
        isLoading = true
        defer { isLoading = false }
        await oauthManager.checkExistingAuth()
        if isAuthenticated {
            await CreditBalanceStore.shared.refresh()
        }
    }

    func signIn() async {
        guard let oauthManager else {
            error = "RxLab sign-in is not configured."
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await oauthManager.authenticate()
            await CreditBalanceStore.shared.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshAccessToken() async throws {
        guard let oauthManager else { throw BackendError.notSignedIn }
        try await oauthManager.refreshTokenIfNeeded()
    }

    func signOut() async {
        isLoading = true
        defer { isLoading = false }
        await oauthManager?.logout()
        CreditBalanceStore.shared.clear()
    }
}
