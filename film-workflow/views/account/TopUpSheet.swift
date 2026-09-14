import RxSubscriptionIOS
import SwiftUI

/// Buying credits without leaving the app.
///
/// Deliberately not the package's own `TopUpView`: that renders packs in raw
/// server order and routes anything carrying an App Store option through
/// StoreKit, which a Sparkle build cannot fulfil. This shows the same packs in
/// credit order and always buys through Stripe checkout.
struct TopUpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TopUpList()
                .navigationTitle("Add Credits")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

struct TopUpList: View {
    @State private var store = SubscriptionStore.shared
    @State private var balance = CreditBalanceStore.shared
    @State private var purchasingID: String?
    @State private var error: String?
    /// Set once checkout has been handed to the browser. The purchase completes
    /// out there, so from here on the only thing to do is wait and re-read.
    @State private var awaitingCheckout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                balanceHeader
                if awaitingCheckout {
                    checkoutPending
                } else {
                    content
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .task { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The purchase happens in a browser, and the package tells us
            // nothing when it finishes, so coming back to the app is the signal.
            Task { await refreshAfterCheckout() }
        }
        .alert("Couldn’t Start Checkout", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var balanceHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Available credits").font(.subheadline).foregroundStyle(.secondary)
            Text(balance.availablePoints.formatted())
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var content: some View {
        let purchasable = store.purchasableTopUps
        if store.isLoading && purchasable.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if purchasable.isEmpty {
            // Either the catalog is empty or every pack is App Store only. The
            // browser page can still sell them, so it is offered rather than
            // leaving the user stuck.
            ContentUnavailableView {
                Label("No Credit Packs Available", systemImage: "plus.circle")
            } description: {
                Text(store.error ?? String(localized: "No packs are on sale for this account right now."))
            } actions: {
                Button("Open Credits Page") { balance.openTopUp() }
            }
        } else {
            let eligible = purchasable.filter { $0.eligible != false }
            let blocked = purchasable.filter { $0.eligible == false }
            if !eligible.isEmpty { section("Available", items: eligible) }
            if !blocked.isEmpty { section("Not Available", items: blocked) }
        }
    }

    private func section(_ title: String, items: [TopUpProduct]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(items) { topUp in
                TopUpCard(
                    topUp: topUp,
                    price: SubscriptionFormatting.price(cents: topUp.priceAmountCents,
                                                        currency: topUp.currency),
                    isLoading: purchasingID == topUp.id
                ) {
                    Task { await purchase(topUp) }
                }
            }
        }
    }

    private var checkoutPending: some View {
        ContentUnavailableView {
            Label("Finish in Your Browser", systemImage: "safari")
        } description: {
            Text("Complete the purchase in the browser window that just opened. Your balance updates here once it clears.")
        } actions: {
            Button("I’ve Completed the Purchase") {
                Task { await refreshAfterCheckout(force: true) }
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") { awaitingCheckout = false }
        }
        .padding(.vertical, 20)
    }

    private func purchase(_ topUp: TopUpProduct) async {
        guard topUp.eligible != false,
              SubscriptionStore.isStripePurchasable(topUp),
              let client = SubscriptionService.shared.client() else { return }
        purchasingID = topUp.id
        defer { purchasingID = nil }
        do {
            let session = try await client.checkoutTopUp(
                id: topUp.id,
                successURL: SubscriptionCheckout.successURL,
                cancelURL: SubscriptionCheckout.cancelURL
            )
            SubscriptionCheckout.open(session.checkoutURL)
            awaitingCheckout = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stripe settles through a webhook, so the balance can lag the purchase by
    /// a moment. This never reports failure — it just re-reads.
    private func refreshAfterCheckout(force: Bool = false) async {
        guard awaitingCheckout || force else { return }
        await balance.refresh()
        await store.refresh()
        awaitingCheckout = false
    }
}

extension View {
    /// Presents `TopUpSheet` whenever `AppNavigation.requestTopUp()` fires.
    /// Attach once at each window's root, like `signInSheetPresenter()`.
    func topUpSheetPresenter() -> some View {
        modifier(TopUpSheetPresenter())
    }
}

private struct TopUpSheetPresenter: ViewModifier {
    @State private var navigation = AppNavigation.shared
    @State private var windowReference = KeyWindowReference()
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .trackingKeyWindow(windowReference) { presentIfRequested() }
            .onChange(of: navigation.topUpRequestCount) { _, _ in
                presentIfRequested()
            }
            .sheet(isPresented: $isPresented) {
                TopUpSheet()
            }
    }

    private func presentIfRequested() {
        if isPresented {
            _ = navigation.consumeTopUpRequest()
            return
        }
        guard windowReference.isReadyForSheet,
              navigation.consumeTopUpRequest() else { return }
        isPresented = true
    }
}
