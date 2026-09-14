import Foundation
import Observation
import OSLog
import RxSubscriptionIOS

/// The app's view of the signed-in user's subscription: which plan they hold,
/// and which top-up packs they can buy.
///
/// Credits are deliberately *not* owned here. `CreditBalanceStore` stays the
/// single source of truth for the balance shown in the toolbar and inspectors,
/// read from the film backend's `api/v1/me`. This store answers only "is there
/// an active plan" and "what is on sale", so the two can never disagree on
/// screen.
@Observable
@MainActor
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    /// What we currently know, as distinct from what we currently show.
    /// `unknown` is the important one: it means the question has not been
    /// answered, which is very different from having been answered "no".
    enum Availability: Equatable {
        /// No publishable key, or nobody signed in. Subscription features off.
        case unconfigured
        /// Never fetched, or the last fetch failed. Not an answer.
        case unknown
        case entitled
        case notEntitled
    }

    /// The statuses rx-subscription treats as a live subscription. Mirrors the
    /// package's own check in `StoreKitSupport.purchaseApple`.
    nonisolated static let activeStatuses: Set<String> = ["active", "trialing"]

    private(set) var entitlements: Entitlements?
    private(set) var catalog: Catalog?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    /// Whether there is a client to ask at all. A `nil` from the loader means
    /// no key or nobody signed in; a thrown error means there *was* a client
    /// and the request failed — which is a very different situation, and the
    /// one the gate's fail-open branch exists for.
    private(set) var isConfigured = false

    private let loadEntitlements: @MainActor () async throws -> Entitlements?
    private let loadCatalog: @MainActor () async throws -> Catalog?
    private let logger = Logger(subsystem: "rxlab.film-workflow", category: "Subscription")

    init(loadEntitlements: @escaping @MainActor () async throws -> Entitlements? = {
             try await SubscriptionService.shared.client()?.entitlements()
         },
         loadCatalog: @escaping @MainActor () async throws -> Catalog? = {
             try await SubscriptionService.shared.client()?.catalog()
         }) {
        self.loadEntitlements = loadEntitlements
        self.loadCatalog = loadCatalog
    }

    // MARK: - Derived state

    var activePlan: EntitledPlan? {
        entitlements?.plans.first { Self.activeStatuses.contains($0.status) }
    }

    var hasActiveSubscription: Bool { activePlan != nil }

    var availability: Availability {
        guard isConfigured else { return .unconfigured }
        guard entitlements != nil else { return .unknown }
        return hasActiveSubscription ? .entitled : .notEntitled
    }

    /// Top-ups in the order the user should see them: the ones they can buy
    /// first, each group smallest credit pack first.
    var sortedTopUps: [TopUpProduct] { Self.sorted(catalog?.topups ?? []) }

    /// What this build can actually sell. See `isStripePurchasable`.
    var purchasableTopUps: [TopUpProduct] { sortedTopUps.filter(Self.isStripePurchasable) }

    /// Eligible first, then ascending by credits.
    ///
    /// `eligible == nil` counts as eligible — that is the convention the
    /// package's own views use, and the field is only populated when the
    /// catalog is fetched with eligibility. Ties fall back to price then id so
    /// the order is stable across refreshes rather than jittering.
    nonisolated static func sorted(_ items: [TopUpProduct]) -> [TopUpProduct] {
        func before(_ a: TopUpProduct, _ b: TopUpProduct) -> Bool {
            (a.amount, a.priceAmountCents, a.id) < (b.amount, b.priceAmountCents, b.id)
        }
        return items.filter { $0.eligible != false }.sorted(by: before)
            + items.filter { $0.eligible == false }.sorted(by: before)
    }

    /// This app ships through Sparkle, not the Mac App Store, so StoreKit
    /// cannot fulfil anything: `purchaseApple` would throw
    /// `storeProductNotFound`. Only products reachable by Stripe checkout are
    /// offered. An empty options list means the server is offering its default
    /// flow, which is Stripe.
    nonisolated static func isStripePurchasable(_ topUp: TopUpProduct) -> Bool {
        topUp.purchaseOptions.isEmpty
            || topUp.purchaseOptions.contains { $0.provider == .stripe && $0.flow == .checkout }
    }

    // MARK: - Loading

    func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let entitlementsTask = fetchEntitlements()
        async let catalogTask = fetchCatalog()
        _ = await (entitlementsTask, catalogTask)
        lastUpdated = Date()
    }

    /// The cheap half, for when only the gate's question matters.
    func refreshEntitlements() async {
        isLoading = true
        defer { isLoading = false }
        await fetchEntitlements()
        lastUpdated = Date()
    }

    private func fetchEntitlements() async {
        do {
            try Task.checkCancellation()
            guard let loaded = try await loadEntitlements() else {
                isConfigured = false
                return
            }
            try Task.checkCancellation()
            isConfigured = true
            entitlements = loaded
            error = nil
        } catch is CancellationError {
            logger.debug("Entitlements refresh cancelled")
        } catch let urlError as URLError where urlError.code == .cancelled {
            logger.debug("Entitlements request cancelled (NSURLErrorDomain -999)")
        } catch {
            // Reaching here means a client existed and the request failed, so
            // the app *is* configured — the question simply went unanswered.
            // A failed fetch must never read as "no subscription": the last
            // good answer is kept, and `availability` stays `.unknown` only
            // when there was never one.
            isConfigured = true
            logger.error("Entitlements refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func fetchCatalog() async {
        do {
            try Task.checkCancellation()
            guard let loaded = try await loadCatalog() else { return }
            try Task.checkCancellation()
            catalog = loaded
        } catch is CancellationError {
            logger.debug("Catalog refresh cancelled")
        } catch let urlError as URLError where urlError.code == .cancelled {
            logger.debug("Catalog request cancelled (NSURLErrorDomain -999)")
        } catch {
            logger.error("Catalog refresh failed: \(error.localizedDescription, privacy: .public)")
            // The catalog only feeds the top-up list, so a failure here leaves
            // whatever was last loaded rather than emptying the sheet.
            if catalog == nil { self.error = error.localizedDescription }
        }
    }

    func clear() {
        entitlements = nil
        catalog = nil
        isConfigured = false
        error = nil
        lastUpdated = nil
    }
}
