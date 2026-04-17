import SwiftUI

struct SettingsView: View {
    @State private var googleKey: String = ""
    @State private var azureKey: String = ""
    @State private var azureEndpoint: String = ""
    @State private var showSavedAlert = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isTestingAzure = false
    @State private var azureTestResult: String?

    var body: some View {
        Form {
            Section {
                SecureField("Enter your API key", text: $googleKey)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                Text("Your API key is stored securely in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(
                    "Get a Gemini API key →",
                    destination: URL(string: "https://aistudio.google.com/u/3/api-keys")!
                )
                .font(.caption)
            } header: {
                Text("Google AI API Key")
            }

            Section {
                SecureField("Subscription key", text: $azureKey)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                TextField("Region or endpoint", text: $azureEndpoint)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    #endif

                Button {
                    Task { await testAzure() }
                } label: {
                    HStack {
                        if isTestingAzure {
                            ProgressView().controlSize(.small)
                        }
                        Text(isTestingAzure ? "Loading Voices…" : "Test Connection")
                    }
                }
                .disabled(isTestingAzure || azureKey.trimmingCharacters(in: .whitespaces).isEmpty || azureEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)

                if let result = azureTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Loaded") ? .green : .red)
                }

                Link(
                    "Get an Azure Speech key →",
                    destination: URL(string: "https://portal.azure.com/#view/Microsoft_Azure_ProjectOxford/CognitiveServicesHub/~/SpeechServices")!
                )
                .font(.caption)
            } header: {
                Text("Azure Speech")
            } footer: {
                Text("Paste your region (e.g. \"eastus\") or any endpoint URL from the portal — we'll derive the TTS endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Save") {
                    saveKeys()
                }
                .disabled(!hasAnyChange)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 520, height: 420)
        #endif
        .onAppear {
            loadKeys()
        }
        .alert("Saved", isPresented: $showSavedAlert) {
            Button("OK") {}
        } message: {
            Text("Your keys have been saved to the Keychain.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var hasAnyChange: Bool {
        !googleKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !azureKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !azureEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadKeys() {
        if let config = try? AppConfig.loadFromKeychain() {
            googleKey = config.googleAIKey
            azureKey = config.azureSpeechKey
            azureEndpoint = config.azureSpeechEndpoint
        }
    }

    private func saveKeys() {
        do {
            let config = AppConfig(
                googleAIKey: googleKey,
                azureSpeechKey: azureKey,
                azureSpeechEndpoint: azureEndpoint
            )
            try config.saveToKeychain()
            showSavedAlert = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func testAzure() async {
        isTestingAzure = true
        azureTestResult = nil
        defer { isTestingAzure = false }

        // Persist first so the store reads the latest values.
        do {
            let config = AppConfig(
                googleAIKey: googleKey,
                azureSpeechKey: azureKey,
                azureSpeechEndpoint: azureEndpoint
            )
            try config.saveToKeychain()
        } catch {
            azureTestResult = "Could not save credentials: \(error.localizedDescription)"
            return
        }

        await AzureVoiceStore.shared.refresh()

        if let err = AzureVoiceStore.shared.lastError {
            azureTestResult = err
        } else {
            azureTestResult = "Loaded \(AzureVoiceStore.shared.voices.count) voices."
        }
    }
}
