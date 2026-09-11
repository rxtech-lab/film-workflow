import AppKit
import Observation
import SwiftUI
import Testing
import VideoEditorCore
import VideoEditorUI
import VideoEffectsUI

@testable import film_workflow

@Suite("Timeline browser layout", .serialized)
@MainActor
struct TimelineBrowserSplitTests {
    @Observable
    final class Model {
        var visible = true
        var timeline = Timeline(tracks: (0..<8).map { index in
            Track(kind: .video, name: "V\(index)", clips: [
                Clip(source: .init(id: "still-\(index)", kind: .image, displayName: "Still"), start: 0, duration: 120)
            ])
        })
        var playhead = 8.5
        var zoom = 80.0
        var selection: Set<UUID> = []
        var appearances = 0
    }

    private actor Resolver: MediaResolver {
        private(set) var requests = 0
        func resolve(_ source: ClipSource) async throws -> ResolvedMedia { throw MediaResolverError.missing(source) }
        func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? {
            requests += 1
            return CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private struct Layout: View {
        let document: ProjectDocument
        @Bindable var model: Model
        let resolver: Resolver

        var body: some View {
            TimelineBrowserSplit(document: document, browserVisible: model.visible) {
                SequenceTimelineView(timeline: $model.timeline, playhead: $model.playhead, selectedClipIDs: $model.selection,
                                     pixelsPerSecond: $model.zoom, resolver: resolver, onDrop: { _, _, _ in })
                    .onAppear { model.appearances += 1 }
            } browser: {
                ModifierBrowser { _ in }
            }
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func open(_ document: ProjectDocument, model: Model, resolver: Resolver) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Layout(document: document, model: model, resolver: resolver))
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        return window
    }

    @Test("Toggling keeps timeline scroll, thumbnails, selection and browser tab alive")
    func stableTimeline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserLayout-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        document.setPanelSizes([884, 310], for: .timelineColumns)
        let model = Model()
        model.selection = [try #require(model.timeline.allClips.first?.id)]
        let selection = model.selection
        let resolver = Resolver()
        let window = try await open(document, model: model, resolver: resolver)
        defer { window.close() }
        let root = try #require(window.contentView)
        let scrolls = descendants(NSScrollView.self, in: root)
        let horizontal = try #require(scrolls.first { $0.hasHorizontalScroller })
        let vertical = try #require(scrolls.first { $0.hasVerticalScroller && $0.bounds.width > 500 })
        horizontal.contentView.scroll(to: NSPoint(x: 300, y: 0))
        horizontal.reflectScrolledClipView(horizontal.contentView)
        vertical.contentView.scroll(to: NSPoint(x: 0, y: 90))
        vertical.reflectScrolledClipView(vertical.contentView)
        let tabs = try #require(descendants(NSSegmentedControl.self, in: root).first)
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        try await Task.sleep(for: .milliseconds(100))
        let offsetX = horizontal.contentView.bounds.minX
        let offsetY = vertical.contentView.bounds.minY
        #expect(offsetX > 0 && offsetY > 0)
        let requests = await resolver.requests
        #expect(requests == 8)
        let expandedWidth = horizontal.frame.width

        for visible in [false, true, false, true] {
            model.visible = visible
            try await Task.sleep(for: .milliseconds(350))
            let current = descendants(NSScrollView.self, in: root)
            #expect(current.contains { $0 === horizontal })
            #expect(current.contains { $0 === vertical })
            #expect(abs(horizontal.contentView.bounds.minX - offsetX) < 1)
            #expect(abs(vertical.contentView.bounds.minY - offsetY) < 1)
            #expect(abs(horizontal.frame.width - expandedWidth - (visible ? 0 : 316)) < 2)
            #expect(model.appearances == 1)
            #expect(await resolver.requests == requests)
            #expect(model.selection == selection && model.playhead == 8.5 && model.zoom == 80)
            #expect(tabs.selectedSegment == 1)
            #expect(document.panelLayout.sizes(for: .timelineColumns)?.last == 310)
        }

        // Interrupt an in-flight collapse; the same views and saved width survive.
        model.visible = false
        try await Task.sleep(for: .milliseconds(60))
        model.visible = true
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.appearances == 1)
        #expect(abs(horizontal.frame.width - expandedWidth) < 2)
        #expect(await resolver.requests == requests)
        await document.close()
    }

    @Test("Opening with the browser hidden preserves its saved expansion width")
    func restoreHiddenBrowser() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HiddenBrowser-\(UUID()).rxfilmstudio")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        document.setPanelSizes([820, 374], for: .timelineColumns)
        document.setEffectsBrowserVisible(false)
        await document.close()
        let reopened = try ProjectDocument.open(url)
        let model = Model()
        model.visible = reopened.panelLayout.effectsBrowserVisible ?? true
        let window = try await open(reopened, model: model, resolver: Resolver())
        defer { window.close() }
        let root = try #require(window.contentView)
        let horizontal = try #require(descendants(NSScrollView.self, in: root).first { $0.hasHorizontalScroller })
        let hiddenWidth = horizontal.frame.width
        model.visible = true
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(hiddenWidth - horizontal.frame.width - 380) < 2)
        #expect(model.appearances == 1)
        #expect(reopened.panelLayout.sizes(for: .timelineColumns)?.last == 374)
        await reopened.close()
    }
}
