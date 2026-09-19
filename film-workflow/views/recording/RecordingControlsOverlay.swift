import AppKit
import SwiftUI

/// One interactive panel that rides beside the pet so a recording can be paused
/// or stopped where the user is already looking.
///
/// Unlike the pet this panel takes clicks, so it cannot share the pet's window.
/// It is excluded from capture *and* from the recorded input stream: its own
/// buttons are chrome, not something the take should replay.
@MainActor final class RecordingControlsOverlay {
    private var panel: NSPanel?
    private var size = CGSize(width: 250, height: 54)
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func prepare() {
        guard panel == nil else { return }
        let created = RecordingControlsPanel(contentRect: CGRect(origin: .zero, size: size),
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        created.isOpaque = false; created.backgroundColor = .clear; created.hasShadow = false
        created.hidesOnDeactivate = false; created.isReleasedWhenClosed = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = RecordingControlsHostingView(rootView: AnyView(
            RecordingActiveControls(compact: true)
                .padding(10)
                .frame(width: size.width, height: size.height)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        ))
        hosting.focusRingType = .none
        created.contentView = hosting
        created.alphaValue = 0
        created.orderFrontRegardless()
        panel = created
        guard let id = windowID else { return }
        RecordingSources.shared.excludedWindowIDs.insert(id)
        RecordingSources.shared.excludedInputWindowIDs.insert(id)
    }

    /// `anchor` is the pet the controls belong to. Nil hides them.
    func update(anchor: CGRect?, appliedExclusions: Set<CGWindowID>, requiresExclusion: Bool) {
        guard let panel, let id = windowID else { return }
        guard let anchor, !requiresExclusion || appliedExclusions.contains(id) else { panel.alphaValue = 0; return }
        position(anchor)
        panel.alphaValue = 1
    }

    func follow(anchor: CGRect?) {
        guard let panel, panel.alphaValue == 1, let anchor else { return }
        position(anchor)
    }

    func hide() { panel?.alphaValue = 0 }
    func dismiss() {
        if let id = windowID {
            RecordingSources.shared.excludedWindowIDs.remove(id)
            RecordingSources.shared.excludedInputWindowIDs.remove(id)
        }
        panel?.orderOut(nil); panel = nil
    }

    private func position(_ anchor: CGRect) {
        guard let panel else { return }
        let visible = NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(anchor), b = rhs.frame.intersection(anchor)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }?.visibleFrame ?? anchor
        let frame = RecordingControlsGeometry.frame(size: size, pet: anchor, visibleFrame: visible)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }
}

nonisolated enum RecordingControlsGeometry {
    /// Under the pet by default, flipping above it when the bottom of the screen
    /// is in the way. Always inside `visibleFrame`.
    static func frame(size: CGSize, pet: CGRect, visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
        var origin = CGPoint(x: pet.midX - size.width / 2, y: pet.minY - size.height - 4)
        if origin.y < visibleFrame.minY { origin.y = pet.maxY + 4 }
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width))
        origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }
}

private final class RecordingControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel never activates the app, so the first click has to be accepted
/// outright or it would be swallowed as an activation click.
private final class RecordingControlsHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
