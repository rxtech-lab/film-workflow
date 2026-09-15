import Foundation

@MainActor
enum AuthSessionBridge {
    /// Handles the custom-scheme links the web pages bounce back into the app
    /// after a browser purchase — the only push signal we get, since the
    /// subscription package's own views report nothing to their host.
    static func handle(_ url: URL) {
        guard url.scheme == "filmstudio",
              url.host == "credits" || url.host == "subscription",
              url.path == "/refresh" else { return }
        Task {
            await CreditBalanceStore.shared.refresh()
            await SubscriptionStore.shared.refresh()
        }
    }

    /// Whether this URL is ours rather than a film package to open.
    static func handles(_ url: URL) -> Bool {
        url.scheme == "filmstudio"
    }
}
