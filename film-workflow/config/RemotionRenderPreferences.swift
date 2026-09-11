import Foundation

@MainActor
enum RemotionRenderPreferences {
    static let concurrencyKey = "remotion.renderConcurrency"
    static var concurrency: Int? {
        let value = UserDefaults.standard.integer(forKey: concurrencyKey)
        return (1...4).contains(value) ? value : nil
    }
}
