import SwiftUI

struct AccountRestorationView: View {
    let auth: AuthManager

    var body: some View {
        VStack(spacing: 16) {
            ProgressView("Restoring account…")
            if auth.restoreError != nil {
                Text("Couldn’t connect to your account. Retrying automatically.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry Now") { Task { await auth.checkExistingAuth() } }
                    .disabled(auth.isLoading)
            }
            Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
