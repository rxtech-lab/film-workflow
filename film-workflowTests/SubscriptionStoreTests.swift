import Foundation
import RxSubscriptionIOS
import Testing

@testable import film_workflow

// MARK: - Fixtures

private func topUp(id: String, amount: Int, cents: Int = 0, eligible: Bool? = nil,
                   options: [(BillingProvider, PurchaseFlow)] = [(.stripe, .checkout)]) -> TopUpProduct {
    let optionsJSON = options.map { provider, flow in
        """
        {"provider": "\(provider.rawValue)", "flow": "\(flow.rawValue)", "productId": null, "productType": null}
        """
    }.joined(separator: ",")
    let eligibleJSON = eligible.map { "\($0)" } ?? "null"
    let json = """
    {
      "id": "\(id)", "key": "\(id)", "name": "Pack \(amount)", "description": null,
      "unit": "credits", "amount": \(amount), "priceAmountCents": \(cents == 0 ? amount : cents),
      "currency": "usd", "eligible": \(eligibleJSON), "blockedBy": null,
      "purchaseOptions": [\(optionsJSON)]
    }
    """
    return try! JSONDecoder().decode(TopUpProduct.self, from: Data(json.utf8))
}

private func entitlements(planStatuses: [String]) -> Entitlements {
    let plans = planStatuses.enumerated().map { index, status in
        """
        {
          "subscriptionId": "sub_\(index)", "purchaseId": null, "planId": "plan_\(index)",
          "planKey": "plan_\(index)", "planName": "Plan \(index)", "planGroup": "default",
          "status": "\(status)", "currentPeriodStart": null, "currentPeriodEnd": null,
          "cancelAtPeriodEnd": false, "billingProvider": "stripe", "providerProductId": null
        }
        """
    }.joined(separator: ",")
    let json = """
    {
      "user": {"id": "u1", "rxlabUserId": "rx1", "level": 0, "levelKey": null},
      "plans": [\(plans)], "roles": [], "permissions": [], "features": {},
      "balances": [], "usage": []
    }
    """
    return try! JSONDecoder().decode(Entitlements.self, from: Data(json.utf8))
}

// MARK: - Ordering

@Suite("Top-up ordering")
struct SubscriptionTopUpSortTests {
    @Test("Packs are ordered by credits, smallest first, whatever order the server sent")
    func ascendingByCredits() {
        let sorted = SubscriptionStore.sorted([
            topUp(id: "c", amount: 5000),
            topUp(id: "a", amount: 500),
            topUp(id: "b", amount: 2000),
        ])
        #expect(sorted.map(\.amount) == [500, 2000, 5000])
    }

    @Test("Packs the account cannot buy sink below the ones it can")
    func eligibleFirst() {
        let sorted = SubscriptionStore.sorted([
            topUp(id: "blocked-small", amount: 100, eligible: false),
            topUp(id: "open-large", amount: 9000, eligible: true),
            topUp(id: "open-small", amount: 200, eligible: true),
        ])
        #expect(sorted.map(\.id) == ["open-small", "open-large", "blocked-small"])
    }

    @Test("A missing eligibility flag counts as eligible")
    func nilEligibleCountsAsEligible() {
        // `eligible` is only populated when the catalog is fetched with
        // eligibility, so nil must not read as "blocked".
        let sorted = SubscriptionStore.sorted([
            topUp(id: "blocked", amount: 100, eligible: false),
            topUp(id: "unknown", amount: 900, eligible: nil),
        ])
        #expect(sorted.map(\.id) == ["unknown", "blocked"])
    }

    @Test("Equal credit amounts keep a stable order across refreshes")
    func stableTieBreak() {
        let first = SubscriptionStore.sorted([
            topUp(id: "z", amount: 100, cents: 500),
            topUp(id: "a", amount: 100, cents: 500),
        ])
        let second = SubscriptionStore.sorted([
            topUp(id: "a", amount: 100, cents: 500),
            topUp(id: "z", amount: 100, cents: 500),
        ])
        #expect(first.map(\.id) == ["a", "z"])
        #expect(first.map(\.id) == second.map(\.id))
    }
}

