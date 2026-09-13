import SwiftUI
import TipKit

struct CaptionSettingsView: View {
    @State private var settings = CaptionSettings.shared
    @State private var modelStore = WhisperModelStore.shared
    @State private var navigation = AppNavigation.shared
    @State private var availability = AgentBackendAvailability.shared

    /// Snapshot of the Keychain config, so the engine picker can say whether an
    /// OpenAI-compatible endpoint is actually set up. Refreshed by `loadKeys`.
    @State private var aiConfig: AppConfig?

    /// One id shared by every hosted provider, the same field the transcription
    /// client reads. The picker below only offers models the selected provider
    /// can actually run.
    @State private var subscriptionTranscriptionModel: String = ""

    @State private var transcriptionModels: [PickableModel] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingDelete: WhisperModelStore.ModelEntry?
    @State private var isUnloading = false

    /// Scroll target for deep links that want the model list.
    private enum Anchor: Hashable {
        case whisper
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                providerSection
                languageSection
                // All three provider sections are always shown. Gating them
                // behind the current provider selection hid the Whisper model
                // list on a fresh install — and downloading a model is a
                // *prerequisite* to choosing that provider, so it must never be
                // hidden behind it.
                whisperSection
                    .id(Anchor.whisper)
                transcriptionModelSection
                narrativeSection
                cueSection
                aiSection
                translationSection
            }
            .formStyle(.grouped)
            // Runs on first appearance too, which is the case that matters: the
            // request is made before this view exists, so onChange never fires.
            .task(id: navigation.pendingSettingsFocus) {
                guard navigation.pendingSettingsFocus == .whisperModels else { return }
                // The form has to lay out before a row can be scrolled to.
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation { proxy.scrollTo(Anchor.whisper, anchor: .top) }
                navigation.pendingSettingsFocus = nil
            }
            // No Save button: the model picker commits as soon as it changes.
            // Everything else here writes through `CaptionSettings` on
            // assignment, so it is already saved.
            .task(id: subscriptionTranscriptionModel) {
                save()
            }
        }
        .onAppear {
            loadKeys()
            // Apple Intelligence can be enabled, and a CLI installed, while the
            // app is open — re-check rather than trusting a launch-time answer.
            availability.refresh()
            Task { await modelStore.fetchIfNeeded() }
            Task { await loadTranscriptionModels(forceRefresh: false) }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .alert(
            "Delete this model?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { modelStore.delete(entry.variant) }
                pendingDelete = nil
            }
        } message: {
            // Built inside the Text, not as a String first: a String argument
            // takes Text's verbatim initializer and never gets localized.
            if let entry = pendingDelete {
                Text("""
                    \(entry.displayName) will be removed from this device. You can download it \
                    again later.
                    """)
            }
        }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section {
            Picker("Default provider", selection: $settings.defaultProvider) {
                ForEach(CaptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Picker("Narrative captions", selection: $settings.narrativeProvider) {
                ForEach(CaptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Picker("Timing fallback", selection: fallbackBinding) {
                Text("None").tag("")
                ForEach(CaptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            capabilityRow(for: settings.defaultProvider)
        } header: {
            Text("Providers")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // Long copy uses `\`-continued multi-line literals, never
                // `"a" + "b"`: joining literals resolves to Text's verbatim
                // String initializer, which is never localized.
                Text("""
                    Narrative captions take only the timings from the speech service — the caption \
                    text always stays exactly as you wrote it.
                    """)
                if !settings.narrativeProvider.supportsWordTimings {
                    Label("""
                        \(settings.narrativeProvider.displayName) doesn't return word timings, so \
                        narrative timings will be estimated. Azure or on-device Whisper give much \
                        better results.
                        """, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                }
                Text("""
                    The timing fallback re-runs a transcription on another provider when the first \
                    returns timings that go backwards.
                    """)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func capabilityRow(for provider: CaptionProvider) -> some View {
        HStack(spacing: 12) {
            capabilityBadge(
                "Speakers", enabled: provider.supportsDiarization
            )
            capabilityBadge(
                "Word timings", enabled: provider.supportsWordTimings
            )
            capabilityBadge(
                "Offline", enabled: !provider.requiresNetwork
            )
        }
        .font(.caption)
    }

    /// `LocalizedStringKey`, not `String`: a `String` argument takes `Label`'s
    /// verbatim initializer, which is why these badges stayed English while the
    /// rest of the pane translated.
    private func capabilityBadge(_ title: LocalizedStringKey, enabled: Bool) -> some View {
        Label(title, systemImage: enabled ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(enabled ? .green : .secondary)
    }

    private var languageSection: some View {
        Section {
            TextField("Language hint (e.g. en-US, zh-CN)", text: $settings.defaultLanguageHint)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #else
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

            Stepper(
                "Maximum speakers: \(settings.defaultMaxSpeakers)",
                value: $settings.defaultMaxSpeakers,
                in: 2...35
            )
        } header: {
            Text("Defaults for new projects")
        } footer: {
            Text("Leave the language blank to auto-detect. Speaker detection needs Azure or Gemini.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Model for the hosted transcription providers.
    ///
    /// Whisper runs on this device and picks its model in its own section, so
    /// this one is empty when Whisper is selected.
    @ViewBuilder
    private var transcriptionModelSection: some View {
        if settings.defaultProvider != .whisperLocal {
            Section {
                HStack {
                    Picker("Transcription model", selection: $subscriptionTranscriptionModel) {
                        Text("Provider default").tag("")
                        if !subscriptionTranscriptionModel.isEmpty,
                           !providerModels.contains(where: { $0.id == subscriptionTranscriptionModel }) {
                            Text(subscriptionTranscriptionModel).tag(subscriptionTranscriptionModel)
                        }
                        ForEach(providerModels) { model in
                            Text(model.pickerLabel).tag(model.id)
                        }
                    }

                    Button {
                        Task { await loadTranscriptionModels(forceRefresh: true) }
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingModels)
                    .help("Refresh model list")
                }

                if let modelsError {
                    Text(modelsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Transcription model")
            } footer: {
                Text("""
                    Runs on the RxFilm server and is billed to your credits. Gemini detects \
                    speakers but returns no word timings, and its timestamps sometimes need \
                    the timing fallback.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var whisperSection: some View {
        Section {
            // State up front: which model is in use, or a nudge to download one.
            if let selected = modelStore.models.first(where: {
                $0.variant == settings.whisperVariant && $0.isInstalled
            }) {
                LabeledContent("Selected model") {
                    Text(selected.displayName)
                        .foregroundStyle(.primary)
                }
            } else if modelStore.installedModels.isEmpty {
                Label(
                    "No model downloaded yet. Download one below to transcribe on this device.",
                    systemImage: "arrow.down.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "No model selected. Tap the circle next to a downloaded model to use it.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if modelStore.isLoading, modelStore.models.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading model list…")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(modelStore.models) { entry in
                whisperModelRow(entry)
            }

            if let error = modelStore.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    Task { await modelStore.refresh() }
                } label: {
                    Label("Refresh list", systemImage: "arrow.clockwise")
                }
                .disabled(modelStore.isLoading)

                Spacer()

                if modelStore.totalInstalledBytes > 0 {
                    Text(byteText(modelStore.totalInstalledBytes) + " on disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Keep the model in memory between runs", isOn: $settings.keepWhisperModelLoaded)

            Button {
                isUnloading = true
                Task {
                    await WhisperKitEngine.shared.unload()
                    isUnloading = false
                }
            } label: {
                if isUnloading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Unload model from memory")
                }
            }
            .disabled(isUnloading)
        } header: {
            Text("On-device Whisper models")
        } footer: {
            Text("""
                Models download from Hugging Face and run entirely on this device. Larger models are \
                more accurate and slower. On-device Whisper doesn't detect speakers, so you assign \
                them in the editor.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .popoverTip(FilmWorkflowTips.WhisperModelTip(), arrowEdge: .top)
    }

    @ViewBuilder
    private func whisperModelRow(_ entry: WhisperModelStore.ModelEntry) -> some View {
        let progress = modelStore.downloadProgress[entry.variant]

        HStack(spacing: 12) {
            // Selecting a model is only meaningful once it's on disk.
            Button {
                settings.whisperVariant = entry.variant
            } label: {
                Image(systemName: settings.whisperVariant == entry.variant
                    ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(!entry.isInstalled)
            .help(entry.isInstalled ? "Use this model" : "Download this model first")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                    if entry.isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    if !entry.isMultilingual {
                        Text("English only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("Downloading — \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.isInstalled
                        ? byteText(entry.installedBytes)
                        : "about " + byteText(entry.approximateBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if progress != nil {
                EmptyView()
            } else if entry.isInstalled {
                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this model")
            } else {
                Button {
                    Task { await modelStore.download(entry.variant) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Download this model")
            }
        }
    }

    private var narrativeSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Alignment confidence: \(Int(settings.narrativeAlignmentMinConfidence * 100))%")
                Slider(value: $settings.narrativeAlignmentMinConfidence, in: 0.3...0.95, step: 0.05)
            }
        } header: {
            Text("Narrative alignment")
        } footer: {
            Text("""
                How much of your script must match what the speech service heard before per-word \
                timings are trusted. Below this, timings fall back to whole sentences.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var cueSection: some View {
        Section {
            Picker("Splitting", selection: $settings.splitMode) {
                ForEach(CaptionSplitMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Stepper(
                "Split captions longer than \(settings.maxCueRunes) characters",
                value: $settings.maxCueRunes,
                in: 20...200,
                step: 10
            )
        } header: {
            Text("Caption length")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                switch settings.splitMode {
                case .characterLimit:
                    Text("""
                        Applies only to runs of text with no sentence punctuation. Commas never \
                        split a caption.
                        """)
                case .ai:
                    Text("""
                        The model decides where a long caption should break — at a clause boundary, \
                        never mid-phrase, and never leaving a stub second line. It leaves a caption \
                        alone when no split improves it. The length above is the threshold it works \
                        to.
                        """)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var translationSection: some View {
        Section {
            Picker("Engine", selection: $settings.translationEngine) {
                ForEach(CaptionTranslationEngineKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            if settings.translationEngine == .aiBackend {
                Toggle("Follow the project glossary", isOn: $settings.translationRespectsGlossary)
            }
        } header: {
            Text("Translation")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.translationEngine.detail)
                if settings.translationEngine == .appleTranslation {
                    Text("""
                        Translations requested by an outside agent over MCP always use the AI \
                        backend — Apple's engine only runs inside the app.
                        """)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        Section {
            Picker("Engine", selection: $settings.aiBackend) {
                ForEach(AgentBackend.supported) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }

            // The reason is shown rather than the option being hidden: "Apple
            // Intelligence isn't turned on" is actionable, a missing row is not.
            if let reason = availability.unavailableReason(settings.aiBackend, config: aiConfig) {
                Label {
                    Text(reason)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)

                if settings.aiBackend == .openAICompatible {
                    Button("Open AI Provider settings") {
                        AppNavigation.shared.settingsSection = .aiProvider
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 12) {
                capabilityBadge("Offline", enabled: !settings.aiBackend.requiresNetwork)
                capabilityBadge(
                    "While transcribing",
                    enabled: settings.aiBackend.supports(.cueRefinement)
                )
            }
            .font(.caption)

            Toggle("Review AI changes before applying", isOn: $settings.aiConfirmChanges)

            Toggle("Use terms as a spelling hint when transcribing", isOn: $settings.termsBiasTranscription)
        } header: {
            Text("Caption AI")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                    Used for splitting, for checking captions against a project's terms, and by the \
                    caption assistant. Apple Intelligence runs entirely on this device.
                    """)
                if !settings.aiBackend.supports(.cueRefinement) {
                    Text("""
                        Claude Code and Codex read a saved transcript through the app's own MCP \
                        server, so they can split and check terms from the caption editor. They \
                        can't do it during transcription, when the captions don't exist yet — that \
                        pass falls back to Apple Intelligence or an OpenAI-compatible model.
                        """)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    /// Catalog entries the selected provider can serve. The catalog names the
    /// provider the server will call, which is the only reliable way to tell a
    /// Gemini id from a Whisper one.
    private var providerModels: [PickableModel] {
        let provider: String
        switch settings.defaultProvider {
        case .gemini: provider = "google"
        case .azure: provider = "azure"
        case .openAI: provider = "openai"
        case .whisperLocal: return []
        }
        return transcriptionModels.filter { $0.provider == provider }
    }

    /// The picker needs a non-optional selection, and "" means "no fallback".
    private var fallbackBinding: Binding<String> {
        Binding(
            get: { settings.timingFallbackProvider?.rawValue ?? "" },
            set: { settings.timingFallbackProvider = CaptionProvider(rawValue: $0) }
        )
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Actions

    private func loadKeys() {
        guard let config = try? AppConfig.loadFromKeychain() else { return }
        aiConfig = config
        subscriptionTranscriptionModel = config.subscriptionTranscriptionModel
    }

    /// Writes only the transcription model, re-reading everything else from the
    /// Keychain so this form can't clobber the AI Provider tab's fields.
    ///
    /// A no-op until `loadKeys` has run, so the autosave that fires with the
    /// pane's first layout can't write an empty model over a saved one.
    private func save() {
        guard let loaded = aiConfig else { return }
        let model = subscriptionTranscriptionModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != loaded.subscriptionTranscriptionModel else { return }
        do {
            let onDisk = try AppConfig.loadFromKeychain()
            var config = onDisk
            config.subscriptionTranscriptionModel = model
            try config.saveChanges(since: onDisk)
            aiConfig = config
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func loadTranscriptionModels(forceRefresh: Bool) async {
        guard AuthManager.shared.isAuthenticated else {
            modelsError = "Sign in to your RxLab account to load transcription models."
            return
        }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            transcriptionModels = try await BackendModelCatalog.shared.models(
                capability: .transcription,
                forceRefresh: forceRefresh
            )
        } catch {
            modelsError = error.localizedDescription
        }
    }
}
