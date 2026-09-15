import RxAuthSwift
import RxSubscriptionIOS
import SwiftUI

struct AccountSheet: View {
    @State private var auth = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountDetailContent()
                .navigationTitle("Account")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 580)
        #endif
    }
}

struct AccountDetailContent: View {
    @State private var auth = AuthManager.shared
    @State private var balance = CreditBalanceStore.shared
    @State private var usage = UsageHistoryStore.shared
    @State private var subscription = SubscriptionStore.shared
    @State private var navigation = AppNavigation.shared
    @State private var confirmSignOut = false
    @State private var refreshError: String?

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        planCard
                        balanceCard
                        usageSummary
                        recentUsage
                        footer
                    }
                    .padding(24)
                }
                .task { await refresh() }
            } else if auth.isRestoring {
                AccountRestorationView(auth: auth)
            } else {
                // Credentials are collected in `SignInSheet`, never inline here.
                ContentUnavailableView {
                    Label("Account Not Signed In", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("Sign in to your RxLab account to manage credits and subscription usage.")
                } actions: {
                    Button("Sign In…") { navigation.requestSignIn() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert("Couldn’t Refresh Account", isPresented: Binding(
            get: { refreshError != nil },
            set: { if !$0 { refreshError = nil } }
        )) {
            Button("OK") { refreshError = nil }
        } message: {
            Text(refreshError ?? "")
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
        } message: {
            Text("You will need to sign in again to use subscription credits.")
        }
    }

    /// Omitted entirely when no publishable key is configured — there is no
    /// plan to report, and an empty card would only raise questions.
    @ViewBuilder
    private var planCard: some View {
        if subscription.availability != .unconfigured {
            VStack(alignment: .leading, spacing: 8) {
                Text("Subscription").foregroundStyle(.secondary)
                if let plan = subscription.activePlan {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(plan.planName).font(.title2.weight(.semibold))
                        if plan.status == "trialing" {
                            Text("Trial")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                    }
                    if let renewal = plan.currentPeriodEnd {
                        Text(plan.cancelAtPeriodEnd
                             ? "Ends \(renewal.formatted(date: .abbreviated, time: .omitted))"
                             : "Renews \(renewal.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(plan.cancelAtPeriodEnd ? .orange : .secondary)
                    }
                    Button("Manage Subscription") { Task { await openBillingPortal() } }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                } else if subscription.availability == .notEntitled {
                    Text("No active plan").font(.title3.weight(.medium))
                    Text("A subscription is required to use AI features.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    // `.unknown` — the question has not been answered yet, so
                    // say so rather than implying the user has no plan.
                    Text("Checking subscription…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func openBillingPortal() async {
        guard let client = SubscriptionService.shared.client() else { return }
        do {
            let session = try await client.billingPortal(returnURL: BackendConfig.webBaseURL)
            SubscriptionCheckout.open(session.url)
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Available credits").foregroundStyle(.secondary)
                Spacer()
                Button { Task { await refresh() } } label: {
                    if balance.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain)
            }
            Text(balance.availablePoints.formatted())
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            if balance.reservedPoints > 0 {
                Text("\(balance.reservedPoints.formatted()) reserved for work in progress")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
                Button("Add Credits") { SubscriptionCheckout.presentTopUp() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            #endif
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage by capability").font(.headline)
            if usage.grouped.isEmpty {
                Text("No metered usage yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(usage.grouped) { group in
                    HStack {
                        Label(group.capability.capitalized, systemImage: icon(group.capability))
                        Spacer()
                        Text("\(group.points.formatted()) credits")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var recentUsage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent usage").font(.headline)
            ForEach(usage.entries.prefix(20)) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.feature)
                        Text([entry.provider, entry.model].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("−\(entry.chargedPoints.formatted())")
                        .monospacedDigit()
                }
                Divider()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Link("View full history in browser", destination: BackendConfig.webBaseURL.appending(path: "usage"))
            HStack {
                Text(auth.currentUser?.email ?? auth.currentUser?.name ?? String(localized: "RxLab account"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign Out") { confirmSignOut = true }
            }
            .font(.caption)
        }
    }

    private func refresh() async {
        async let balanceRefresh: Void = balance.refresh()
        async let usageRefresh: Void = usage.refresh()
        async let subscriptionRefresh: Void = subscription.refresh()
        _ = await (balanceRefresh, usageRefresh, subscriptionRefresh)
        refreshError = balance.error ?? usage.error
    }

    private func icon(_ capability: String) -> String {
        switch capability {
        case "image": "photo"
        case "speech": "waveform"
        case "music": "music.note"
        case "transcription": "captions.bubble"
        default: "sparkles"
        }
    }
}
