import Foundation

@MainActor
enum AuthSessionBridge {
    static func handle(_ url: URL) {
        guard url.scheme == "filmstudio", url.host == "credits", url.path == "/refresh" else { return }
        Task { await CreditBalanceStore.shared.refresh() }
    }
}
