import Foundation
import RxAuthSwift
import Testing

@testable import film_workflow

/// The gate is the one change here that can lock every user out of the
/// product, so its policy is a pure function and every branch is pinned.
@Suite("Subscription gate policy")
struct SubscriptionGateStateTests {
    private func resolve(auth: AuthenticationState,
                         availability: SubscriptionStore.Availability,
                         hasError: Bool = false,
                         bypassed: Bool = false) -> SubscriptionGateState {
        .resolve(isBypassed: bypassed, authState: auth,
                 availability: availability, hasError: hasError)
    }

    @Test("A bypassed build is never gated, whatever the account looks like")
    func bypassWins() {
        #expect(resolve(auth: .unauthenticated, availability: .notEntitled, bypassed: true) == .open)
    }

    @Test("The paywall never flashes while the session is still being restored")
    func restoringNeverShowsPaywall() {
        let state = resolve(auth: .unknown, availability: .notEntitled)
        #expect(state == .restoring)
        #expect(state != .unsubscribed)
    }

    @Test("Signed out asks for sign-in rather than for money")
    func signedOut() {
        #expect(resolve(auth: .unauthenticated, availability: .unknown) == .signedOut)
    }

    @Test("An active plan opens the app")
    func entitled() {
        #expect(resolve(auth: .authenticated, availability: .entitled) == .open)
    }

    @Test("A server answer of 'no plan' closes the gate")
    func notEntitled() {
        #expect(resolve(auth: .authenticated, availability: .notEntitled) == .unsubscribed)
    }

    @Test("No publishable key leaves the app exactly as it was before")
    func unconfigured() {
        #expect(resolve(auth: .authenticated, availability: .unconfigured) == .open)
    }

    @Test("An unanswered question waits rather than accusing the user")
    func unknownWithoutError() {
        #expect(resolve(auth: .authenticated, availability: .unknown) == .restoring)
    }

    @Test("An unreachable service fails open — a blip must not lock out a subscriber")
    func unknownWithError() {
        let state = resolve(auth: .authenticated, availability: .unknown, hasError: true)
        #expect(state == .unreachable)
        #expect(!state.isBlocking)
    }

    @Test("Only the states that should stop work actually block it")
    func blockingStates() {
        #expect(SubscriptionGateState.restoring.isBlocking)
        #expect(SubscriptionGateState.signedOut.isBlocking)
        #expect(SubscriptionGateState.unsubscribed.isBlocking)
        #expect(!SubscriptionGateState.open.isBlocking)
        #expect(!SubscriptionGateState.unreachable.isBlocking)
    }
}

@Suite("Subscription configuration")
struct SubscriptionConfigTests {
    private let url = URL(string: "https://subscription.rxlab.app")

    @Test("An empty or blank key disables subscription features rather than half-enabling them")
    func emptyKey() {
        #expect(!BackendConfig.hasSubscriptionConfiguration(key: "", url: url))
        #expect(!BackendConfig.hasSubscriptionConfiguration(key: "   ", url: url))
    }

    @Test("An xcconfig variable that never expanded is not a key")
    func unexpandedKey() {
        #expect(!BackendConfig.hasSubscriptionConfiguration(
            key: "$(APP_SUBSCRIPTION_PUBLISHABLE_KEY)", url: url))
    }

    @Test("A real key with a real URL enables subscription features")
    func validKey() {
        #expect(BackendConfig.hasSubscriptionConfiguration(key: "rxs_pk_live_abc123", url: url))
    }

    @Test("A key without a usable URL is not enough")
    func missingURL() {
        #expect(!BackendConfig.hasSubscriptionConfiguration(key: "rxs_pk_live_abc123", url: nil))
    }

    @Test("The subscription service defaults to production")
    func defaultURL() {
        #expect(BackendConfig.subscriptionURL.host == "subscription.rxlab.app")
    }

    @Test("Diagnostics report whether a key is present but never what it is")
    func diagnosticsHideTheKey() {
        let diagnostics = BackendConfig.diagnostics
        #expect(diagnostics.contains("subscription="))
        #expect(!diagnostics.contains("rxs_pk"))
    }
}
