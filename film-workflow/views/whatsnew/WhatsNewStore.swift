import Foundation
import Observation

/// One presentation owner across all windows, with read state persisted per card.
@MainActor
@Observable
final class WhatsNewStore {
    static let seenDefaultsKey = "whatsNew.seenFeatureSlugs"
    static let shared: WhatsNewStore = {
        let process = ProcessInfo.processInfo
        let isUITesting = process.arguments.contains("-uiTesting")
        let defaults = isUITesting
            ? process.environment["RXFILM_WHATS_NEW_TEST_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
            : .standard
        return WhatsNewStore(
            defaults: defaults,
            automaticallyPresents: NSClassFromString("XCTestCase") == nil
                && (!isUITesting || process.arguments.contains("-showWhatsNewForTesting"))
        )
    }()

    private let defaults: UserDefaults
    private let automaticallyPresents: Bool
    private(set) var seenIDs: Set<String>
    private(set) var presentationOwner: UUID?
    private(set) var hasPendingRequest = false

    init(defaults: UserDefaults = .standard, automaticallyPresents: Bool = true) {
        self.defaults = defaults
        self.automaticallyPresents = automaticallyPresents
        seenIDs = Set(defaults.stringArray(forKey: Self.seenDefaultsKey) ?? [])
    }

    func requestPresentation() {
        guard presentationOwner == nil else { return }
        hasPendingRequest = true
    }

    func beginPresentation(owner: UUID, automatically: Bool, features: [WhatsNewFeature] = WhatsNewFeature.all) -> [WhatsNewFeature] {
        guard presentationOwner == nil else { return [] }
        let batch: [WhatsNewFeature]
        if hasPendingRequest {
            batch = features
        } else if automatically && automaticallyPresents {
            batch = features.filter { !seenIDs.contains($0.id) }
        } else {
            return []
        }
        guard !batch.isEmpty else { return [] }
        hasPendingRequest = false
        presentationOwner = owner
        return batch
    }

    func markSeen(_ features: [WhatsNewFeature]) {
        seenIDs.formUnion(features.map(\.id))
        defaults.set(seenIDs.sorted(), forKey: Self.seenDefaultsKey)
    }

    func endPresentation(owner: UUID) {
        guard presentationOwner == owner else { return }
        presentationOwner = nil
    }
}
