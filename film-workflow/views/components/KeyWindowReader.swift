#if os(macOS)
import AppKit
import SwiftUI

/// Shared plumbing for the sheets raised from outside a view — sign-in,
/// top-ups, the subscription paywall.
///
/// Scene-root modifiers do not reliably inherit SwiftUI's active-window state,
/// so each presenter reaches for the real `NSWindow` instead. Extracted so the
/// "is this window ready for a sheet" rule lives in one place rather than being
/// copied per presenter and drifting apart.
final class KeyWindowReference {
    weak var window: NSWindow?

    /// A window can take a sheet only when it is the one the user is looking at
    /// and is not already hosting or acting as a sheet.
    var isReadyForSheet: Bool {
        guard let window else { return false }
        return window.isKeyWindow
            && window.isVisible
            && window.sheetParent == nil
            && window.attachedSheet == nil
    }

    func matches(_ notification: Notification) -> Bool {
        notification.object as? NSWindow === window
    }
}

struct KeyWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onWindow?(window)
            }
        }
    }
}

extension View {
    /// Tracks this view's window in `reference`, calling `onChange` whenever the
    /// window appears, becomes key, or finishes dismissing a sheet.
    func trackingKeyWindow(_ reference: KeyWindowReference,
                           onChange: @escaping () -> Void) -> some View {
        background {
            KeyWindowReader { window in
                reference.window = window
                onChange()
            }
            .frame(width: 0, height: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard reference.matches(notification) else { return }
            onChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { notification in
            guard reference.matches(notification) else { return }
            // The sheet is still attached at notification time; yield so the
            // window reports itself free before the next presenter checks.
            Task { @MainActor in
                await Task.yield()
                onChange()
            }
        }
    }
}
#endif
