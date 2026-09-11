import AppKit
import SwiftUI

/// Put this in the background of a direct split child. Observing the native
/// split preserves SwiftUI's divider dragging, constraints and accessibility.
struct PersistedPanelSplit: NSViewRepresentable {
    let document: ProjectDocument
    let panel: DocumentPanelLayout.Panel

    func makeNSView(context: Context) -> Probe {
        Probe(document: document, panel: panel)
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        nsView.detach()
    }

    final class Probe: NSView {
        private let document: ProjectDocument
        private let panel: DocumentPanelLayout.Panel
        private weak var split: NSSplitView?
        private var restored = false
        private var restoring = false

        init(document: ProjectDocument, panel: DocumentPanelLayout.Panel) {
            self.document = document
            self.panel = panel
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach(); return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func layout() {
            super.layout()
            // Initial SwiftUI layout can attach the view before its split is sized.
            if !restored {
                DispatchQueue.main.async { [weak self] in self?.attach() }
            }
        }

        private func attach() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let found = ancestor as? NSSplitView else { return }
            if split !== found {
                detach()
                split = found
                NotificationCenter.default.addObserver(
                    self, selector: #selector(didResize),
                    name: NSSplitView.didResizeSubviewsNotification, object: found
                )
            }
            restoreIfReady()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            split = nil
            restored = false
        }

        private func restoreIfReady() {
            guard !restored, !restoring, let split,
                  split.arrangedSubviews.count >= 2 else { return }
            let available = (split.isVertical ? split.bounds.width : split.bounds.height)
                - split.dividerThickness * CGFloat(split.arrangedSubviews.count - 1)
            guard available > 0,
                  split.arrangedSubviews.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 }) else { return }
            restored = true
            guard let saved = document.panelLayout.sizes(for: panel),
                  saved.count == split.arrangedSubviews.count else { return }
            restoring = true
            defer { restoring = false }

            var sizes = saved.map { CGFloat($0) }
            if split.isVertical && sizes.count == 3 {
                // Preserve sidebar widths; give changes in window width to the viewer.
                sizes[1] = max(0, available - sizes[0] - sizes[2])
            } else if panel == .timelineColumns && sizes.count == 2 {
                sizes[0] = max(0, available - sizes[1])
            } else {
                let scale = available / sizes.reduce(0, +)
                sizes = sizes.map { $0 * scale }
            }
            var position: CGFloat = 0
            for index in 0..<(sizes.count - 1) {
                position += sizes[index]
                let constrained = min(split.maxPossiblePositionOfDivider(at: index),
                                      max(split.minPossiblePositionOfDivider(at: index), position))
                split.setPosition(constrained, ofDividerAt: index)
                position += split.dividerThickness
            }
        }

        @objc private func didResize(_ notification: Notification) {
            guard !restoring else { return }
            if !restored { restoreIfReady(); return }
            guard let split, split.window != nil else { return }
            let sizes = split.arrangedSubviews.map { Double(split.isVertical ? $0.frame.width : $0.frame.height) }
            // Layout state is not observed by SwiftUI. Record synchronously so
            // closing immediately after a drag still flushes its final position.
            document.setPanelSizes(sizes, for: panel)
        }
    }
}
