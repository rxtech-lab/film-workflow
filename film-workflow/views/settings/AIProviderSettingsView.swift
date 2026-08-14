import SwiftUI
import TipKit

struct AIProviderSettingsView: View {
    @State private var credentialMode: CredentialMode = .byok
    @State private var googleKey: String = ""
    @State private var azureKey: String = ""
    @State private var azureEndpoint: String = ""
    @State private var openAIEndpoint: String = ""
    @State private var openAIKey: String = ""
    @State private var openAIModel: String = ""
    @State private var defaultImageModel: String = ""
    @State private var defaultVideoModel: String = ""
    // Owned by Settings › Captions, but round-tripped here so saving this form
    // can't blank them out.
    @State private var openAITranscriptionModel: String = ""
    @State private var geminiTranscriptionModel: String = ""
    @State private var claudeCodeModel: String = ""
    @State private var codexModel: String = ""
    @State private var codexReasoningEffort: String = ""
    @State private var subscriptionChatModel: String = ""
    @State private var subscriptionImageModel: String = ""
    @State private var subscriptionTranscriptionModel: String = ""
    @State private var subscriptionModels: [PickableModel] = []
    @State private var isLoadingSubscriptionModels = false
    @State private var subscriptionModelsError: String?
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

    @State private var veoModels: [GoogleModelInfo] = []
    @State private var isLoadingVeoModels = false
    @State private var veoModelsError: String?

    @State private var modelCatalog = AgentModelCatalog.shared

