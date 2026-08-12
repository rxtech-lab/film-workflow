import SwiftData
import SwiftUI

/// Edits one caption's text, speaker and time range.
///
/// The UI works in start/end because that's how people think about captions;
/// storage is offset/duration. That conversion happens only here and in
/// `CaptionSegment.retime`, never scattered through the views.
struct CaptionSegmentEditorSheet: View {
    @Bindable var project: CaptionProject
    let segment: CaptionSegment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var draftText: String = ""
    @State private var draftSpeaker: UUID?
    @State private var draftStartMs: Int = 0
    @State private var draftEndMs: Int = 0
    @State private var player: CaptionEditorAudioPlayer?
    @State private var editingBoundary: CaptionTimestampBoundary?
    @State private var retimeNotice: String?
    @State private var draftTranslationLanguage: String = ""
    @State private var draftTranslation: String = ""

    /// Languages this caption's version has, not just this caption's — so a row
    /// that was skipped by a translation pass can still be filled in by hand.
    private var translatedLanguages: [String] {
        var codes = project.translatedLanguages
        for code in segment.translatedLanguages where !codes.contains(code) {
            codes.append(code)
        }
        return codes
    }

    private var audioDurationMs: Int {
        project.audioDurationMs > 0 ? project.audioDurationMs : (player?.durationMs ?? 0)
    }

