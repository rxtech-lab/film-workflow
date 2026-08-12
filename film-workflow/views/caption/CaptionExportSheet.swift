import SwiftUI
import UniformTypeIdentifiers

/// Format picker plus a live preview for caption export.
struct CaptionExportSheet: View {
    @Bindable var project: CaptionProject

    @Environment(\.dismiss) private var dismiss

    @State private var options = CaptionExportOptions()
    @State private var preview: String = ""
    @State private var sizeLabel: String?
    @State private var isRendering = false
    @State private var exportFile: CaptionExportFile?
    @State private var showExporter = false
    @State private var errorMessage: String?
    @State private var bundleFiles: [CaptionExportBundleFile] = []
    @State private var showBundleExporter = false

    private var snapshot: CaptionTranscriptSnapshot { project.snapshot() }

    /// Original plus every translated language, which is what "each language"
    /// means for the multi-file export.
    private var exportLanguages: [String] { [""] + project.translatedLanguages }

    private var hasWordTimings: Bool {
        project.activeSegments.contains { !$0.words.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        #if os(macOS)
            // A fixed size rather than a minimum: sections come and go as the
            // format changes, and letting the sheet resize itself to fit made
            // the whole form jump on every edit.
            .frame(width: 560, height: 620)
        #else
            .frame(minWidth: 520, minHeight: 560)
        #endif
        .task(id: options) {
            // Coalesce rapid edits — holding a stepper fires a change per step —
            // into a single render.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await renderPreview()
        }
        .fileExporter(
            isPresented: $showExporter,
            item: exportFile,
            contentTypes: [options.format.utType],
            defaultFilename: CaptionExporter.defaultFilename(
                projectName: project.name,
                options: options,
                languageCode: CaptionExporter.filenameLanguageCode(options: options)
            )
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            } else {
                dismiss()
            }
        }
        .fileExporter(
            isPresented: $showBundleExporter,
            items: bundleFiles,
            contentTypes: [options.format.utType]
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            } else {
                dismiss()
            }
        }
        .onAppear {
            // Start on whatever the editor is showing, so Export follows the
            // language the user was just reading.
            if options.translationLanguage.isEmpty {
                options.translationLanguage = project.displayedTranslationLanguage
                if !options.translationLanguage.isEmpty {
                    options.translationMode = .bilingual
                }
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Export Captions")
                .font(.headline)
            Spacer()
            Text("\(project.activeSegmentCount) captions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            if !project.translatedLanguages.isEmpty {
                languageSection
            }

            Section {
                Picker("Format", selection: $options.format) {
                    ForEach(CaptionExportFormat.allCases) { format in
                        Text("\(format.displayName) (.\(format.fileExtension))").tag(format)
                    }
                }

                if options.format != .json {
                    Picker("Granularity", selection: $options.granularity) {
                        ForEach(CaptionExportGranularity.allCases) { granularity in
                            Text(granularity.displayName).tag(granularity)
                        }
                    }

                    Picker("Speaker names", selection: $options.speakerStyle) {
                        ForEach(CaptionExportOptions.SpeakerStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }
            } header: {
                Text("Format")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if options.granularity == .wordKaraoke, !options.format.supportsWordKaraoke {
                        Text("""
                            \(options.format.displayName) can't express inline word timings, so \
                            sentence cues will be exported instead.
                            """)
                    }
                    if options.effectiveGranularity != .sentence, !hasWordTimings {
                        Text("""
                            This transcript has no word timings, so word times will be estimated by \
                            splitting each caption's duration.
                            """)
                    }
                    if options.speakerStyle == .vttVoiceTag, !options.format.supportsSpeakerVoiceTags {
                        Text("Voice tags are WebVTT-only; names will be used as a prefix instead.")
                    }
                    if options.effectiveTranslationMode != .originalOnly {
                        Text("""
                            Translations have no word timings, so whole sentence cues are exported \
                            and long captions aren't re-wrapped.
                            """)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if options.format == .text {
                Section("Plain text") {
                    Toggle("Include timestamps", isOn: $options.includeTimestampsInText)
                }
            }

            if options.format != .json {
                Section("Text") {
                    Toggle("Remove punctuation", isOn: $options.stripPunctuation)
                    if options.effectiveGranularity == .sentence {
                        Stepper(
                            options.maxRunesPerCue == 0
                                ? "Don't re-wrap long captions"
                                : "Re-wrap over \(options.maxRunesPerCue) characters",
                            value: $options.maxRunesPerCue,
                            in: 0...120,
                            step: 4
                        )
                    }
                }
            }

            Section {
                // The last render stays on screen while the next one runs.
                // Swapping it for a spinner collapsed this section from 160pt to
                // one row and back, which resized the sheet on every edit.
                ScrollView {
                    Text(preview.isEmpty ? "Nothing to preview." : preview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)

                // Kept in the layout at zero opacity for the same reason: a row
                // that appears and disappears moves everything below it.
                Text("\(sizeLabel ?? "—") total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(sizeLabel == nil ? 0 : 1)
            } header: {
                HStack(spacing: 6) {
                    Text("Preview")
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isRendering ? 1 : 0)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $options.translationLanguage) {
                Text("Original").tag("")
                ForEach(project.translatedLanguages, id: \.self) { code in
                    Text(CaptionTranslationAvailability.displayName(code)).tag(code)
                }
            }
            .onChange(of: options.translationLanguage) { _, code in
                // Picking a language with the mode still on original-only would
                // change nothing about the output, which reads as a broken
                // picker. Bilingual is the sane default; the layout picker
                // appears in the same breath so it's easy to change.
                if !code.isEmpty, options.translationMode == .originalOnly {
                    options.translationMode = .bilingual
                }
            }

            if !options.translationLanguage.isEmpty {
                Picker("Layout", selection: $options.translationMode) {
                    ForEach(
                        [CaptionExportOptions.TranslationMode.bilingual, .translationOnly],
                        id: \.self
                    ) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("""
                Choosing a language sets what one file contains. \
                "Export Each Language…" writes them all at once, one file per language.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy") { Task { await copyToClipboard() } }
                .buttonStyle(.bordered)

            #if os(macOS)
            Button("Save All Formats…") { Task { await exportAllFormats() } }
                .buttonStyle(.bordered)
            #endif

            if !project.translatedLanguages.isEmpty {
                Button("Export Each Language…") { Task { await exportEachLanguage() } }
                    .buttonStyle(.bordered)
            }

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
            Button("Export…") { Task { await beginExport() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(project.activeSegmentCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// Renders off the main actor and shows only the head of the document —
    /// a full hour-long transcript would be megabytes of text in a `Text` view.
    private func renderPreview() async {
        guard project.activeSegmentCount > 0 else {
            preview = ""
            sizeLabel = nil
            return
        }

        // The spinner only shows up if the render is slow enough to be worth
        // reporting; flipping it on unconditionally flashed it for a frame or
        // two on every edit, which reads as a glitch.
        let spinner = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { isRendering = true }
        }
        defer {
            spinner.cancel()
            isRendering = false
        }

        let currentSnapshot = snapshot
        let currentOptions = options
        do {
            let data = try await CaptionExporter.render(currentSnapshot, options: currentOptions)
            sizeLabel = ByteCountFormatter.string(
                fromByteCount: Int64(data.count), countStyle: .file
            )
            let text = String(decoding: data, as: UTF8.self)
            preview = String(text.prefix(2000))
        } catch {
            preview = error.localizedDescription
            sizeLabel = nil
        }
    }

    private func beginExport() async {
        do {
            let data = try await CaptionExporter.render(snapshot, options: options)
            exportFile = CaptionExportFile(data: data, utType: options.format.utType)
            showExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyToClipboard() async {
        do {
            let data = try await CaptionExporter.render(snapshot, options: options)
            Pasteboard.copy(String(decoding: data, as: UTF8.self))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One file per language: the original plus each translation, named
    /// `{project}_{language}.{ext}` so they can't collide in a folder.
    ///
    /// The original is named with the transcript's own language for the same
    /// reason — a folder holding `Talk.srt` and `Talk_zh-Hans.srt` doesn't say
    /// what the first one is.
    private func exportEachLanguage() async {
        let currentSnapshot = snapshot
        var rendered: [(name: String, data: Data)] = []

        for code in exportLanguages {
            var languageOptions = options
            languageOptions.translationLanguage = code
            languageOptions.translationMode = code.isEmpty ? .originalOnly : options.translationMode
            if languageOptions.translationMode == .originalOnly, !code.isEmpty {
                languageOptions.translationMode = .bilingual
            }

            let filenameCode = code.isEmpty ? currentSnapshot.sourceLanguage : code
            do {
                let data = try await CaptionExporter.render(currentSnapshot, options: languageOptions)
                rendered.append((
                    CaptionExporter.defaultFilename(
                        projectName: project.name,
                        options: languageOptions,
                        languageCode: filenameCode
                    ),
                    data
                ))
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        guard !rendered.isEmpty else { return }

        #if os(macOS)
            guard let directory = chooseExportDirectory() else { return }
            do {
                for file in rendered {
                    try file.data.write(to: directory.appendingPathComponent(file.name))
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            dismiss()
        #else
            // No folder panel on iOS. The multi-item exporter takes each file's
            // name from its URL, so the files are staged in a temporary
            // directory under their final names — the only way to get
            // `{project}_{language}.{ext}` there.
            do {
                let staging = FileManager.default.temporaryDirectory
                    .appending(path: "CaptionExport-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true
                )
                bundleFiles = try rendered.map { file in
                    let url = staging.appending(path: file.name)
                    try file.data.write(to: url)
                    return CaptionExportBundleFile(url: url)
                }
                showBundleExporter = true
            } catch {
                errorMessage = error.localizedDescription
            }
        #endif
    }

    #if os(macOS)
    private func chooseExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Writes VTT, SRT and TXT into a chosen folder in one go — the common case
    /// when handing captions to an editor who wants all three. Honours the
    /// selected language, so "all formats" means all formats of what's on screen.
    private func exportAllFormats() async {
        guard let directory = chooseExportDirectory() else { return }

        let currentSnapshot = snapshot
        let languageCode = CaptionExporter.filenameLanguageCode(options: options)

        for format in [CaptionExportFormat.vtt, .srt, .text] {
            var formatOptions = options
            formatOptions.format = format
            do {
                let data = try await CaptionExporter.render(currentSnapshot, options: formatOptions)
                let name = CaptionExporter.defaultFilename(
                    projectName: project.name,
                    options: formatOptions,
                    languageCode: languageCode
                )
                try data.write(to: directory.appendingPathComponent(name))
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        dismiss()
    }
    #endif
}

/// URL-backed, unlike the single-file `CaptionExportFile`: the multi-item
/// exporter derives each file's name from its URL, and a `Data` representation
/// has no name to give it.
private struct CaptionExportBundleFile: Transferable, Identifiable {
    let url: URL

    var id: URL { url }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            SentTransferredFile(file.url)
        }
    }
}

/// Cue files are kilobytes, so eager `Data` is fine here — unlike the audio
/// exporters, which is why this mirrors `NarrativeAudioFile` rather than
/// streaming.
private struct CaptionExportFile: Transferable {
    let data: Data
    let utType: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in
            file.data
        }
    }
}
