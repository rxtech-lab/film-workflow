import RxAuthSwift
import RxAuthSwiftUI
import SwiftUI

/// The one place the app collects credentials.
///
/// Presented as a sheet from wherever a "Sign in" control lives, so the
/// Settings window and the account menus never embed the credential form
/// themselves. Dismisses on its own once the session is established.
struct SignInSheet: View {
    @State private var auth = AuthManager.shared
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
    /// fires while the window is active. Attach once at each window's root so
    /// menu commands, which have no view of their own, can still raise the sheet.
    func signInSheetPresenter() -> some View {
        modifier(SignInSheetPresenter())
    }
}

private struct SignInSheetPresenter: ViewModifier {
    @State private var navigation = AppNavigation.shared
    @Environment(\.appearsActive) private var appearsActive
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: navigation.signInRequestCount) { _, _ in
                // Only the active window answers, otherwise every open window
                // would present its own copy of the sheet.
                guard appearsActive else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                SignInSheet()
            }
    }
}
