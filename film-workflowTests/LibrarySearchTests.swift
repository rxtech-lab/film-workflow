import AppKit
import SwiftUI
import Testing

@testable import film_workflow

@Suite("Library search", .serialized)
@MainActor
struct LibrarySearchTests {
    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func libraryTextPixels(in bitmap: NSBitmapImageRep, height: CGFloat, scale: CGFloat) -> Int {
        var count = 0
        // Exclude the fixed title/filter bar and the footage pane. In dark
        // appearance these bright pixels belong to the library's rendered content.
        for y in Int(75 * scale)..<Int((height - 10) * scale) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.5,
                   min(color.redComponent, color.greenComponent, color.blueComponent) > 0.65 { count += 1 }
            }
        }
        return count
    }

    @Test("Clearing matching and empty searches restores visible library footage")
    func clearSearch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySearch-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let group = ProjectGroup(name: "Location footage")
        let assets = (0..<12).map { index in
            let asset = ImportedAsset(name: index == 0 ? "Harbor sunrise" : "City \(index)",
                                      kind: .video, originalPath: url.appendingPathComponent("missing-\(index).mp4").path)
            asset.durationSeconds = 25
            asset.updatedAt = Date(timeIntervalSince1970: Double(100 - index))
            asset.groupID = index < 6 ? nil : group.id
            return asset
        }
        let state = EditorWindowState()
        let panel = LibraryPanel(index: LibraryIndex(imported: assets), groups: [group], state: state,
                                 document: document, onCreate: { _, _ in }, onMove: { _, _ in },
                                 onImport: {}, onCreateGroup: {}, onRenameGroup: { _ in },
                                 onDeleteGroup: { _ in }, onRename: { _ in }, onDelete: { _ in },
                                 onExport: { _ in }, onShowVersions: { _, _ in })
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))

        let field = try #require(views(NSTextField.self, in: host).first { $0.isEditable })
        // The grid is the only scroll view while nothing is selected; its bottom
        // edge is where the footage pane begins.
        let grid = try #require(views(NSScrollView.self, in: host).first)
        func gridPaneHeight() -> CGFloat {
            let rect = grid.convert(grid.bounds, to: host)
            return host.isFlipped ? rect.maxY : host.bounds.height - rect.minY
        }
        let initialHeight = gridPaneHeight()
        for (iteration, query) in ["", "Harbor", "", "no matching footage", "", "City 8", ""].enumerated() {
            field.stringValue = query
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/film-library-search-\(iteration).png"))
            #expect(abs(gridPaneHeight() - initialHeight) < 2)
            let visiblePixels = libraryTextPixels(in: bitmap, height: initialHeight,
                                                 scale: CGFloat(bitmap.pixelsHigh) / host.bounds.height)
            #expect(visiblePixels > 200, "Library content must be rendered after search step \(iteration): '\(query)'")
        }
        await document.close()
    }
}
