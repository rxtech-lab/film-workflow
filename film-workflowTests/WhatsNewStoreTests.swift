import Foundation
import SwiftUI
import Testing

@testable import film_workflow

@Suite("What's New read state")
@MainActor
struct WhatsNewStoreTests {
    @Test("Seen cards survive relaunch; a later card is still announced")
    func persistedReadState() throws {
        let suite = "WhatsNewStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        let store = WhatsNewStore(defaults: defaults)
        let batch = store.beginPresentation(owner: owner, automatically: true)
        #expect(batch.map(\.id) == WhatsNewFeature.all.map(\.id))
        store.markSeen(batch)
        store.endPresentation(owner: owner)

        let relaunched = WhatsNewStore(defaults: defaults)
        #expect(relaunched.beginPresentation(owner: owner, automatically: true).isEmpty)
        let future = WhatsNewFeature(id: "future-feature", title: "Future", subtitle: "Future", imageName: "", highlights: [])
        #expect(relaunched.beginPresentation(owner: owner, automatically: true, features: WhatsNewFeature.all + [future]).map(\.id) == [future.id])
    }

    @Test("Manual replay includes read cards and only one window can claim it")
    func manualReplayAndWindowOwnership() throws {
        let suite = "WhatsNewStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhatsNewStore(defaults: defaults, automaticallyPresents: false)
        let first = UUID()
        let second = UUID()
        store.markSeen(WhatsNewFeature.all)
        #expect(store.beginPresentation(owner: first, automatically: true).isEmpty)
        store.requestPresentation()
        #expect(store.hasPendingRequest)
        #expect(store.beginPresentation(owner: first, automatically: false).count == WhatsNewFeature.all.count)
        #expect(!store.hasPendingRequest)
        #expect(store.beginPresentation(owner: second, automatically: false).isEmpty)
        store.endPresentation(owner: second)
        #expect(store.presentationOwner == first)
        store.requestPresentation()
        #expect(!store.hasPendingRequest)
        store.endPresentation(owner: first)
        store.requestPresentation()
        #expect(!store.beginPresentation(owner: second, automatically: false).isEmpty)
    }
}
