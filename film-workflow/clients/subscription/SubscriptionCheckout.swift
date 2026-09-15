import AppKit
import Foundation

/// The one place that decides how a purchase is started.
///
/// While no publishable key is configured the app behaves exactly as it did
/// before this service existed — the browser credits page — so a build without
/// a key is never a dead end.
enum SubscriptionCheckout {
    @MainActor
    static func presentTopUp() {
        if SubscriptionService.shared.isConfigured {
            AppNavigation.shared.requestTopUp()
        } else {
            CreditBalanceStore.shared.openTopUp()
        }
    }

    /// Where Stripe sends the browser when checkout succeeds.
    ///
    /// Stripe rejects non-HTTP(S) redirect targets, so this cannot be
    /// `filmstudio://` directly. It points at the web page, which bounces back
    /// into the app; if that bounce is ever missing, the app still catches up
    /// through its refresh on `didBecomeActive`.
    static var successURL: URL {
        BackendConfig.webBaseURL
            .appending(path: "credits/complete")
            .appending(queryItems: [URLQueryItem(name: "app", value: "1")])
    }

    static var cancelURL: URL {
        BackendConfig.webBaseURL
            .appending(path: "credits")
            .appending(queryItems: [URLQueryItem(name: "app", value: "1")])
    }

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
