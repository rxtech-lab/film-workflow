import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var showSavedAlert = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        Form {
            Section("Google AI API Key") {
                SecureField("Enter your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("Your API key is stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Save") {
                        saveKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    if showSavedAlert {
                        Text("Saved!")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 200)
        .onAppear {
            loadKey()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func loadKey() {
        if let config = try? AppConfig.loadFromKeychain() {
            apiKey = config.googleAIKey
        }
    }

    private func saveKey() {
        do {
            let config = AppConfig(googleAIKey: apiKey)
            try config.saveToKeychain()
            withAnimation {
                showSavedAlert = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSavedAlert = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
