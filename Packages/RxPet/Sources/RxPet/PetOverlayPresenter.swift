import AppKit
import SwiftUI

/// Hosts one reusable click-through window. The owner must exclude `windowID`
/// from every capture filter before calling reveal(). All bounds use AppKit coordinates.
@MainActor public final class PetOverlayPresenter {
    private var panel: NSPanel?
    private var state: PetState?
    private var size: CGFloat = 72
    private var movementTask: Task<Void, Never>?
    private var walking = false
    private var walkUntil = Date.distantPast
    public init() {}
    /// Exposed for tests: the sprite animates its legs whenever the pet is
    /// travelling, whether it slides there or snaps.
    public var isWalking: Bool { walking }
    public var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }
    public private(set) var placementFrame: CGRect?
    public func prepare(state: PetState, target: CGRect, visibleFrame: CGRect, size: CGFloat = 72) {
        if panel == nil {
            let p = NSPanel(contentRect: .init(x: 0, y: 0, width: 210, height: 130), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
            p.level = .floating; p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.alphaValue = 0; p.orderFrontRegardless(); panel = p
        }
        self.state = state; self.size = size
        render()
        move(target: target, visibleFrame: visibleFrame, animated: false)
    }
    public func update(state: PetState) { guard self.state != state else { return }; self.state = state; render() }
    private func render() {
        guard var state else { return }
        if walking, state.motion == .automatic, [.preparing, .recording, .replaying].contains(state.status) { state.motion = .walking }
        panel?.contentView = NSHostingView(rootView: PetView(state: state).size(size).animated(panel?.alphaValue == 1).frame(width: 210, height: 130))
    }
    /// `animated` chooses only *how* the pet travels. A pet following a window
    /// the user is dragging must snap, because a half-second animation restarted
    /// every tick leaves it permanently that far behind.
    public func move(target: CGRect, visibleFrame: CGRect, animated: Bool = true, avoiding occupiedFrames: [CGRect] = []) {
        guard let panel else { return }
        let point = Self.origin(target: target, visibleFrame: visibleFrame, size: panel.frame.size, avoiding: occupiedFrames)
        let destination = CGRect(origin: point, size: panel.frame.size)
        let previous = placementFrame
        // Kept current even when the pet does not move, because callers place
        // other overlays against it.
        placementFrame = destination
        // Already sliding to exactly here.
        if animated, previous == destination { return }
        guard abs(panel.frame.minX - point.x) > 0.5 || abs(panel.frame.minY - point.y) > 0.5 else { return }
        // Walking is about travelling at all, not about how — so a snapping pet
        // still animates its legs alongside the window it follows.
        startWalking()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.5; panel.animator().setFrame(destination, display: true) }
        } else { panel.setFrameOrigin(point) }
    }
    /// One task per walk episode, extended by further movement. `render()` is
    /// deliberately confined to the two state transitions: it rebuilds the
    /// hosting view, so calling it per follow tick would be ruinous.
    private func startWalking() {
        walkUntil = Date().addingTimeInterval(1.2)
        guard !walking else { return }
        walking = true; render()
        movementTask?.cancel()
        movementTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.walkUntil.timeIntervalSinceNow
                guard remaining > 0 else { self.walking = false; self.render(); return }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }
    public var isRevealed: Bool { panel?.alphaValue == 1 }
    public func reveal() { guard panel?.alphaValue != 1 else { return }; panel?.alphaValue = 1; render() }
    public func hide() { guard panel?.alphaValue != 0 else { return }; movementTask?.cancel(); walking = false; walkUntil = .distantPast; panel?.alphaValue = 0; render() }
    public func dismiss() { movementTask?.cancel(); panel?.orderOut(nil); panel = nil; placementFrame = nil }

    static func origin(target: CGRect, visibleFrame: CGRect, size: CGSize, avoiding occupiedFrames: [CGRect] = []) -> CGPoint {
        let right = target.maxX + 8, left = target.minX - size.width - 8
        let x: CGFloat
        if right >= visibleFrame.minX && right + size.width <= visibleFrame.maxX { x = right }
        else if left >= visibleFrame.minX && left + size.width <= visibleFrame.maxX { x = left }
        else { x = max(visibleFrame.minX, min(target.maxX - size.width, visibleFrame.maxX - size.width)) }
        let y = max(visibleFrame.minY, min(visibleFrame.maxY - size.height, target.maxY - size.height))
        let preferred = CGPoint(x: x, y: y)
        let xs = [x, right, left].filter { $0 >= visibleFrame.minX && $0 + size.width <= visibleFrame.maxX }
        var candidateYs: [CGFloat] = [y]
        for frame in occupiedFrames {
            candidateYs.append(frame.minY - size.height - 8)
            candidateYs.append(frame.maxY + 8)
        }
        let ys = candidateYs
            .filter { $0 >= visibleFrame.minY && $0 + size.height <= visibleFrame.maxY }
            .sorted { abs($0 - y) < abs($1 - y) }
        for candidateX in xs {
            for candidateY in ys {
                let frame = CGRect(x: candidateX, y: candidateY, width: size.width, height: size.height)
                if !occupiedFrames.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(frame) }) { return frame.origin }
            }
        }
        return preferred
    }
}