    private var isValid: Bool {
        draftStartMs >= 0
            && draftEndMs > draftStartMs
            && (audioDurationMs <= 0 || draftEndMs <= audioDurationMs)
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var textChanged: Bool {
        draftText != segment.text
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
        .sheet(item: $editingBoundary) { boundary in
            CaptionTimestampPickerSheet(
                title: boundary == .start ? "Start Time" : "End Time",
                totalMs: boundary == .start ? $draftStartMs : $draftEndMs,
                maxMs: audioDurationMs,
                currentAudioMs: player?.currentMs
            ) {
                editingBoundary = nil
            }
        }
    }

    // MARK: - Sections

    private var translationSection: some View {
        Section {
            if translatedLanguages.count > 1 {
                Picker("Language", selection: $draftTranslationLanguage) {
                    ForEach(translatedLanguages, id: \.self) { code in
                        Text(CaptionTranslationAvailability.displayName(code)).tag(code)
                    }
                }
                .onChange(of: draftTranslationLanguage) { previous, _ in
                    // Commit the edit in progress before swapping languages,
                    // otherwise switching the picker silently discards it.
                    commitTranslation(for: previous)
                    loadTranslation()
                }
            }

            TextEditor(text: $draftTranslation)
                .frame(minHeight: 70)
                .font(.body)

            if segment.isTranslationStale(draftTranslationLanguage) {
                Label(
                    "The caption changed after this was translated. Saving both marks it current again.",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Translation")
        }
    }

    private var header: some View {
        HStack {
            Text("Edit Caption")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            Section("Text") {
                TextEditor(text: $draftText)
                    .frame(minHeight: 90)
                    .font(.body)

                if textChanged, !segment.words.isEmpty {
                    Label(
                        "Word timings will be re-matched to the new text.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if !translatedLanguages.isEmpty {
                translationSection
            }

            Section("Speaker") {
                Picker("Speaker", selection: $draftSpeaker) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(project.speakers) { speaker in
                        Text(speaker.label).tag(UUID?.some(speaker.id))
                    }
                }
            }

            Section("Timing") {
                timingRow(.start, value: draftStartMs)
                timingRow(.end, value: draftEndMs)

                LabeledContent("Duration") {
                    Text("\(max(draftEndMs - draftStartMs, 0)) ms")
                        .monospacedDigit()
                        .foregroundStyle(draftEndMs > draftStartMs ? Color.primary : Color.red)
                }

                if let player {
                    audioControls(player)
                }
            }

            if !segment.words.isEmpty {
                Section("Words") {
                    LabeledContent("Word timings", value: "\(segment.words.count)")
                    if segment.words.contains(where: { $0.isPinned }) {
                        Label(
                            "Pinned words keep their exact times when the caption is retimed.",
                            systemImage: "pin.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func timingRow(_ boundary: CaptionTimestampBoundary, value: Int) -> some View {
        HStack {
            Text(boundary.title)
            Spacer()
            Button {
                editingBoundary = boundary
            } label: {
                Text(CaptionExporter.vttTimestamp(value))
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)

            Button {
                guard let player else { return }
                if boundary == .start {
                    draftStartMs = player.currentMs
                } else {
                    draftEndMs = player.currentMs
                }
            } label: {
                Image(systemName: "playhead.and.waveform")
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .help("Use the current audio time")
        }
    }

    @ViewBuilder
    private func audioControls(_ player: CaptionEditorAudioPlayer) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    player.clearPlaybackLimit()
                    player.playRange(startMs: draftStartMs, endMs: draftEndMs)
                } label: {
                    Image(systemName: "play.rectangle")
                }
                .buttonStyle(.borderless)
                .disabled(draftEndMs <= draftStartMs)
                .help("Play just this caption")

                Button { player.step(byMs: -250) } label: { Image(systemName: "gobackward") }
                    .buttonStyle(.borderless)
                Button { player.step(byMs: 250) } label: { Image(systemName: "goforward") }
                    .buttonStyle(.borderless)

                Spacer()

                Text(CaptionExporter.vttTimestamp(player.currentMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if audioDurationMs > 0 {
                Slider(
                    value: Binding(
                        get: { Double(player.currentMs) },
                        set: { player.seek(toMs: Int($0)) }
                    ),
                    in: 0...Double(audioDurationMs)
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            if let retimeNotice {
                Text(retimeNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func load() {
        draftText = segment.text
        draftSpeaker = segment.speakerId
        draftStartMs = segment.startMs
        draftEndMs = segment.endMs
        if FileManager.default.fileExists(atPath: project.audioURL.path) {
            player = CaptionEditorAudioPlayer(url: project.audioURL)
        }

        // Open on whatever the list is showing, so the row the user
        // double-tapped and the sheet they get are about the same language.
        let shown = project.displayedTranslationLanguage
        draftTranslationLanguage = translatedLanguages.contains(shown)
            ? shown
            : (translatedLanguages.first ?? "")
        loadTranslation()
    }

    private func loadTranslation() {
        draftTranslation = segment.translatedText(draftTranslationLanguage)
    }

    /// Writes the draft back if it changed. `setTranslation` re-stamps the
    /// fingerprint from the segment's *current* text, so editing the caption and
    /// its translation in one pass correctly clears the stale badge.
    private func commitTranslation(for language: String) {
        guard !language.isEmpty else { return }
        let trimmed = draftTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != segment.translatedText(language) else { return }
        segment.setTranslation(
            trimmed,
            language: language,
            engine: segment.translation(language)?.engine ?? "",
            isUserEdited: true
        )
    }

    private func save() {
        guard isValid else { return }
        let previousWords = segment.words
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Retime first so word rescaling happens against the final span, then
        // re-tokenize if the text changed. Doing it the other way round would
        // rescale words that are about to be replaced.
        if draftStartMs != segment.startMs || draftEndMs != segment.endMs {
            let changed = segment.retime(toStartMs: draftStartMs, endMs: draftEndMs)
            if changed > 0 {
                retimeNotice = "\(changed) word timing\(changed == 1 ? "" : "s") rescaled."
            }
        }

        if trimmed != segment.text {
            segment.text = trimmed
            if !previousWords.isEmpty {
                segment.retokenizeWords(preservingTimingsFrom: previousWords)
            }
        }

        segment.speakerId = draftSpeaker
        segment.isUserEdited = true
        // After the text is final, so the fingerprint matches what was saved.
        commitTranslation(for: draftTranslationLanguage)
        project.refreshTranslationSummary()
        project.updatedAt = Date()
        dismiss()
    }
}
