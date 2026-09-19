import AppKit

/// A red strip along the top edge of everything being recorded. Click-through
/// and excluded from capture, so it marks the take without joining it.
@MainActor final class RecordingBorderIndicators {
    private var bars: [String: NSPanel] = [:]
    var windowIDs: Set<CGWindowID> { Set(bars.values.map { CGWindowID($0.windowNumber) }) }
    static let thickness: CGFloat = 5

    func prepare(targets: [RecordingPetTarget]) {
        hide()
        let wanted = Set(targets.map(\.id))
        for id in bars.keys where !wanted.contains(id) { remove(id) }
        for target in targets {
            let bar = bars[target.id] ?? make()
            bars[target.id] = bar
            position(bar, for: target)
            RecordingSources.shared.excludedWindowIDs.insert(CGWindowID(bar.windowNumber))
            // Click-through like the pet, so clicks that land on the recorded
            // content underneath are still captured as user actions.
            RecordingSources.shared.passThroughWindowIDs.insert(CGWindowID(bar.windowNumber))
        }
    }

    func update(targets: [RecordingPetTarget], paused: Bool, appliedExclusions: Set<CGWindowID>, requiresExclusion: Bool) {
        let wanted = Set(targets.map(\.id))
        for (id, bar) in bars where !wanted.contains(id) { bar.alphaValue = 0 }
        for target in targets {
            guard let bar = bars[target.id] else { continue }
            let id = CGWindowID(bar.windowNumber)
            guard !requiresExclusion || appliedExclusions.contains(id) else { bar.alphaValue = 0; continue }
            (bar.contentView as? RecordingBorderBar)?.paused = paused
            position(bar, for: target)
            bar.alphaValue = 1
        }
    }

    /// Position only, driven by the fast loop. Never animated — the bar must sit
    /// exactly on the edge it marks.
    func follow(targets: [RecordingPetTarget]) {
        for target in targets {
            guard let bar = bars[target.id], bar.alphaValue == 1 else { continue }
            position(bar, for: target)
        }
    }

    func hide() { bars.values.forEach { $0.alphaValue = 0 } }
    func dismiss() {
        for id in Array(bars.keys) { remove(id) }
        bars = [:]
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: Self.thickness),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        // .floating sits under the menu bar, which is exactly where a display's
        // top edge is. The bar is excluded from capture either way.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = RecordingBorderBar()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        return panel
    }

    private func remove(_ id: String) {
        guard let bar = bars.removeValue(forKey: id) else { return }
        let windowID = CGWindowID(bar.windowNumber)
        RecordingSources.shared.excludedWindowIDs.remove(windowID)
        RecordingSources.shared.passThroughWindowIDs.remove(windowID)
        bar.orderOut(nil)
    }

    private func position(_ bar: NSPanel, for target: RecordingPetTarget) {
        let screen = NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(target.frame), b = rhs.frame.intersection(target.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }?.frame ?? target.frame
        let frame = RecordingBorderGeometry.topBar(for: target.frame, height: Self.thickness, within: screen)
        guard !frame.isEmpty else { bar.alphaValue = 0; return }
        if bar.frame != frame { bar.setFrame(frame, display: false) }
    }
}

nonisolated enum RecordingBorderGeometry {
    /// The strip sits inside the target's top edge, clipped to the screen it is
    /// on. Empty when the target has no visible top edge there.
    static func topBar(for frame: CGRect, height: CGFloat, within screen: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0, height > 0 else { return .zero }
        let bar = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        let clipped = bar.intersection(screen)
        return clipped.isNull ? .zero : clipped
    }
}

private final class RecordingBorderBar: NSView {
    var paused = false { didSet { if paused != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        (paused ? NSColor.systemOrange : .systemRed).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
