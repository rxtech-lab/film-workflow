import AppKit
import Foundation
import SwiftUI
import Testing

@testable import film_workflow

@Suite("Library marketplace section", .serialized)
@MainActor
struct LibraryMarketplaceSectionTests {
    private func manifest(_ kind: MarketplaceKind, id: String, title: String, installedAt: Date, category: String = "test",
                          metadata: MarketplaceItemMetadata = .init()) -> InstalledMarketplaceManifest {
        InstalledMarketplaceManifest(itemID: id, kind: kind, title: title, category: category, description: "", contentFilename: "content.mp4",
                                     contentRelativePath: "content.mp4", previewImagePath: "preview.jpg", metadata: metadata, installedAt: installedAt)
    }

    @Test("Only film-addable kinds reach the library, newest install first")
    func libraryItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let manifests = [
            manifest(.footage, id: "harbor", title: "Harbor", installedAt: now.addingTimeInterval(-60)),
            manifest(.font, id: "serif", title: "Serif", installedAt: now),
            manifest(.soundEffect, id: "door", title: "Door", installedAt: now.addingTimeInterval(-10)),
            manifest(.effect, id: "glow", title: "Glow", installedAt: now),
            manifest(.remotionPrompt, id: "intro", title: "Intro", installedAt: now.addingTimeInterval(-30)),
        ]
        for m in manifests {
            let dir = FileStorage.marketplaceItemDir(kind: m.kind.rawValue, itemID: m.itemID, root: root)
            try MarketplaceStore.write(m, to: dir)
            try Data("x".utf8).write(to: m.contentURL(in: dir))
        }
        let store = MarketplaceStore(client: MarketplaceClient(transport: FakeMarketplaceTransport(page: .init(items: [], total: 0, page: 1, pageCount: 1, pageSize: 24, categories: []), downloadFile: root)), root: root)
        #expect(store.installed.count == 5)
        #expect(store.libraryItems.map(\.itemID) == ["door", "intro", "harbor"])
    }

    @Test("Rows resolve their files and honour the panel's search filter")
    func rows() throws {
        let root = URL(fileURLWithPath: "/tmp/marketplace-rows")
        let manifests = [
            manifest(.footage, id: "harbor", title: "Harbor sunrise", installedAt: Date(), category: "nature", metadata: .init(durationSeconds: 12.5, width: 1920, height: 1080)),
            manifest(.soundEffect, id: "door", title: "Door slam", installedAt: Date(), category: "foley"),
            manifest(.remotionPrompt, id: "intro", title: "Cold open", installedAt: Date(), category: "intros"),
        ]
        let directory: (InstalledMarketplaceManifest) -> URL = { root.appendingPathComponent($0.itemID) }

        let all = LibraryMarketplaceRow.rows(from: manifests, directory: directory, search: "")
        #expect(all.map(\.id) == ["harbor", "door", "intro"])
        let harbor = try #require(all.first)
        #expect(harbor.mediaURL == root.appendingPathComponent("harbor/content.mp4"))
        #expect(harbor.previewURL == root.appendingPathComponent("harbor/preview.jpg"))
        #expect(harbor.posterVideoURL == harbor.mediaURL)
        #expect(harbor.duration == 12.5)
        #expect(harbor.subtitle == "nature · 1920×1080")
        #expect(all[1].posterVideoURL == nil)
        #expect(all[1].duration == nil)

        #expect(LibraryMarketplaceRow.rows(from: manifests, directory: directory, search: "SLAM").map(\.id) == ["door"])
        #expect(LibraryMarketplaceRow.rows(from: manifests, directory: directory, search: "zzz").isEmpty)
        #expect(LibraryMarketplaceRow.sectionKinds == [.footage, .remotionPrompt, .audio, .soundEffect])
    }

    @Test("The Marketplace tab lists installed items by kind as cards that add to the film")
    func cards() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let root = URL(fileURLWithPath: "/tmp/marketplace-cards")
        let group = ProjectGroup(name: "B-roll")
        let rows = LibraryMarketplaceRow.rows(from: [
            manifest(.footage, id: "harbor", title: "Harbor sunrise", installedAt: Date(), metadata: .init(durationSeconds: 25)),
            manifest(.soundEffect, id: "door", title: "Door slam", installedAt: Date()),
        ], directory: { root.appendingPathComponent($0.itemID) }, search: "")

        final class Added: @unchecked Sendable { var calls: [(String, UUID?)] = [] }
        let added = Added()
        let grid = LibraryMarketplaceGrid(rows: rows, groups: [group], onAdd: { row, group in added.calls.append((row.id, group)) },
                                          onReveal: { _ in }, onOpenMarketplace: {})
        let host = NSHostingView(rootView: grid)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let elements = hostedAccessibilityDescendants(host)
        let header = try #require(elements.first { $0.accessibilityIdentifier() == "library.marketplace.section.footage" })
        #expect(header.accessibilityLabel()?.contains("Footage") == true)
        let harbor = try #require(elements.first { $0.accessibilityIdentifier() == "library.marketplace.harbor" })
        #expect(harbor.accessibilityLabel()?.contains("Harbor sunrise") == true)
        #expect(harbor.accessibilityLabel()?.contains("0:25") == true)
        // Sound effects get their own section, listed after footage.
        let effects = try #require(elements.first { $0.accessibilityIdentifier() == "library.marketplace.section.sound_effect" })
        let door = try #require(elements.first { $0.accessibilityIdentifier() == "library.marketplace.door" })
        #expect(effects.accessibilityFrame().minY < harbor.accessibilityFrame().minY)
        #expect(door.accessibilityFrame().minY < effects.accessibilityFrame().minY)
        #expect(!elements.contains { $0.accessibilityIdentifier() == "library.marketplace.section.audio" })

        // Pressing a card (VoiceOver's stand-in for the double-click) adds it ungrouped.
        #expect(harbor.accessibilityPerformPress())
        #expect(added.calls.map(\.0) == ["harbor"])
        #expect(added.calls.first?.1 == nil)

        // Collapsing a section hides its cards and leaves the others alone.
        // The collapse animates, so wait for the tree rather than a fixed beat.
        #expect(header.accessibilityPerformPress())
        var after = hostedAccessibilityDescendants(host)
        for _ in 0..<20 where after.contains(where: { $0.accessibilityIdentifier() == "library.marketplace.harbor" }) {
            try await Task.sleep(for: .milliseconds(100))
            after = hostedAccessibilityDescendants(host)
        }
        #expect(!after.contains { $0.accessibilityIdentifier() == "library.marketplace.harbor" })
        #expect(after.contains { $0.accessibilityIdentifier() == "library.marketplace.door" })
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        view.subviews.flatMap { ($0 as? NSSegmentedControl).map { [$0] } ?? segmentedControls(in: $0) }
    }

    @Test("The panel offers Library and Marketplace tabs; the Marketplace tab shows the installed items")
    func panelTabs() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-tabs-\(UUID().uuidString)")
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-tabs-\(UUID().uuidString).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: package) }
        let m = manifest(.footage, id: "harbor", title: "Harbor sunrise", installedAt: Date())
        let dir = FileStorage.marketplaceItemDir(kind: m.kind.rawValue, itemID: m.itemID, root: root)
        try MarketplaceStore.write(m, to: dir)
        try Data("x".utf8).write(to: m.contentURL(in: dir))
        let store = MarketplaceStore(client: MarketplaceClient(transport: FakeMarketplaceTransport(page: .init(items: [], total: 0, page: 1, pageCount: 1, pageSize: 24, categories: []), downloadFile: root)), root: root)
        let document = try ProjectDocument.create(at: package)
        defer { Task { await document.close() } }

        let panel = LibraryPanel(index: LibraryIndex(), groups: [], state: EditorWindowState(), document: document,
                                 onCreate: { _, _ in }, onMove: { _, _ in }, onImport: {}, onCreateGroup: {},
                                 onRenameGroup: { _ in }, onDeleteGroup: { _ in }, onRename: { _ in }, onDelete: { _ in },
                                 onExport: { _ in }, onShowVersions: { _, _ in }, marketplace: store)
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        var elements = hostedAccessibilityDescendants(host)
        #expect(elements.contains { $0.accessibilityIdentifier() == "library.grid" })
        #expect(!elements.contains { $0.accessibilityIdentifier() == "library.marketplace.harbor" })
        // The segmented picker sits in the panel's title bar; switch it the way a click would.
        let picker = try #require(segmentedControls(in: host).first { $0.segmentCount == 2 })
        #expect(picker.label(forSegment: 1) == "Marketplace")
        picker.selectedSegment = 1
        #expect(picker.sendAction(picker.action, to: picker.target))
        try await Task.sleep(for: .milliseconds(300))

        elements = hostedAccessibilityDescendants(host)
        #expect(!elements.contains { $0.accessibilityIdentifier() == "library.grid" })
        #expect(elements.contains { $0.accessibilityIdentifier() == "library.marketplace.grid" })
        #expect(elements.contains { $0.accessibilityIdentifier() == "library.marketplace.harbor" })
    }
}
