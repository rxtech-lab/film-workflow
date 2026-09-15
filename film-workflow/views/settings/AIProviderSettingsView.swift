import RxSubscriptionIOS
import SwiftUI
import TipKit

struct AIProviderSettingsView: View {
    @State private var openAIEndpoint: String = ""
    @State private var openAIKey: String = ""
    @State private var openAIModel: String = ""
    @State private var claudeCodeModel: String = ""
    @State private var codexModel: String = ""
    @State private var codexReasoningEffort: String = ""
    @State private var subscriptionChatModel: String = ""
    @State private var subscriptionImageModel: String = ""
    @State private var subscriptionTranscriptionModel: String = ""
    @State private var subscriptionVideoModel: String = ""

    /// What is currently on disk, so the autosave can write just the fields
    /// this pane changed and skip writing at all when nothing differs.
    @State private var loadedConfig = AppConfig()

    @State private var subscriptionModels: [PickableModel] = []
    @State private var isLoadingSubscriptionModels = false
    @State private var subscriptionModelsError: String?

    @State private var chatModels: [OpenAIModelInfo] = []
    @State private var isLoadingChatModels = false
    @State private var chatModelsError: String?

    @State private var errorMessage: String?
    @State private var showError = false

    @State private var modelCatalog = AgentModelCatalog.shared
    @State private var navigation = AppNavigation.shared

