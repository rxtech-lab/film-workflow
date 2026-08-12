import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Source and provider configuration for one caption project.
struct CaptionProjectParametersView: View {
    @Bindable var project: CaptionProject
    let isTranscribing: Bool

    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
        // Raises the Settings window; on iOS, switching tabs is enough.
        @Environment(\.openSettings) private var openSettings
    #endif
    @State private var settings = CaptionSettings.shared
    @State private var modelStore = WhisperModelStore.shared
    @State private var showAudioImporter = false
    @State private var showNarrativePicker = false
    @State private var importError: String?
    @State private var renamingSpeaker: CaptionSpeaker?
    @State private var speakerDraft: String = ""
    @State private var deletingVersion: CaptionTranscriptVersion?

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
            if !project.versions.isEmpty { versionSection }
            if hasStatus { statusSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Caption Setup")
        .task {
            // Needed so the model picker knows what's on disk.
            await modelStore.fetchIfNeeded()
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
                        Image(systemName: project.isNarrativeSourced ? "text.book.closed" : "waveform")
                        Text(project.isNarrativeSourced
                            ? project.sourceNarrativeName
                            : project.audioURL.lastPathComponent)
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
                Text("Choose an audio file or a narration you've already generated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
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

            if resolvedProvider.supportsWordTimings {
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
            LabeledContent("Alignment", value: project.alignmentQualityEnum.displayName)
            if project.alignmentMatchRatio > 0 {
                LabeledContent("Script match") {
                    Text("\(Int(project.alignmentMatchRatio * 100))%")
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

    /// Every transcription run, newest first, with the active one marked.
    ///
    /// The only place a version can be switched or deleted — deliberately out of
    /// the editor's way, since re-reading an old take is rare and deleting one
    /// is irreversible.
    private var versionSection: some View {
        Section {
            ForEach(project.orderedVersions) { version in
                versionRow(version)
            }
        } header: {
            Text("Versions")
        } footer: {
            Text("""
                Each transcription run is kept as its own version, with its own \
                translations. Switch versions to compare takes; deleting one \
                removes its captions for good.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Delete this version?",
            isPresented: Binding(
                get: { deletingVersion != nil },
                set: { if !$0 { deletingVersion = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingVersion
        ) { version in
            Button("Delete", role: .destructive) {
                CaptionTranscriptionService.deleteVersion(
                    version.id,
                    from: project,
                    context: modelContext
                )
                deletingVersion = nil
            }
            Button("Cancel", role: .cancel) { deletingVersion = nil }
        } message: { version in
            Text("Version \(version.number) and its \(version.segmentCount) captions will be removed. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func versionRow(_ version: CaptionTranscriptVersion) -> some View {
        let isActive = version.id == project.activeVersionID
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Version \(version.number)")
                        .fontWeight(isActive ? .semibold : .regular)
                    if !version.languageDisplayName.isEmpty {
                        Text(version.languageDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(versionDetail(version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !version.translatedLanguages.isEmpty {
                    Text(translationDetail(version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("Make Active") {
                    CaptionTranscriptionService.activateVersion(version.id, in: project)
                }
                .disabled(isActive)
                Divider()
                Button("Delete…", role: .destructive) { deletingVersion = version }
                    .disabled(project.versions.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    private func versionDetail(_ version: CaptionTranscriptVersion) -> String {
        var parts: [String] = ["\(version.segmentCount) captions"]
        if let provider = version.providerEnum {
            parts.append(provider.displayName)
        } else if !version.provider.isEmpty {
            parts.append(version.provider)
        }
        parts.append(version.createdAt.formatted(date: .abbreviated, time: .shortened))
        if !version.note.isEmpty { parts.append(version.note) }
        return parts.joined(separator: " · ")
    }

    private func translationDetail(_ version: CaptionTranscriptVersion) -> String {
        version.translations
            .filter { $0.translatedCount > 0 }
            .map { "\($0.languageDisplayName) \($0.translatedCount)/\($0.totalCount)" }
            .joined(separator: " · ")
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

    // MARK: - Bindings

    /// "" means "follow the app default", which the picker shows as its own row.
    private var providerBinding: Binding<String> {
        Binding(
            get: { project.provider },
            set: { project.provider = $0 }
        )
    }

    // MARK: - Actions

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
                    FileStorage.deleteFile(at: project.audioFilePath)
                }
                let relative = try FileStorage.importAudio(from: url)
                project.audioFilePath = relative
                project.ownsAudioFile = true
                project.sourceKindEnum = .importedFile
                project.sourceNarrativeID = nil
                project.sourceNarrativeName = ""
                project.referenceUnits = []
                project.alignmentQualityEnum = .none
                project.audioDurationMs = 0
                if project.name == "Untitled Captions" {
                    project.name = url.deletingPathExtension().lastPathComponent
                }
                project.updatedAt = Date()

                Task {
                    if let ms = try? await AudioProbe.durationMs(
                        of: FileStorage.absoluteURL(for: relative)
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
