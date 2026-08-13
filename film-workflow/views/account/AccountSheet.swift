import RxAuthSwift
import RxAuthSwiftUI
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
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        balanceCard
                        usageSummary
                        recentUsage
                        footer
                    }
                    .padding(24)
                }
                .task { await refresh() }
            } else if let manager = auth.oauthManager {
                RxSignInView(
                    manager: manager,
                    appearance: RxSignInAppearance(
                        title: "Sign in to RxLab",
                        subtitle: "Manage credits and subscription usage.",
                    ),
                    style: .native,
                    onAuthSuccess: { Task { await CreditBalanceStore.shared.refresh() } }
                )
            } else {
                ContentUnavailableView {
                    Label("Sign in to RxLab", systemImage: "person.crop.circle")
                } description: {
                    Text("Use your account to manage credits and subscription usage.")
                } actions: {
                    Button("Sign in") { Task { await auth.signIn() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
        } message: {
            Text("You will need to sign in again to use subscription credits.")
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
                Button("Add Credits") { balance.openTopUp() }
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
                Text(auth.currentUser?.email ?? auth.currentUser?.name ?? "RxLab account")
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
        _ = await (balanceRefresh, usageRefresh)
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
