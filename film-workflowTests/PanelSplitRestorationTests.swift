import AppKit
import SwiftUI
import Testing

@testable import film_workflow

@Suite("Panel split restoration", .serialized)
@MainActor
struct PanelSplitRestorationTests {
    private struct Layout: View {
        let document: ProjectDocument

        var body: some View {
            VSplitView {
                HSplitView {
                    VSplitView {
                        Color.clear.frame(minHeight: 180)
                            .background(PersistedPanelSplit(document: document, panel: .libraryRows))
                        Color.clear.frame(minHeight: 150)
                    }
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
                    Color.clear.frame(minWidth: 360)
                        .background(PersistedPanelSplit(document: document, panel: .editorColumns))
                    Color.clear.frame(minWidth: 300, idealWidth: 320, maxWidth: 460)
                }
                .frame(minHeight: 330)
                Color.clear.frame(minHeight: 190)
                    .background(PersistedPanelSplit(document: document, panel: .editorRows))
            }
        }
    }

    private func splits(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? [])
            + view.subviews.flatMap { splits(in: $0) }
    }

    private func openWindow(_ document: ProjectDocument) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Layout(document: document))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    @Test("Native nested dividers save and restore after closing and reopening")
    func restoresNativeDividers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelSplit-\(UUID().uuidString).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let first = try await openWindow(document)
        defer { first.close() }
        let native = splits(in: try #require(first.contentView))
        let columns = try #require(native.first { $0.isVertical && $0.arrangedSubviews.count == 3 })
        let rows = try #require(native.first { !$0.isVertical && $0.bounds.width > 1000 })
        let library = try #require(native.first { !$0.isVertical && $0.bounds.width < 500 })
        columns.setPosition(310, ofDividerAt: 0)
        columns.setPosition(columns.bounds.width - 370 - columns.dividerThickness, ofDividerAt: 1)
        rows.setPosition(590, ofDividerAt: 0)
        library.setPosition(290, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        let saved = document.panelLayout
        #expect(saved.sizes(for: .editorColumns) != nil)
        #expect(saved.sizes(for: .editorRows) != nil)
        #expect(saved.sizes(for: .libraryRows) != nil)
        first.close()
        await document.close()

        let reopened = try ProjectDocument.open(url)
        let second = try await openWindow(reopened)
        defer { second.close() }
        let restored = splits(in: try #require(second.contentView))
        for (panel, split) in [
            (DocumentPanelLayout.Panel.editorColumns, try #require(restored.first { $0.isVertical && $0.arrangedSubviews.count == 3 })),
            (.editorRows, try #require(restored.first { !$0.isVertical && $0.bounds.width > 1000 })),
            (.libraryRows, try #require(restored.first { !$0.isVertical && $0.bounds.width < 500 }))
        ] {
            let expected = try #require(saved.sizes(for: panel))
            let actual = split.arrangedSubviews.map { Double(split.isVertical ? $0.frame.width : $0.frame.height) }
            #expect(actual.count == expected.count)
            for (value, target) in zip(actual, expected) { #expect(abs(value - target) < 2) }
        }
        await reopened.close()
    }
}
