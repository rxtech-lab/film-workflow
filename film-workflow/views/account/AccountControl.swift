import SwiftUI
import RxAuthSwift

@MainActor
struct AccountControl: View {
    enum Placement { case sidebarFooter, settingsHeader, toolbar }

    let placement: Placement
    @Environment(\.openSettings) private var openSettings
    @State var auth = AuthManager.shared
    @State private var balance = CreditBalanceStore.shared
    @State private var navigation = AppNavigation.shared

    var body: some View {
        if auth.isAuthenticated {
            Menu {
                if placement == .toolbar {
                    Text(auth.currentUser?.email ?? auth.currentUser?.name ?? "RxLab account")
                    Text("\(balance.availablePoints.formatted()) credits")
                    Divider()
                }
                Button("Account…") { navigation.showAccountSettings(); openSettings() }
                #if os(macOS)
                Button("Add Credits…") { balance.openTopUp() }
                #endif
                Divider()
                Button("Sign Out", role: .destructive) {
                    Task { await auth.signOut() }
                }
            } label: {
                if placement == .toolbar {
                    Label("Account", systemImage: "person.crop.circle.fill")
                        .labelStyle(.iconOnly)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(auth.currentUser?.email ?? auth.currentUser?.name ?? "RxLab account")
                                .lineLimit(1)
                            Text("\(balance.availablePoints.formatted()) credits")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .help("Account")
        } else if auth.isRestoring {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if placement != .toolbar {
                    Text("Restoring account…")
                    Spacer()
                }
            }
            .accessibilityLabel("Restoring account…")
            .help("Restoring account…")
        } else {
            Button {
                navigation.requestSignIn()
            } label: {
                if placement == .toolbar {
                    Label("Sign in", systemImage: "person.crop.circle")
                        .labelStyle(.iconOnly)
                } else {
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text("Sign in")
                        Spacer()
                    }
                }
            }
            .help("Sign in")
        }
    }
}

#if os(macOS)
struct AccountCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    @State private var auth = AuthManager.shared
    @State private var balance = CreditBalanceStore.shared
    @State private var navigation = AppNavigation.shared

    var body: some Commands {
        CommandMenu("Account") {
            if auth.isAuthenticated {
                Button(auth.currentUser?.email ?? auth.currentUser?.name ?? "RxLab account") {}
                    .disabled(true)
                Button("\(balance.availablePoints.formatted()) credits") {}
                    .disabled(true)
                Divider()
                Button("Account…") { navigation.showAccountSettings(); openSettings() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Add Credits…") { balance.openTopUp() }
                Divider()
                Button("Sign Out") { Task { await auth.signOut() } }
            } else if auth.isRestoring {
                Button("Restoring account…") {}.disabled(true)
                Button("Retry") { Task { await auth.checkExistingAuth() } }.disabled(auth.isLoading)
                Button("Sign Out") { Task { await auth.signOut() } }
            } else {
                Button("Sign In…") { navigation.requestSignIn() }
            }
        }
    }
}
#endif
