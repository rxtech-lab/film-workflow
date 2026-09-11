import AppKit
import Observation
import SwiftUI
import Testing

@testable import film_workflow

@Suite("Library footage layout", .serialized)
@MainActor
struct LibraryFootageSplitTests {
    @Observable
    final class Model {
        var visible = true
    }

    private struct Layout: View {
        let document: ProjectDocument
        @Bindable var model: Model

        var body: some View {
            LibraryFootageSplit(document: document, footageVisible: model.visible) {
                ScrollView { Color.clear.frame(height: 2000) }
            } footage: {
                FootageBrowserView(libraryItem: nil, title: "Footage", cells: [], selectedID: nil,
                                   onSelect: { _ in }, onDeselect: {}, isExpanded: model.visible,
                                   onToggle: { model.visible.toggle() })
            }
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func open(_ document: ProjectDocument, model: Model) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Layout(document: document, model: model))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    @Test("Collapsing folds the pane to its header and keeps the saved height")
    func collapseAndExpand() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FootageSplit-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        document.setPanelSizes([374, 220], for: .libraryRows)
        let model = Model()
        let window = try await open(document, model: model)
        defer { window.close() }
        let root = try #require(window.contentView)
        let grid = try #require(descendants(NSScrollView.self, in: root).first)
        let total = root.bounds.height
        #expect(abs(grid.frame.height - (total - 220 - LibraryFootageSplit<EmptyView, EmptyView>.dividerHeight)) < 2)

        model.visible = false
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(grid.frame.height - (total - LibraryFootageSplit<EmptyView, EmptyView>.collapsedHeight)) < 2)
        #expect(document.panelLayout.sizes(for: .libraryRows)?.last == 220)

        model.visible = true
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(grid.frame.height - (total - 220 - LibraryFootageSplit<EmptyView, EmptyView>.dividerHeight)) < 2)
        await document.close()
    }

    @Test("Opening with the pane collapsed restores its saved height on expand")
    func restoreCollapsed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FootageSplitHidden-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        document.setPanelSizes([350, 244], for: .libraryRows)
        document.setFootageBrowserVisible(false)
        await document.close()
        let reopened = try ProjectDocument.open(url)
        let model = Model()
        model.visible = reopened.panelLayout.footageBrowserVisible ?? true
        #expect(model.visible == false)
        let window = try await open(reopened, model: model)
        defer { window.close() }
        let root = try #require(window.contentView)
        let grid = try #require(descendants(NSScrollView.self, in: root).first)
        let collapsedHeight = grid.frame.height
        model.visible = true
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(collapsedHeight - grid.frame.height - 244 + FootageBrowserView.headerHeight) < 2)
        await reopened.close()
    }
}
