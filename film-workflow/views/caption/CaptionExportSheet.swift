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

    private var snapshot: CaptionTranscriptSnapshot { project.snapshot() }

    private var hasWordTimings: Bool {
        project.segments.contains { !$0.words.isEmpty }
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
                projectName: project.name, options: options
            )
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            } else {
                dismiss()
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
            Text("\(project.segments.count) captions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
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

    private var footer: some View {
        HStack {
            Button("Copy") { Task { await copyToClipboard() } }
                .buttonStyle(.bordered)

            #if os(macOS)
            Button("Save All Formats…") { Task { await exportAllFormats() } }
                .buttonStyle(.bordered)
            #endif

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
            Button("Export…") { Task { await beginExport() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(project.segments.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// Renders off the main actor and shows only the head of the document —
    /// a full hour-long transcript would be megabytes of text in a `Text` view.
    private func renderPreview() async {
        guard !project.segments.isEmpty else {
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

    #if os(macOS)
    /// Writes VTT, SRT and TXT into a chosen folder in one go — the common case
    /// when handing captions to an editor who wants all three.
    private func exportAllFormats() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let base = CaptionExporter.sanitize(project.name)
        let currentSnapshot = snapshot

        for format in [CaptionExportFormat.vtt, .srt, .text] {
            var formatOptions = options
            formatOptions.format = format
            do {
                let data = try await CaptionExporter.render(currentSnapshot, options: formatOptions)
                let url = directory.appendingPathComponent("\(base).\(format.fileExtension)")
                try data.write(to: url)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        dismiss()
    }
    #endif
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
