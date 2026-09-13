import Foundation
import Observation
import OSLog
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SubscriptionUser: Codable, Sendable {
    let id: String
    let name: String
    let email: String
}

struct BillingSnapshot: Codable, Sendable {
    let enabled: Bool
    let balancePoints: Int
    let reservedPoints: Int
    let availablePoints: Int
    let pointsPerUsd: Int
}

struct AccountSnapshot: Codable, Sendable {
    struct URLs: Codable, Sendable { let credits: String; let usage: String }
    let user: SubscriptionUser
    let billing: BillingSnapshot
    let urls: URLs
}

@Observable
@MainActor
final class CreditBalanceStore {
    static let shared = CreditBalanceStore()

    private(set) var availablePoints = 0
    private(set) var reservedPoints = 0
    private(set) var balancePoints = 0
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var error: String?

    private let isAuthenticated: @MainActor () -> Bool
    private let loadAccount: @MainActor () async throws -> AccountSnapshot
    private let logger = Logger(subsystem: "rxlab.film-workflow", category: "AccountBalance")

    init(isAuthenticated: @escaping @MainActor () -> Bool = { AuthManager.shared.isAuthenticated },
         loadAccount: @escaping @MainActor () async throws -> AccountSnapshot = {
             try await BackendClient.shared.get("api/v1/me")
         }) {
        self.isAuthenticated = isAuthenticated
        self.loadAccount = loadAccount
    }

    var isSignedIn: Bool { isAuthenticated() }

    func refresh() async {
        guard isSignedIn else { clear(); return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try Task.checkCancellation()
            logger.debug("Refreshing account balance: GET \(BackendConfig.apiBaseURL.absoluteString, privacy: .public)/api/v1/me")
            let snapshot = try await loadAccount()
            try Task.checkCancellation()
            apply(snapshot.billing)
        } catch is CancellationError {
            logger.debug("Account balance refresh cancelled")
        } catch let error as URLError where error.code == .cancelled {
            logger.debug("Account balance request cancelled (NSURLErrorDomain -999)")
        } catch {
            let failure = error as NSError
            logger.error("Account balance refresh failed: \(failure.domain, privacy: .public) \(failure.code)")
            self.error = error.localizedDescription
        }
    }

    func apply(_ snapshot: BillingSnapshot) {
        balancePoints = snapshot.balancePoints
        reservedPoints = snapshot.reservedPoints
        availablePoints = snapshot.availablePoints
        lastUpdated = Date()
    }

    func apply(available: Int) {
        availablePoints = available
        lastUpdated = Date()
    }

    func clear() {
        balancePoints = 0
        reservedPoints = 0
        availablePoints = 0
        lastUpdated = nil
        error = nil
    }

    func openTopUp() {
        let url = BackendConfig.webBaseURL.appending(path: "credits").appending(queryItems: [URLQueryItem(name: "app", value: "1")])
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        // App Store builds may use existing credits but must not link to an
        // external purchase flow. Keep purchase navigation macOS-only.
        _ = url
        #endif
    }
}
