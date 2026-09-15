import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Source and provider configuration for one caption project.
struct CaptionProjectParametersView: View {
    @Bindable var project: CaptionProject
    let isTranscribing: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.projectStorage) private var storage
    #if os(macOS)
        // Raises the Settings window; on iOS, switching tabs is enough.
        @Environment(\.openSettings) private var openSettings
    #endif
    /// The film's own recordings, offered in the audio menu alongside a file
    /// from disk. Music takes and imported audio only — a narration brings its
    /// script as well, so it keeps the picker that shows what it says.
    @Query private var musicTakes: [GeneratedMusic]
    @Query private var importedAssets: [ImportedAsset]
    @State private var settings = CaptionSettings.shared
    @State private var modelStore = WhisperModelStore.shared
    @State private var showAudioImporter = false
    @State private var showNarrativePicker = false
    @State private var importError: String?
    @State private var renamingSpeaker: CaptionSpeaker?
    @State private var speakerDraft: String = ""
    @State private var openAIModels: [PickableModel] = []
    @State private var isLoadingOpenAIModels = false
    @State private var openAIModelsError: String?
    /// Cached so the body doesn't hit the Keychain on every redraw — this Form
    /// re-renders on each keystroke in the language hint.
    @State private var config: AppConfig?

    private var resolvedProvider: CaptionProvider {
        project.providerOverride ?? settings.defaultProvider
    }

    var body: some View {
        Form {
            sourceSection
            providerSection
            if !project.speakers.isEmpty { speakerSection }
            CaptionTermsSection(project: project)
            if project.isNarrativeSourced { narrativeSection }
            if hasStatus { statusSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Caption Setup")
        .task {
            // Needed so the model picker knows what's on disk.
            await modelStore.fetchIfNeeded()
        }
        // Keyed on the provider so switching to OpenAI-compatible fetches the
        // model list right then, rather than only on first appearance.
        .task(id: resolvedProvider) {
            guard resolvedProvider == .openAI else { return }
            await loadOpenAITranscriptionModels(forceRefresh: false)
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleAudioImport(result)
        }
        .sheet(isPresented: $showNarrativePicker) {
            CaptionNarrativeSourcePickerSheet(project: project)
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert(
            "Rename Speaker",
            isPresented: Binding(
                get: { renamingSpeaker != nil },
                set: { if !$0 { renamingSpeaker = nil } }
            )
        ) {
            TextField("Name", text: $speakerDraft)
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
            Button("Rename") { commitSpeakerRename() }
        }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        Section {
            TextField("Project name", text: $project.name)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #endif

            if project.hasAudio {
                LabeledContent("Source") {
                    HStack(spacing: 6) {
                        Image(systemName: sourceSymbol)
                        Text(sourceLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                LabeledContent("Duration") {
                    Text(project.audioDurationMs > 0
                        ? CaptionExporter.shortTimestamp(project.audioDurationMs)
                        : "Unknown")
                }
            } else {
                Text("Choose audio from this film, a file on disk, or a narration you've already generated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            audioSourceMenu
                .disabled(isTranscribing)
        } header: {
            Text("Audio source")
        } footer: {
            if project.isNarrativeSourced {
                Text("""
                    Captions from a narration use the speech service for timings only — the text \
                    stays exactly as you wrote it, and speakers come from your narrative.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// One menu rather than a row of buttons: the film's own music and imported
    /// audio are the common case, and they can't be listed as buttons without
    /// the section growing with the library.
    private var audioSourceMenu: some View {
        Menu {
            if !audioEntries.isEmpty {
                Section("In This Film") {
                    ForEach(audioEntries) { entry in
                        Button {
                            chooseProjectAudio(entry)
                        } label: {
                            Label(entry.title, systemImage: entry.systemImage)
                        }
                    }
                }
            }
            Section {
                Button {
                    showAudioImporter = true
                } label: {
                    Label("Import Audio…", systemImage: "square.and.arrow.down")
                }
                Button {
                    showNarrativePicker = true
                } label: {
                    Label("Use Narration…", systemImage: "text.book.closed")
                }
            }
        } label: {
            Label(project.hasAudio ? "Change Audio…" : "Use Audio…", systemImage: "waveform")
        }
        .accessibilityIdentifier("caption-audio-source-menu")
    }

    private var audioEntries: [CaptionAudioSource.Entry] {
        CaptionAudioSource.entries(music: musicTakes, imported: importedAssets)
    }

    /// The recording this project plays, when it is one of the film's own.
    /// Matched by id rather than by file: a referenced import lives outside the
    /// package, and the project holds a copy.
    private var projectAudioEntry: CaptionAudioSource.Entry? {
        guard let sourceID = project.lyricsSourceID else { return nil }
        return audioEntries.first { $0.id == sourceID }
    }

    private var sourceSymbol: String {
        if project.isNarrativeSourced { return "text.book.closed" }
        return projectAudioEntry?.systemImage ?? "waveform"
    }

    /// A file name is what the user chose for an import, but audio from the
    /// film is stored under a UUID, so that is named the way the library does.
    private var sourceLabel: String {
        if project.isNarrativeSourced { return project.sourceNarrativeName }
        return projectAudioEntry?.title ?? project.audioURL.lastPathComponent
    }

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: providerBinding) {
                Text("Default (\(settings.defaultProvider.displayName))").tag("")
                ForEach(CaptionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            if resolvedProvider == .whisperLocal {
                whisperModelPicker
            } else if resolvedProvider == .openAI {
                openAITranscriptionModelPicker
            }

            TextField("Language hint (optional)", text: $project.languageHint)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #else
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

            // Controls for capabilities the provider lacks are hidden rather
            // than shown disabled — a dead switch invites you to keep poking it.
            // The footer says what's unavailable and what to do instead.
            if resolvedProvider.supportsDiarization {
                Toggle("Detect speakers", isOn: $project.diarizationEnabled)

                if project.diarizationEnabled {
                    Stepper(
                        "Up to \(project.maxSpeakers) speakers",
                        value: $project.maxSpeakers,
                        in: 2...35
                    )
                }
            }

            if supportsWordTimings {
                Toggle("Word-level timings", isOn: $project.wordTimestampsEnabled)
            }
        } header: {
            Text("Transcription")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !resolvedProvider.supportsDiarization {
                    // One literal, not two joined with `+`: `Text("a" + "b")`
                    // resolves to the *verbatim* String initializer, which never
                    // gets localized. A `\`-continued multi-line literal stays a
                    // literal, so it's still extracted and translated.
                    Text("""
                        \(resolvedProvider.displayName) doesn't detect speakers. You can select \
                        captions in the editor and assign speakers in bulk.
                        """)
                }
                if !resolvedProvider.supportsWordTimings {
                    Text("""
                        \(resolvedProvider.displayName) doesn't return word timings, so word-level \
                        export will be approximated.
                        """)
                } else if !supportsWordTimings {
                    Text("""
                        \(wordTimingsBlockedBy) doesn't return word timings, so word-level export \
                        will be approximated.
                        """)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Per-project Whisper model, offering only what's actually downloaded.
    @ViewBuilder
    private var whisperModelPicker: some View {
        let installed = modelStore.installedModels

        if installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "No Whisper model downloaded yet.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)

                // Telling someone where to go is worse than taking them there.
                Button(action: openWhisperSettings) {
                    Label("Download a Model…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        } else {
            Picker("Whisper model", selection: $project.whisperVariantOverride) {
                Text(defaultWhisperLabel).tag("")
                ForEach(installed) { entry in
                    Text(entry.displayName).tag(entry.variant)
                }
            }
        }
    }

    private var defaultWhisperLabel: String {
        let global = CaptionSettings.shared.whisperVariant
        guard !global.isEmpty,
              let entry = modelStore.models.first(where: { $0.variant == global })
        else { return "Default" }
        return "Default (\(entry.displayName))"
    }

    /// Per-project transcription model, listing what the subscription offers
    /// for the provider this project transcribes with.
    @ViewBuilder
    private var openAITranscriptionModelPicker: some View {
        HStack {
            Picker("Transcription model", selection: $project.openAITranscriptionModelOverride) {
                Text(defaultOpenAITranscriptionLabel).tag("")
                // Keep a hand-typed or since-removed id selectable, so
                // opening this screen can't silently retarget the project.
                if !project.openAITranscriptionModelOverride.isEmpty,
                   !openAIModels.contains(where: { $0.id == project.openAITranscriptionModelOverride }) {
                    Text(project.openAITranscriptionModelOverride)
                        .tag(project.openAITranscriptionModelOverride)
                }
                ForEach(openAIModels) { model in
                    Text(model.pickerLabel).tag(model.id)
                }
            }

            Button {
                Task { await loadOpenAITranscriptionModels(forceRefresh: true) }
            } label: {
                if isLoadingOpenAIModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isLoadingOpenAIModels)
            .help("Refresh model list")
        }

        if let openAIModelsError {
            Text(openAIModelsError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// `LocalizedStringKey`, not `String`: `Text(someString)` picks the verbatim
    /// initializer and would never be translated.
    private var defaultOpenAITranscriptionLabel: LocalizedStringKey {
        let global = config?.subscriptionTranscriptionModel ?? ""
        return global.isEmpty
            ? "Default (\(OpenAITranscriptionClient.defaultModel))"
            : "Default (\(global))"
    }

    /// What `CaptionTranscriptionService.options(for:)` would resolve to today.
    private var resolvedTranscriptionModel: String {
        let override = project.openAITranscriptionModelOverride
        if !override.isEmpty { return override }
        let global = config?.subscriptionTranscriptionModel ?? ""
        return global.isEmpty ? OpenAITranscriptionClient.defaultModel : global
    }

    /// Word timings depend on the model, not just the provider: OpenAI's
    /// `gpt-4o*-transcribe` models don't implement `verbose_json`. Where they
    /// can't be produced the toggle is hidden rather than offered and quietly
    /// ignored.
    private var supportsWordTimings: Bool {
        guard resolvedProvider.supportsWordTimings else { return false }
        guard resolvedProvider == .openAI else { return true }
        return OpenAITranscriptionClient.modelSupportsWordTimings(resolvedTranscriptionModel)
    }

    /// Names what is responsible, for the footer.
    private var wordTimingsBlockedBy: String { resolvedTranscriptionModel }

    private var speakerSection: some View {
        Section {
            ForEach(project.speakers) { speaker in
                HStack {
                    Circle()
                        .fill(CaptionSpeakerPalette.color(at: speaker.colorIndex))
                        .frame(width: 10, height: 10)
                    Text(speaker.label)
                    Spacer()
                    Button("Rename") {
                        speakerDraft = speaker.label
                        renamingSpeaker = speaker
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Button {
                var speakers = project.speakers
                speakers.append(CaptionSpeaker(
                    label: "Speaker \(speakers.count + 1)",
                    colorIndex: speakers.count
                ))
                project.speakers = speakers
                project.updatedAt = Date()
            } label: {
                Label("Add Speaker", systemImage: "plus")
            }
            .font(.caption)
        } header: {
            Text("Speakers")
        }
    }

    private var narrativeSection: some View {
        Section {
            LabeledContent("Alignment", value: project.activeAlignmentQuality.displayName)
            if project.activeAlignmentMatchRatio > 0 {
                LabeledContent("Script match") {
                    Text("\(Int(project.activeAlignmentMatchRatio * 100))%")
                }
            }
            LabeledContent("Script paragraphs", value: "\(project.referenceUnits.count)")
        } header: {
            Text("Narrative alignment")
        } footer: {
            Text("""
                Script match is how much of your text the speech service recognised. Higher means \
                more accurate timings.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Transcribing itself lives in the toolbar, matching the other tabs; this is
    /// only the record of the last run.
    private var statusSection: some View {
        Section {
            if let date = project.lastTranscribedAt {
                LabeledContent("Last run") {
                    Text(date, style: .relative)
                }
            }
            if !project.lastProviderName.isEmpty {
                LabeledContent("Used", value: project.lastProviderName)
            }
        } header: {
            Text("Last transcription")
        } footer: {
            if project.activeSegmentCount > 0 {
                Text("Re-transcribing creates a new version. The current one is kept, along with its translations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasStatus: Bool {
        project.lastTranscribedAt != nil || !project.lastProviderName.isEmpty
    }

    // MARK: - Navigation

    private func openWhisperSettings() {
        AppNavigation.shared.showCaptionSettings(focus: .whisperModels)
        #if os(macOS)
            openSettings()
        #endif
    }

    // MARK: - Model loading

    /// Never blocks the screen: a failure leaves the current selection alone and
    /// surfaces the reason under the picker.
    @MainActor
    private func loadOpenAITranscriptionModels(forceRefresh: Bool) async {
        // Re-read rather than trusting the cache: the user may have just come
        // back from Settings with a different default.
        config = try? AppConfig.loadFromKeychain()

        guard AuthManager.shared.isAuthenticated else {
            // `String(localized:)` because this lands in a `String?` that
            // `Text` would otherwise render verbatim, untranslated.
            openAIModelsError = String(
                localized: "Sign in to your RxLab account to load transcription models."
            )
            return
        }

        isLoadingOpenAIModels = true
        openAIModelsError = nil
        defer { isLoadingOpenAIModels = false }
        do {
            let all = try await BackendModelCatalog.shared.models(
                capability: .transcription,
                forceRefresh: forceRefresh
            )
            openAIModels = all.filter { $0.provider == "openai" }
        } catch {
            openAIModelsError = error.localizedDescription
        }
    }

    // MARK: - Bindings

    /// "" means "follow the app default", which the picker shows as its own row.
    private var providerBinding: Binding<String> {
        Binding(
            get: { project.provider },
            set: { project.provider = $0 }
        )
    }

    // MARK: - Actions

    /// Points this project at one of the film's recordings. The file is
    /// referenced in place where it already lives in the package, so choosing a
    /// long music take costs nothing.
    private func chooseProjectAudio(_ entry: CaptionAudioSource.Entry) {
        Task {
            do {
                try await CaptionAudioSource.attach(entry.id, to: project, context: modelContext)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // Sandboxed pickers hand back a security-scoped URL that must be
            // opened before it can be read.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                // Drop audio the project previously owned so imports don't pile up.
                if project.ownsAudioFile, !project.audioFilePath.isEmpty {
                    storage.deleteFile(at: project.audioFilePath)
                }
                let relative = try storage.importAudio(from: url)
                project.audioFilePath = relative
                project.ownsAudioFile = true
                project.sourceKindEnum = .importedFile
                project.sourceNarrativeID = nil
                project.sourceNarrativeName = ""
                // A file from disk is not one of the film's recordings, so the
                // link the lyrics editor and the caption menus follow is dropped.
                project.lyricsSourceID = nil
                project.referenceUnits = []
                project.alignmentQualityEnum = .none
                project.audioDurationMs = 0
                if project.name == "Untitled Captions" {
                    project.name = url.deletingPathExtension().lastPathComponent
                }
                project.updatedAt = Date()

                Task {
                    if let ms = try? await AudioProbe.durationMs(
                        of: storage.absoluteURL(for: relative)
                    ) {
                        project.audioDurationMs = ms
                    }
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func commitSpeakerRename() {
        defer { renamingSpeaker = nil }
        guard let target = renamingSpeaker else { return }
        let trimmed = speakerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var speakers = project.speakers
        guard let index = speakers.firstIndex(where: { $0.id == target.id }) else { return }
        speakers[index].label = trimmed
        project.speakers = speakers
        project.updatedAt = Date()
    }
}
