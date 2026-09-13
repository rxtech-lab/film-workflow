import RxAuthSwift
import RxAuthSwiftUI
import SwiftUI

/// The one place the app collects credentials.
///
/// Presented as a sheet from wherever a "Sign in" control lives, so the
/// Settings window and the account menus never embed the credential form
/// themselves. Dismisses on its own once the session is established.
struct SignInSheet: View {
    @State var auth = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // No title bar: the form carries its own heading. The Cancel control
        // floats over the form's top-trailing corner instead.
        ZStack(alignment: .topTrailing) {
            content
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Cancel")
            .accessibilityLabel("Cancel")
            .padding(16)
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if auth.isRestoring {
            AccountRestorationView(auth: auth)
                .task { await auth.checkExistingAuth() }
        } else if let manager = auth.oauthManager {
            RxSignInView(
                manager: manager,
                appearance: RxSignInAppearance(
                    title: "Sign in to RxLab",
                    subtitle: "Manage credits and subscription usage."
                ),
                style: .native,
                onAuthSuccess: {
                    Task { await auth.didSignIn() }
                    dismiss()
                }
            )
        } else {
            ContentUnavailableView {
                Label("Sign-in Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("RxLab sign-in is not configured for this build.")
            }
        }
    }
}

extension View {
    /// Presents `SignInSheet` on this window whenever `AppNavigation.requestSignIn()`
    /// fires, once the window is ready. Attach once at each window's root so
    /// menu commands, which have no view of their own, can still raise the sheet.
    func signInSheetPresenter(auth: AuthManager = .shared) -> some View {
        modifier(SignInSheetPresenter(auth: auth))
    }
}

private struct SignInSheetPresenter: ViewModifier {
    let auth: AuthManager
    @State private var navigation = AppNavigation.shared
    @State private var windowReference = SignInWindowReference()
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .background {
                SignInWindowReader { window in
                    windowReference.window = window
                    presentIfRequested()
                }
                .frame(width: 0, height: 0)
            }
            .onChange(of: navigation.signInRequestCount) { _, _ in
                presentIfRequested()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard notification.object as? NSWindow === windowReference.window else { return }
                presentIfRequested()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { notification in
                guard notification.object as? NSWindow === windowReference.window else { return }
                Task { @MainActor in
                    await Task.yield()
                    presentIfRequested()
                }
            }
            .sheet(isPresented: $isPresented) {
                SignInSheet(auth: auth)
            }
    }

    private func presentIfRequested() {
        if isPresented {
            // Repeated tool calls reuse the current sheet.
            _ = navigation.consumeSignInRequest()
            return
        }
        guard let window = windowReference.window, window.isKeyWindow,
              window.isVisible, window.sheetParent == nil, window.attachedSheet == nil,
              navigation.consumeSignInRequest(), !auth.isAuthenticated else { return }
        isPresented = true
    }
}

private final class SignInWindowReference {
    weak var window: NSWindow?
}

/// Scene-root modifiers do not reliably inherit SwiftUI's active-window state.
private struct SignInWindowReader: NSViewRepresentable {
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
