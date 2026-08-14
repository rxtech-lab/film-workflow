import SwiftUI
import RxAuthSwift

@MainActor
struct AccountControl: View {
    enum Placement { case sidebarFooter, settingsHeader }

    let placement: Placement
    @State private var auth = AuthManager.shared
    @State private var balance = CreditBalanceStore.shared
    @State private var navigation = AppNavigation.shared

    var body: some View {
        if auth.isAuthenticated {
            Menu {
                Button("Account…") { navigation.showAccountSheet = true }
                #if os(macOS)
                Button("Add Credits…") { balance.openTopUp() }
                #endif
                Divider()
                Button("Sign Out", role: .destructive) {
                    Task { await auth.signOut() }
                }
            } label: {
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
            .menuStyle(.borderlessButton)
        } else {
            Button {
                navigation.showAccountSheet = true
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text("Sign in")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }
}

#if os(macOS)
struct AccountCommands: Commands {
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
                Button("Account…") { navigation.showAccountSheet = true }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Add Credits…") { balance.openTopUp() }
                Divider()
                Button("Sign Out") { Task { await auth.signOut() } }
            } else {
                Button("Sign In…") { navigation.showAccountSheet = true }
            }
        }
    }
}
#endif
