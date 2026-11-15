import Foundation

/// User-tunable Remotion render settings, read when a render starts.
enum RemotionRenderPreferences {
    static let concurrencyKey = "remotion.renderConcurrency"

    /// The "frames at a time" preference (1…4), or nil for automatic.
    static var concurrency: Int? {
        let value = UserDefaults.standard.integer(forKey: concurrencyKey)
        return (1...4).contains(value) ? value : nil
    }
}
