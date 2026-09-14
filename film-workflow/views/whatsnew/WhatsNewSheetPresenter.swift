import SwiftUI

extension View {
    func whatsNewSheetPresenter(automatically: Bool = false) -> some View {
        modifier(WhatsNewSheetPresenter(automatically: automatically))
    }
}

private struct WhatsNewSheetPresenter: ViewModifier {
    let automatically: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var windowReference = WhatsNewWindowReference()
    @State private var store = WhatsNewStore.shared
    @State private var owner = UUID()
    @State private var batch: [WhatsNewFeature] = []
    @State private var presentation: WhatsNewPresentation?
    /// A sheet cannot open a window while it is up, so the card's button is
    /// remembered and acted on once the sheet is gone.
    @State private var actionAfterDismissal: WhatsNewFeature.CallToAction?

    func body(content: Content) -> some View {
        content
            .background {
                WhatsNewWindowReader { window in
                    windowReference.window = window
                    schedulePresentation()
                }
                .frame(width: 0, height: 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard notification.object as? NSWindow === windowReference.window else { return }
                schedulePresentation()
            }
            .onChange(of: store.hasPendingRequest) { _, pending in
                if pending { presentIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in
                // A menu request made during another sheet waits for that sheet to close.
                schedulePresentation()
            }
            .sheet(item: $presentation, onDismiss: didDismiss) { presentation in
                WhatsNewSheet(
                    features: presentation.features,
                    onSeen: { store.markSeen([$0]) },
                    onDismiss: { self.presentation = nil },
                    onCallToAction: { action in
                        actionAfterDismissal = action
                        self.presentation = nil
                    }
                )
            }
            .onDisappear { store.endPresentation(owner: owner) }
    }

    private func presentIfNeeded() {
        guard presentation == nil, let window = windowReference.window,
              window.isKeyWindow, window.isVisible,
              window.sheetParent == nil, window.attachedSheet == nil else { return }
        let features = store.beginPresentation(owner: owner, automatically: automatically)
        guard !features.isEmpty else { return }
        batch = features
        presentation = WhatsNewPresentation(features: features)
    }

    private func schedulePresentation() {
        Task { @MainActor in
            // Let launch/restoration and any previous sheet dismissal finish first.
            try? await Task.sleep(for: .milliseconds(450))
            presentIfNeeded()
        }
    }

    private func didDismiss() {
        store.markSeen(batch)
        store.endPresentation(owner: owner)
        batch = []
        switch actionAfterDismissal {
        case .exploreMarketplace:
            openWindow(id: MarketplaceWindowID.value)
        case .startNewFilm:
            AppNavigation.shared.requestWelcomeRoute(.gallery)
            openWindow(id: WelcomeWindowID.value)
        case nil:
            break
        }
        actionAfterDismissal = nil
    }
}

private struct WhatsNewPresentation: Identifiable {
    let id = UUID()
    let features: [WhatsNewFeature]
}

private final class WhatsNewWindowReference {
    weak var window: NSWindow?
}

/// A scene-root modifier doesn't reliably inherit SwiftUI's controlActiveState.
/// Read its actual owning window so menu requests go to exactly that window.
private struct WhatsNewWindowReader: NSViewRepresentable {
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
