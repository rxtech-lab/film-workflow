import AppKit
import SwiftUI
import Testing

@testable import film_workflow

/// A card has to serve two clicks: one previews the item, two add it to the
/// film. Both are attached to the same card, so the order they arbitrate in
/// is worth pinning down with real mouse events rather than assuming.
@Suite("Library marketplace card clicks", .serialized)
@MainActor
struct LibraryMarketplaceClickTests {
    final class Calls: @unchecked Sendable {
        var log: [String] = []
    }

    private struct Card: View {
        let calls: Calls
        var body: some View {
            Color.gray
                .frame(width: 200, height: 80)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { calls.log.append("add") }
                .onTapGesture { calls.log.append("preview") }
        }
    }

    private func click(_ window: NSWindow, at point: NSPoint, count: Int) {
        for clickCount in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                window.sendEvent(event)
            }
        }
    }

    @Test("One click previews; two add, without the preview standing in the way")
    func clickCounts() async throws {
        let calls = Calls()
        let host = NSHostingView(rootView: Card(calls: calls))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        click(window, at: NSPoint(x: 100, y: 40), count: 1)
        // A single click waits out the double-click interval before it lands.
        try await Task.sleep(for: .milliseconds(600))
        #expect(calls.log == ["preview"])

        calls.log.removeAll()
        click(window, at: NSPoint(x: 100, y: 40), count: 2)
        try await Task.sleep(for: .milliseconds(600))
        #expect(calls.log == ["add"])
    }
}
