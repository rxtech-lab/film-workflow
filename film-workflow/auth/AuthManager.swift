import Foundation
import Observation
import OSLog
import RxAuthSwift

@Observable
@MainActor
final class AuthManager {
    static let shared = AuthManager()

    private let tokenStorage: any TokenStorageProtocol
    let oauthManager: OAuthManager?
    private let sessionClient: AuthSessionClient?
    private let refreshCredits: () async -> Void
    private let logger = Logger(subsystem: "rxlab.film-workflow", category: "Authentication")

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var restoreError: String?
    private var restorationPending: Bool
    private var restoredUser: User?

    private convenience init() {
        self.init(
            configuration: BackendConfig.hasOAuthConfiguration ? RxAuthConfiguration(
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
            ) : nil,
            tokenStorage: KeychainTokenStorage(serviceName: "com.rxlab.film-workflow.auth")
        )
    }

    init(configuration: RxAuthConfiguration?, tokenStorage: any TokenStorageProtocol,
         session: URLSession? = nil,
         refreshCredits: @escaping () async -> Void = { await CreditBalanceStore.shared.refresh() }) {
        self.tokenStorage = tokenStorage
        self.refreshCredits = refreshCredits
        restorationPending = configuration != nil
        oauthManager = configuration.map {
            OAuthManager(configuration: $0, tokenStorage: InteractiveAuthTokenStorage(storage: tokenStorage))
        }
        sessionClient = configuration.map { AuthSessionClient(configuration: $0, storage: tokenStorage, session: session) }
    }

    var authState: AuthenticationState {
        if restoredUser != nil || oauthManager?.authState == .authenticated { return .authenticated }
        return restorationPending ? .unknown : .unauthenticated
    }

    var isAuthenticated: Bool {
        if case .authenticated = authState { return true }
        return false
    }

    var isRestoring: Bool { restorationPending && !isAuthenticated }
    var currentUser: User? { restoredUser ?? oauthManager?.currentUser }
    var accessToken: String? { tokenStorage.getAccessToken() }

    private var restoreRetryTask: Task<Void, Never>?
    private var restoreAttempts = 0
    private var sessionGeneration = 0

    func checkExistingAuth() async {
        guard let sessionClient else {
            error = "RxLab sign-in is not configured (\(BackendConfig.diagnostics))."
            return
        }
        guard !isLoading, !isAuthenticated else { return }
        cancelRestoreRetry()
        isLoading = true
        restorationPending = true
        restoreError = nil
        let generation = sessionGeneration
        let started = ContinuousClock.now
        defer { if generation == sessionGeneration { isLoading = false } }
        do {
            let user = try await sessionClient.restore()
            guard generation == sessionGeneration else { return }
            restoredUser = user
            restorationPending = false
            restoreAttempts = 0
            error = nil
        } catch is CancellationError {
            return
        } catch AuthSessionClient.SessionError.rejected {
            guard generation == sessionGeneration else { return }
            await signOut()
            error = AuthSessionClient.SessionError.rejected.localizedDescription
            return
        } catch {
            guard generation == sessionGeneration else { return }
            // Keep the saved credentials and the restoring UI through outages.
            restoreError = error.localizedDescription
            logger.info("Account restoration deferred after \(String(describing: started.duration(to: .now)), privacy: .public)")
            scheduleRestoreRetry()
            return
        }
        if isAuthenticated {
            logger.info("Restored existing authentication session in \(String(describing: started.duration(to: .now)), privacy: .public)")
            isLoading = false
            await refreshCredits()
        }
    }

    /// Recover quickly when connectivity returns, without delaying for minutes.
    private func scheduleRestoreRetry() {
        restoreRetryTask?.cancel()
        let delay = min(2 * pow(2.0, Double(restoreAttempts)), 15)
        restoreAttempts = min(restoreAttempts + 1, 3)
        restoreRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isAuthenticated else { return }
            self.restoreRetryTask = nil
            await self.checkExistingAuth()
        }
    }

    private func cancelRestoreRetry() {
        restoreRetryTask?.cancel()
        restoreRetryTask = nil
    }

    func signIn() async {
        guard let oauthManager else {
            error = "RxLab sign-in is not configured."
            return
        }
        cancelRestoreRetry()
        sessionGeneration += 1
        sessionClient?.cancel()
        restorationPending = false
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await oauthManager.authenticate()
            await didSignIn()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func didSignIn() async {
        cancelRestoreRetry()
        sessionGeneration += 1
        sessionClient?.cancel()
        restorationPending = false
        restoredUser = nil
        restoreError = nil
        error = nil
        await refreshCredits()
    }

    func refreshAccessToken() async throws {
        guard let sessionClient else { throw BackendError.notSignedIn }
        let generation = sessionGeneration
        do {
            guard let user = try await sessionClient.restore(forceRefresh: true) else { throw BackendError.notSignedIn }
            guard generation == sessionGeneration else { throw CancellationError() }
            restoredUser = user
        } catch AuthSessionClient.SessionError.rejected {
            guard generation == sessionGeneration else { throw CancellationError() }
            await signOut()
            throw BackendError.notSignedIn
        }
    }

    func signOut() async {
        cancelRestoreRetry()
        sessionGeneration += 1
        sessionClient?.cancel()
        restorationPending = false
        restoredUser = nil
        restoreError = nil
        error = nil
        restoreAttempts = 0
        isLoading = true
        defer { isLoading = false }
        await oauthManager?.logout()
        CreditBalanceStore.shared.clear()
        MarketplaceAuthoringService.shared.clearAccess()
    }
}
