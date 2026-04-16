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
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                Text("Your API key is stored securely in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Save") {
                    saveKey()
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 450, height: 200)
        #endif
        .onAppear {
            loadKey()
        }
        .alert("Saved", isPresented: $showSavedAlert) {
            Button("OK") {}
        } message: {
            Text("Your API key has been saved to the Keychain.")
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
            showSavedAlert = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
