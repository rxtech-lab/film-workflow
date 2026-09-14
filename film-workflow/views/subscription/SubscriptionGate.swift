import RxAuthSwift
import RxSubscriptionIOS
import SwiftUI

/// What the gate should be doing right now.
///
/// Kept as a value with a pure `resolve` so the whole policy — which is the
/// part that can lock every user out of the product — is testable without
/// standing up SwiftUI.
enum SubscriptionGateState: Equatable {
    /// Nothing in the way.
    case open
    /// The session is still being restored. Never show a paywall here: it
    /// would flash on every cold launch before the answer arrives.
    case restoring
    case signedOut
    case unsubscribed
    /// Configured and signed in, but the service could not be reached and we
    /// have never had an answer.
    case unreachable
}

extension SubscriptionGateState {
    /// Whether this state puts a curtain over the app. `.unreachable` does
    /// not: see the fail-open note in `resolve`.
    var isBlocking: Bool {
        switch self {
        case .open, .unreachable: false
        case .restoring, .signedOut, .unsubscribed: true
        }
    }

    static func resolve(isBypassed: Bool,
                        authState: AuthenticationState,
                        availability: SubscriptionStore.Availability,
                        hasError: Bool) -> SubscriptionGateState {
        if isBypassed { return .open }
        switch authState {
        case .authenticated: break
        case .unauthenticated: return .signedOut
        default: return .restoring
        }
        switch availability {
        case .unconfigured, .entitled:
            return .open
        case .notEntitled:
            // Only a successful answer closes the gate.
            return .unsubscribed
        case .unknown:
            // A refusal we never heard is not a refusal. A network blip must
            // not lock a paying subscriber out of their own film packages, so
            // an unanswered question fails open — with a visible warning —
            // until the service says otherwise.
            return hasError ? .unreachable : .restoring
        }
    }
}

enum SubscriptionGate {
    /// Contexts where the gate must never run: tests (the keychain read alone
    /// would stall the runner), and any build without a publishable key, which
    /// is how this repo ships today.
    static var isBypassed: Bool {
        if ProcessInfo.processInfo.arguments.contains("-forceSubscriptionGate") { return false }
        return NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains("-uiTesting")
            || ProcessInfo.processInfo.arguments.contains("-skipStartupAuth")
            || !BackendConfig.hasSubscriptionConfiguration
    }
}

extension View {
    /// Blocks this window until the account holds an active subscription.
    /// Attach at each window root, beside `signInSheetPresenter()`.
    func subscriptionGate() -> some View {
        modifier(SubscriptionGatePresenter())
    }
}

private struct SubscriptionGatePresenter: ViewModifier {
    @State private var auth = AuthManager.shared
    @State private var store = SubscriptionStore.shared
    @State private var navigation = AppNavigation.shared
    @State private var windowReference = KeyWindowReference()
    @State private var isShowingPaywall = false

    private var state: SubscriptionGateState {
        .resolve(isBypassed: SubscriptionGate.isBypassed,
                 authState: auth.authState,
                 availability: store.availability,
                 hasError: store.error != nil)
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if state.isBlocking {
                // An opaque curtain, not just a sheet: `ServerPaywallView`
                // dismisses itself and Esc closes any sheet, either of which
                // would otherwise hand back a fully usable editor.
                SubscriptionGateCurtain(state: state,
                                        onChoosePlan: { presentPaywallIfPossible() })
                    .transition(.opacity)
            } else if state == .unreachable {
                // Fail open. An unanswered question is not a refusal, and a
                // network blip must not lock a paying subscriber out of their
                // own film packages — so the app stays usable and only says so.
                SubscriptionUnreachableBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: state)
        .trackingKeyWindow(windowReference) { presentPaywallIfPossible() }
        .onChange(of: state) { _, new in
            if new == .signedOut { navigation.requestSignIn() }
            if new == .unsubscribed { presentPaywallIfPossible() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A plan bought in the browser reaches us no other way: the
            // package's paywall reports nothing back to its host.
            guard !SubscriptionGate.isBypassed, auth.isAuthenticated else { return }
            Task { await store.refreshEntitlements() }
        }
        .sheet(isPresented: $isShowingPaywall) {
            // Deliberately no re-presentation on dismiss: the curtain still
            // blocks the app, and re-raising the sheet on every Esc would make
            // an inescapable modal loop.
            Task { await store.refreshEntitlements() }
        } content: {
            SubscriptionPaywallSheet()
        }
    }

    private func presentPaywallIfPossible() {
        guard state == .unsubscribed, !isShowingPaywall,
              windowReference.isReadyForSheet,
              SubscriptionService.shared.client() != nil else { return }
        isShowingPaywall = true
    }
}

/// The package's server-driven paywall, wrapped so it can be dismissed from a
/// window that has no navigation of its own.
private struct SubscriptionPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let client = SubscriptionService.shared.client() {
                // `sections`, `initialSection` and any header are ignored on
                // the `.server` path, so passing them would only mislead.
                PaywallView(client: client, paywall: .server)
            } else {
                ContentUnavailableView {
                    Label("Plans Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Couldn’t reach the subscription service. Try again in a moment.")
                }
            }
        }
        .frame(minWidth: 620, minHeight: 640)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .padding(16)
        }
    }
}

private struct SubscriptionGateCurtain: View {
    let state: SubscriptionGateState
    let onChoosePlan: () -> Void

    @State private var auth = AuthManager.shared
    @State private var store = SubscriptionStore.shared
    @State private var navigation = AppNavigation.shared

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            content
                .padding(40)
        }
        // Swallows clicks and keystrokes aimed at whatever is underneath.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .open:
            EmptyView()
        case .restoring:
            AccountRestorationView(auth: auth)
        case .signedOut:
            ContentUnavailableView {
                Label("Sign In to Continue", systemImage: "person.crop.circle")
            } description: {
                Text("RxFilm Studio needs your RxLab account to check your subscription.")
            } actions: {
                Button("Sign In…") { navigation.requestSignIn() }
                    .buttonStyle(.borderedProminent)
            }
        case .unsubscribed:
            ContentUnavailableView {
                Label("Subscription Required", systemImage: "star.circle")
            } description: {
                Text("Choose a plan to use RxFilm Studio.")
            } actions: {
                Button("Choose a Plan") { onChoosePlan() }
                    .buttonStyle(.borderedProminent)
                Button("Account…") { navigation.showAccountSettings() }
            }
        case .unreachable:
            // Handled by the banner, not the curtain.
            EmptyView()
        }
    }
}

/// Shown over a still-usable app when the subscription could not be verified.
private struct SubscriptionUnreachableBanner: View {
    @State private var store = SubscriptionStore.shared
    @State private var isDismissed = false

    var body: some View {
        if !isDismissed {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                Text("Couldn’t verify your subscription. You can keep working.")
                    .font(.callout)
                Button("Retry") { Task { await store.refreshEntitlements() } }
                    .buttonStyle(.link)
                Button {
                    isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.quaternary))
            .padding(.top, 10)
            .shadow(radius: 6, y: 2)
        }
    }
}