    /// Scroll target for the deep link an "unavailable model" alert follows.
    private enum Anchor: Hashable {
        case subscriptionModels
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                // Runs on first appearance too, which is the case that matters:
                // the request is made before this view exists, so `onChange`
                // never fires.
                .task(id: navigation.pendingSettingsFocus) {
                    guard navigation.pendingSettingsFocus == .subscriptionModels else { return }
                    // The catalog is what decides whether a saved id is stale,
                    // so a deep link arriving here forces it fresh rather than
                    // flagging a model against an hour-old list.
                    await loadSubscriptionModels(forceRefresh: true)
                    withAnimation { proxy.scrollTo(Anchor.subscriptionModels, anchor: .top) }
                    navigation.pendingSettingsFocus = nil
                }
        }
    }

    private var subscriptionSummary: String {
        let credits = String(localized: "\(CreditBalanceStore.shared.availablePoints) credits")
        guard let plan = SubscriptionStore.shared.activePlan else { return credits }
        return "\(plan.planName) · \(credits)"
    }

    private var form: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: AuthManager.shared.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(AuthManager.shared.isAuthenticated ? .green : .orange)
                    Text(AuthManager.shared.isAuthenticated
                        ? "Using your RxLab account balance"
                        : "Sign in on the Account tab before generating")
                    Spacer()
                    if AuthManager.shared.isAuthenticated {
                        // This pane decides which models are reachable, and
                        // that depends on the plan, so name it next to the
                        // balance rather than in a section of its own.
                        Text(subscriptionSummary)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .popoverTip(FilmWorkflowTips.SubscriptionCreditsTip(), arrowEdge: .top)
            } header: {
                Text("RxFilm subscription")
            }

            Section {
                // Said once at the top as well as beside each picker: a pane
                // reached from a failed generation has to answer "what do I fix"
                // before the user scrolls, and a stale id is easy to scroll past.
                if !unavailableCapabilities.isEmpty {
                    Label {
                        Text("No longer offered on your plan: \(unavailableSummary). Pick a replacement in each highlighted row below.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                subscriptionPicker("Chat model", capability: .chat, selection: $subscriptionChatModel)
                subscriptionPicker("Image model", capability: .image, selection: $subscriptionImageModel)
                subscriptionPicker("Transcription model", capability: .transcription, selection: $subscriptionTranscriptionModel)
                subscriptionPicker("Video model", capability: .video, selection: $subscriptionVideoModel)

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
                Text("Default models")
            } footer: {
                Text("Provider credentials stay on the RxFilm server. Model prices are estimates; actual usage is deducted after each operation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id(Anchor.subscriptionModels)

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
                    Picker("Chat model", selection: $openAIModel) {
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
                    .disabled(isLoadingChatModels || !canFetchChatModels)
                    .help("Refresh model list")
                }

                if let chatModelsError {
                    Text(chatModelsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Your key is stored securely in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenAI-compatible endpoint (optional)")
            } footer: {
                Text("""
                    Adds a second chat engine to the agent window and the caption AI \
                    tasks, billed by that provider rather than your credits. Works with \
                    OpenAI, Azure OpenAI, OpenRouter, Ollama, LM Studio, etc. Image, \
                    speech, music, transcription and video always run on your \
                    subscription. Leave it empty to use the subscription alone.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        // No Save button: every edit is written on a short delay. Keyed on the
        // assembled config so a fresh keystroke cancels the pending write
        // instead of queueing a Keychain round-trip per character.
        .task(id: currentConfig()) {
            let config = currentConfig()
            guard config != loadedConfig else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveKeys(config)
        }
        .onAppear {
            loadKeys()
            Task { await loadSubscriptionModels(forceRefresh: false) }
            Task { await loadChatModels(forceRefresh: false) }
            #if os(macOS)
                Task { await modelCatalog.loadCodexModels(forceRefresh: false) }
            #endif
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
        !openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadKeys() {
        guard let config = try? AppConfig.loadFromKeychain() else { return }
        loadedConfig = config
        openAIEndpoint = config.openAIEndpoint
        openAIKey = config.openAIKey
        openAIModel = config.openAIModel
        claudeCodeModel = config.claudeCodeModel
        codexModel = config.codexModel
        codexReasoningEffort = config.codexReasoningEffort
        subscriptionChatModel = config.subscriptionChatModel
        subscriptionImageModel = config.subscriptionImageModel
        subscriptionTranscriptionModel = config.subscriptionTranscriptionModel
        subscriptionVideoModel = config.subscriptionVideoModel
    }

    /// Single place that assembles the config, so no save path can drop a field.
    private func currentConfig() -> AppConfig {
        var config = AppConfig()
        config.openAIEndpoint = openAIEndpoint
        config.openAIKey = openAIKey
        config.openAIModel = openAIModel
        config.claudeCodeModel = claudeCodeModel
        config.codexModel = codexModel
        config.codexReasoningEffort = codexReasoningEffort
        config.subscriptionChatModel = subscriptionChatModel
        config.subscriptionImageModel = subscriptionImageModel
        config.subscriptionTranscriptionModel = subscriptionTranscriptionModel
        config.subscriptionVideoModel = subscriptionVideoModel
        return config
    }

    private func saveKeys(_ config: AppConfig) {
        do {
            try config.saveChanges(since: loadedConfig)
            // Re-read instead of trusting `config`: the Captions pane writes
            // the transcription model too, so for every field this pane did not
            // just change, the Keychain is the truth.
            loadKeys()
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
            chatModels = try await OpenAIModelsClient.shared.chatModels(
                endpoint: openAIEndpoint,
                apiKey: openAIKey,
                forceRefresh: forceRefresh
            )
        } catch {
            chatModelsError = error.localizedDescription
        }
    }

    /// Whether `subscriptionModels` holds a catalog the server actually
    /// answered with, which is the only list a saved id can be judged against.
    private var isCatalogLoaded: Bool {
        !isLoadingSubscriptionModels && subscriptionModelsError == nil && !subscriptionModels.isEmpty
    }

    /// Every capability whose saved model the catalog no longer offers.
    ///
    /// Read for the section header as well as the rows: an id going stale is
    /// the one thing in this pane the user did not do and has to undo, so it is
    /// said once at the top and again beside the picker that holds it.
    private var unavailableCapabilities: [AICapability] {
        subscriptionSelections.compactMap { capability, selection in
            SubscriptionModelPicker.isUnavailable(
                selection.wrappedValue,
                in: models(for: capability),
                isCatalogLoaded: isCatalogLoaded
            ) ? capability : nil
        }
    }

    /// The stale rows, named the way the pickers below name them.
    private var unavailableSummary: String {
        unavailableCapabilities.map(\.settingsRowLabel).formatted(.list(type: .and))
    }

    /// The four pickers this pane owns, in the order they are shown.
    private var subscriptionSelections: [(AICapability, Binding<String>)] {
        [
            (.chat, $subscriptionChatModel),
            (.image, $subscriptionImageModel),
            (.transcription, $subscriptionTranscriptionModel),
            (.video, $subscriptionVideoModel),
        ]
    }

    private func models(for capability: AICapability) -> [PickableModel] {
        subscriptionModels.filter { $0.capability == capability.rawValue }
    }

    @ViewBuilder
    private func subscriptionPicker(
        _ title: LocalizedStringKey,
        capability: AICapability,
        selection: Binding<String>
    ) -> some View {
        let models = models(for: capability)
        // The catalog tracks the live gateway list, so a saved model can vanish
        // from it. The picker keeps its row rather than showing a blank, and
        // flags it rather than letting it pass for a working choice.
        SubscriptionModelPicker(
            title: title,
            emptyLabel: "Select a model",
            models: models,
            isCatalogLoaded: isCatalogLoaded,
            selection: selection
        )
        if SubscriptionModelPicker.isUnavailable(
            selection.wrappedValue,
            in: models,
            isCatalogLoaded: isCatalogLoaded
        ) {
            UnavailableModelWarning(model: selection.wrappedValue, capability: capability)
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
            async let video = BackendModelCatalog.shared.models(capability: .video, forceRefresh: forceRefresh)
            let result = try await (chat, image, transcription, video)
            subscriptionModels = result.0 + result.1 + result.2 + result.3
        } catch {
            subscriptionModelsError = error.localizedDescription
        }
    }
}
