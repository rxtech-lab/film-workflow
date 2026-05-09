import SwiftUI

struct AIProviderSettingsView: View {
    @State private var googleKey: String = ""
    @State private var azureKey: String = ""
    @State private var azureEndpoint: String = ""
    @State private var openAIEndpoint: String = ""
    @State private var openAIKey: String = ""
    @State private var openAIModel: String = ""
    @State private var defaultImageModel: String = ""
    @State private var showSavedAlert = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isTestingAzure = false
    @State private var azureTestResult: String?

    @State private var chatModels: [OpenAIModelInfo] = []
    @State private var isLoadingChatModels = false
    @State private var chatModelsError: String?

    @State private var imageModels: [OpenAIModelInfo] = []
    @State private var isLoadingImageModels = false
    @State private var imageModelsError: String?

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
                TextField("Endpoint (e.g. https://api.openai.com/v1)", text: $openAIEndpoint)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    #endif

                SecureField("API key", text: $openAIKey)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                HStack {
                    Picker("Default chat model", selection: $openAIModel) {
                        if openAIModel.isEmpty {
                            Text("Select a model").tag("")
                        } else if !chatModels.contains(where: { $0.id == openAIModel }) {
                            Text(openAIModel).tag(openAIModel)
                        }
                        ForEach(chatModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }

                    Button {
                        Task { await loadChatModels(forceRefresh: true) }
                    } label: {
                        if isLoadingChatModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingChatModels || canFetchChatModels == false)
                    .help("Refresh model list")
                }

                if let chatModelsError {
                    Text(chatModelsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("OpenAI-compatible LLM")
            } footer: {
                Text("Used to generate and edit Remotion compositions. Works with OpenAI, Azure OpenAI, OpenRouter, Ollama, LM Studio, etc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Picker("Default image model", selection: $defaultImageModel) {
                        Text("None").tag("")
                        if !defaultImageModel.isEmpty,
                           !imageModels.contains(where: { $0.id == defaultImageModel }) {
                            Text(defaultImageModel).tag(defaultImageModel)
                        }
                        ForEach(imageModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }

                    Button {
                        Task { await loadImageModels(forceRefresh: true) }
                    } label: {
                        if isLoadingImageModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingImageModels || canFetchChatModels == false)
                    .help("Refresh model list")
                }

                if let imageModelsError {
                    Text(imageModelsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Default image model")
            } footer: {
                Text("Used by the Remotion agent's generate_image tool. Reuses the OpenAI endpoint and key above.")
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
        .onAppear {
            loadKeys()
            Task { await loadChatModels(forceRefresh: false) }
            Task { await loadImageModels(forceRefresh: false) }
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

    private var canFetchChatModels: Bool {
        !openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasAnyChange: Bool {
        !googleKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !azureKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !azureEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !defaultImageModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadKeys() {
        if let config = try? AppConfig.loadFromKeychain() {
            googleKey = config.googleAIKey
            azureKey = config.azureSpeechKey
            azureEndpoint = config.azureSpeechEndpoint
            openAIEndpoint = config.openAIEndpoint
            openAIKey = config.openAIKey
            openAIModel = config.openAIModel
            defaultImageModel = config.defaultImageModel
        }
    }

    private func saveKeys() {
        do {
            let config = AppConfig(
                googleAIKey: googleKey,
                azureSpeechKey: azureKey,
                azureSpeechEndpoint: azureEndpoint,
                openAIEndpoint: openAIEndpoint,
                openAIKey: openAIKey,
                openAIModel: openAIModel,
                defaultImageModel: defaultImageModel
            )
            try config.saveToKeychain()
            showSavedAlert = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func loadChatModels(forceRefresh: Bool) async {
        guard canFetchChatModels else { return }
        isLoadingChatModels = true
        chatModelsError = nil
        defer { isLoadingChatModels = false }
        do {
            let models = try await OpenAIModelsClient.shared.chatModels(
                endpoint: openAIEndpoint,
                apiKey: openAIKey,
                forceRefresh: forceRefresh
            )
            chatModels = models
        } catch {
            chatModelsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadImageModels(forceRefresh: Bool) async {
        guard canFetchChatModels else { return }
        isLoadingImageModels = true
        imageModelsError = nil
        defer { isLoadingImageModels = false }
        do {
            let models = try await OpenAIModelsClient.shared.imageModels(
                endpoint: openAIEndpoint,
                apiKey: openAIKey,
                forceRefresh: forceRefresh
            )
            imageModels = models
        } catch {
            imageModelsError = error.localizedDescription
        }
    }

    @MainActor
    private func testAzure() async {
        isTestingAzure = true
        azureTestResult = nil
        defer { isTestingAzure = false }

        do {
            let config = AppConfig(
                googleAIKey: googleKey,
                azureSpeechKey: azureKey,
                azureSpeechEndpoint: azureEndpoint,
                openAIEndpoint: openAIEndpoint,
                openAIKey: openAIKey,
                openAIModel: openAIModel,
                defaultImageModel: defaultImageModel
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