    var body: some View {
        Form {
            Section {
                Picker("AI credentials", selection: $credentialMode) {
                    ForEach(CredentialMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .popoverTip(FilmWorkflowTips.SubscriptionCreditsTip(), arrowEdge: .top)

                if credentialMode == .subscription {
                    HStack {
                        Image(systemName: AuthManager.shared.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(AuthManager.shared.isAuthenticated ? .green : .orange)
                        Text(AuthManager.shared.isAuthenticated
                            ? "Using your RxLab account balance"
                            : "Sign in on the Account tab before generating")
                        Spacer()
                        if AuthManager.shared.isAuthenticated {
                            Text("\(CreditBalanceStore.shared.availablePoints) credits")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            } header: {
                Text("Credential mode")
            }

            if credentialMode == .byok {
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
                HStack {
                    Picker("Default video model", selection: $defaultVideoModel) {
                        Text("None").tag("")
                        if !defaultVideoModel.isEmpty,
                           !veoModels.contains(where: { $0.id == defaultVideoModel }) {
                            Text(defaultVideoModel).tag(defaultVideoModel)
                        }
                        ForEach(veoModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }

                    Button {
                        Task { await loadVeoModels(forceRefresh: true) }
                    } label: {
                        if isLoadingVeoModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingVeoModels || googleKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Refresh model list")
                }

                if let veoModelsError {
                    Text(veoModelsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Default video model")
            } footer: {
                Text("Prefilled on new video projects. Uses the Google AI API key above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .popoverTip(FilmWorkflowTips.AIProviderTip(), arrowEdge: .top)

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
                Text("Used by the agent window and by caption AI tasks. Works with OpenAI, Azure OpenAI, OpenRouter, Ollama, LM Studio, etc.")
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
                Text("Used by the agent's image generation tools. Reuses the OpenAI endpoint and key above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            } else {
                Section {
                    subscriptionPicker(
                        "Chat model",
                        capability: .chat,
                        selection: $subscriptionChatModel
                    )
                    subscriptionPicker(
                        "Default image model",
                        capability: .image,
                        selection: $subscriptionImageModel
                    )
                    subscriptionPicker(
                        "Transcription model",
                        capability: .transcription,
                        selection: $subscriptionTranscriptionModel
                    )

                    if isLoadingSubscriptionModels {
                        ProgressView("Loading subscription catalog…")
                            .controlSize(.small)
                    }
                    if let subscriptionModelsError {
                        Text(subscriptionModelsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Refresh model catalog") {
                        Task { await loadSubscriptionModels(forceRefresh: true) }
                    }
                    .disabled(isLoadingSubscriptionModels || !AuthManager.shared.isAuthenticated)
                } header: {
                    Text("Subscription models")
                } footer: {
                    Text("Provider credentials stay on the RxFilm server. Model prices are estimates; actual usage is deducted after each operation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if os(macOS)
                Section {
                    // Hardcoded list: `claude` has no model-listing command, and
                    // an alias it doesn't know comes back only as "it may not
                    // exist". The aliases themselves are short and stable.
                    CLIAgentModelPicker(
                        title: "Claude Code model",
                        options: AgentModelCatalog.claudeModels,
                        selection: $claudeCodeModel
                    )

                    // Codex does publish its catalogue, so this one is fetched.
                    CLIAgentModelPicker(
                        title: "Codex model",
                        options: modelCatalog.codexModels,
                        selection: $codexModel,
                        isLoading: modelCatalog.isLoadingCodexModels,
                        errorMessage: modelCatalog.codexModelsError,
                        onRefresh: { Task { await modelCatalog.loadCodexModels(forceRefresh: true) } }
                    )

                    Picker("Codex reasoning effort", selection: $codexReasoningEffort) {
                        Text("Model default").tag("")
                        // A level saved against a model we can't see the details
                        // of keeps its own row, so the picker never shows blank.
                        if !codexReasoningEffort.isEmpty,
                           !codexEfforts.contains(codexReasoningEffort) {
                            Text(codexReasoningEffort.capitalized).tag(codexReasoningEffort)
                        }
                        ForEach(codexEfforts, id: \.self) { effort in
                            Text(effort.capitalized).tag(effort)
                        }
                    }
                    .onChange(of: codexModel) {
                        // Levels aren't uniform across models — GPT-5.6-Sol
                        // takes "ultra", GPT-5.5 doesn't — so a level the new
                        // model can't run has to go rather than sit there
                        // looking selected.
                        //
                        // Asked through the same rule the runner uses, which
                        // leaves a model it doesn't recognize alone. That matters
                        // on first appear: the saved model loads before Codex
                        // discovery finishes, and a stricter check here would
                        // clear a perfectly good setting just for opening the pane.
                        if !codexReasoningEffort.isEmpty,
                           modelCatalog.effort(for: codexModel, configured: codexReasoningEffort) == nil {
                            codexReasoningEffort = ""
                        }
                    }
                } header: {
                    Text("Command-line agents")
                } footer: {
                    Text("""
                        Passed to `claude --model` and `codex --model`. Leave a model \
                        on its default to use whatever the tool itself is set to. \
                        Each thread in the agent window can pick its own model from \
                        the engine menu. These agents authenticate through their own \
                        CLI, so no key is needed here.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            #endif

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
            if credentialMode == .subscription {
                Task { await loadSubscriptionModels(forceRefresh: false) }
            } else {
                Task { await loadChatModels(forceRefresh: false) }
                Task { await loadImageModels(forceRefresh: false) }
                Task { await loadVeoModels(forceRefresh: false) }
            }
            #if os(macOS)
                Task { await modelCatalog.loadCodexModels(forceRefresh: false) }
            #endif
        }
        .onChange(of: credentialMode) { _, mode in
            if mode == .subscription {
                Task { await loadSubscriptionModels(forceRefresh: false) }
            }
        }
        .alert("Saved", isPresented: $showSavedAlert) {
            Button("OK") {}
        } message: {
            Text("Your AI settings have been saved to the Keychain.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    #if os(macOS)
        /// Reasoning levels the selected Codex model accepts. Generic ones for a
        /// custom id — the user knows more about it than the catalogue does.
        private var codexEfforts: [String] {
            modelCatalog.efforts(forCodexModel: codexModel)
        }
    #endif

    private var canFetchChatModels: Bool {
        credentialMode == .subscription
            || (!openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
            )
    }

    private var hasAnyChange: Bool {
        credentialMode == .subscription
            || !googleKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !azureKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !azureEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !defaultImageModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !defaultVideoModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !claudeCodeModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !codexModel.trimmingCharacters(in: .whitespaces).isEmpty
            || !codexReasoningEffort.trimmingCharacters(in: .whitespaces).isEmpty
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
            defaultVideoModel = config.defaultVideoModel
            openAITranscriptionModel = config.openAITranscriptionModel
            geminiTranscriptionModel = config.geminiTranscriptionModel
            claudeCodeModel = config.claudeCodeModel
            codexModel = config.codexModel
            codexReasoningEffort = config.codexReasoningEffort
            credentialMode = config.credentialMode
            subscriptionChatModel = config.subscriptionChatModel
            subscriptionImageModel = config.subscriptionImageModel
            subscriptionTranscriptionModel = config.subscriptionTranscriptionModel
        }
    }

    /// Single place that assembles the config, so no save path can drop a field.
    private func currentConfig() -> AppConfig {
        AppConfig(
            googleAIKey: googleKey,
            azureSpeechKey: azureKey,
            azureSpeechEndpoint: azureEndpoint,
            openAIEndpoint: openAIEndpoint,
            openAIKey: openAIKey,
            openAIModel: openAIModel,
            defaultImageModel: defaultImageModel,
            defaultVideoModel: defaultVideoModel,
            openAITranscriptionModel: openAITranscriptionModel,
            geminiTranscriptionModel: geminiTranscriptionModel,
            claudeCodeModel: claudeCodeModel,
            codexModel: codexModel,
            codexReasoningEffort: codexReasoningEffort,
            credentialMode: credentialMode,
            subscriptionChatModel: subscriptionChatModel,
            subscriptionImageModel: subscriptionImageModel,
            subscriptionTranscriptionModel: subscriptionTranscriptionModel
        )
    }

    private func saveKeys() {
        do {
            let config = currentConfig()
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
    private func loadVeoModels(forceRefresh: Bool) async {
        let key = googleKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            // Silent on the automatic load — an empty key on first open is the
            // normal state, not an error worth shouting about.
            if forceRefresh { veoModelsError = "Enter the Google AI API key first." }
            return
        }
        isLoadingVeoModels = true
        veoModelsError = nil
        defer { isLoadingVeoModels = false }
        do {
            veoModels = try await GoogleModelsClient.shared.veoModels(
                apiKey: key,
                forceRefresh: forceRefresh
            )
        } catch {
            veoModelsError = error.localizedDescription
        }
    }

    @MainActor
    private func testAzure() async {
        isTestingAzure = true
        azureTestResult = nil
        defer { isTestingAzure = false }

        do {
            try currentConfig().saveToKeychain()
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

    @ViewBuilder
    private func subscriptionPicker(
        _ title: String,
        capability: AICapability,
        selection: Binding<String>
    ) -> some View {
        let models = subscriptionModels.filter { $0.capability == capability.rawValue }
        Picker(title, selection: selection) {
            Text("Select a model").tag("")
            // The catalog tracks the live gateway list, so a saved model can
            // vanish from it. Keep its row rather than showing a blank picker.
            if !selection.wrappedValue.isEmpty,
               !models.contains(where: { $0.id == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(models) { model in
                Text(model.pickerLabel).tag(model.id)
            }
        }
    }

    @MainActor
    private func loadSubscriptionModels(forceRefresh: Bool) async {
        guard AuthManager.shared.isAuthenticated else {
            subscriptionModelsError = "Sign in to load the subscription model catalog."
            return
        }
        isLoadingSubscriptionModels = true
        subscriptionModelsError = nil
        defer { isLoadingSubscriptionModels = false }
        do {
            async let chat = BackendModelCatalog.shared.models(capability: .chat, forceRefresh: forceRefresh)
            async let image = BackendModelCatalog.shared.models(capability: .image, forceRefresh: forceRefresh)
            async let transcription = BackendModelCatalog.shared.models(capability: .transcription, forceRefresh: forceRefresh)
            let result = try await (chat, image, transcription)
            subscriptionModels = result.0 + result.1 + result.2
        } catch {
            subscriptionModelsError = error.localizedDescription
        }
    }
}