@Suite("Purchasable top-ups")
struct SubscriptionPurchasabilityTests {
    @Test("App Store only packs are not offered — this build cannot fulfil them")
    func dropsAppleOnly() {
        #expect(!SubscriptionStore.isStripePurchasable(
            topUp(id: "apple", amount: 100, options: [(.appleAppStore, .storeKit)])))
    }

    @Test("A pack with both rails is offered, bought through Stripe")
    func keepsMixed() {
        #expect(SubscriptionStore.isStripePurchasable(
            topUp(id: "both", amount: 100, options: [(.appleAppStore, .storeKit), (.stripe, .checkout)])))
    }

    @Test("No purchase options means the server's default rail, which is Stripe")
    func keepsEmptyOptions() {
        #expect(SubscriptionStore.isStripePurchasable(topUp(id: "plain", amount: 100, options: [])))
    }
}

// MARK: - Store

@Suite("Subscription store", .serialized)
@MainActor
struct SubscriptionStoreStateTests {
    @Test("An active or trialing plan entitles the account")
    func activeStatuses() async {
        for status in ["active", "trialing"] {
            let store = SubscriptionStore(
                loadEntitlements: { entitlements(planStatuses: [status]) },
                loadCatalog: { nil })
            await store.refresh()
            #expect(store.hasActiveSubscription, "\(status) should entitle")
            #expect(store.availability == .entitled)
        }
    }

    @Test("Lapsed plan statuses do not entitle the account")
    func inactiveStatuses() async {
        for status in ["canceled", "past_due", "incomplete", "unpaid", "paused"] {
            let store = SubscriptionStore(
                loadEntitlements: { entitlements(planStatuses: [status]) },
                loadCatalog: { nil })
            await store.refresh()
            #expect(!store.hasActiveSubscription, "\(status) should not entitle")
            #expect(store.availability == .notEntitled)
        }
    }

    @Test("One live plan among lapsed ones still entitles the account")
    func picksTheActivePlan() async {
        let store = SubscriptionStore(
            loadEntitlements: { entitlements(planStatuses: ["canceled", "active"]) },
            loadCatalog: { nil })
        await store.refresh()
        #expect(store.activePlan?.status == "active")
    }

    @Test("A failed fetch keeps the last known plan instead of reading as unsubscribed")
    func failureKeepsLastAnswer() async {
        // The gate hangs off this: a network blip must never look like a refusal.
        var shouldFail = false
        let store = SubscriptionStore(
            loadEntitlements: {
                if shouldFail { throw URLError(.notConnectedToInternet) }
                return entitlements(planStatuses: ["active"])
            },
            loadCatalog: { nil })
        await store.refresh()
        #expect(store.availability == .entitled)

        shouldFail = true
        await store.refresh()
        #expect(store.availability == .entitled)
        #expect(store.error != nil)
    }

    @Test("A failure with no prior answer leaves the question unanswered, not answered no")
    func failureWithoutPriorAnswerIsUnknown() async {
        let store = SubscriptionStore(
            loadEntitlements: { throw URLError(.timedOut) },
            loadCatalog: { nil })
        await store.refresh()
        #expect(store.availability == .unknown)
    }

    @Test("No client means unconfigured, which is not the same as unsubscribed")
    func nilClientIsUnconfigured() async {
        let store = SubscriptionStore(loadEntitlements: { nil }, loadCatalog: { nil })
        await store.refresh()
        #expect(store.availability == .unconfigured)
    }

    @Test("Clearing on sign-out drops every trace of the account")
    func clearResetsState() async {
        let store = SubscriptionStore(
            loadEntitlements: { entitlements(planStatuses: ["active"]) },
            loadCatalog: { nil })
        await store.refresh()
        store.clear()
        #expect(store.entitlements == nil)
        #expect(store.availability == .unconfigured)
        #expect(!store.hasActiveSubscription)
    }
}
