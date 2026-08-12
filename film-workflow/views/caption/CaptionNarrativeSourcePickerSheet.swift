import SwiftData
import SwiftUI

/// Picks a previously generated narration as a caption project's audio source.
///
/// Choosing one switches the project into "timings only" mode: it captures the
/// narrative's paragraph text as the reference, so alignment can supply timings
/// while the caption body stays exactly what the author wrote.
struct CaptionNarrativeSourcePickerSheet: View {
    @Bindable var project: CaptionProject

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NarrativeProject.updatedAt, order: .reverse)
    private var narratives: [NarrativeProject]

    /// Lets you hear a narration before committing to it — the list is otherwise
    /// just timestamps, which is a poor way to tell two takes apart.
    @State private var preview = CaptionNarrationPreviewPlayer()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a Narration")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if narratives.allSatisfy({ $0.generatedFiles.isEmpty }) {
                ContentUnavailableView(
                    "No Narrations Yet",
                    systemImage: "text.book.closed",
                    description: Text("Generate audio in the Narrative tab first.")
                )
            } else {
                List {
                    ForEach(narratives) { narrative in
                        if !narrative.generatedFiles.isEmpty {
                            Section(narrative.name) {
                                ForEach(
                                    narrative.generatedFiles.sorted { $0.createdAt > $1.createdAt },
                                    id: \.persistentModelID
                                ) { file in
                                    row(narrative: narrative, file: file)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                if preview.isAnyPlaying {
                    Button {
                        preview.stop()
                    } label: {
                        Label("Stop Preview", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 480)
        // Never leave audio playing behind a dismissed sheet.
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private func row(narrative: NarrativeProject, file: GeneratedNarrative) -> some View {
        let exists = FileManager.default.fileExists(atPath: file.audioURL.path)
        let isLoaded = preview.isPlaying(url: file.audioURL)
        let isPlaying = isLoaded && !preview.isPaused

        // The scrubber is a sibling of the select button, never inside it: a
        // Button label swallows its children's gestures, so a nested Slider
        // would be undraggable and every drag would select the narration.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    preview.toggle(url: file.audioURL)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!exists)
                .help(isPlaying ? "Pause" : "Listen to this narration")

                Button {
                    select(narrative: narrative, file: file)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.createdAt, format: .dateTime)
                                .font(.callout)
                            HStack(spacing: 6) {
                                if !file.providerName.isEmpty {
                                    Text(file.providerName)
                                }
                                if !file.speakerSummary.isEmpty {
                                    Text(file.speakerSummary)
                                        .lineLimit(1)
                                }
                                Text(file.fileExtension.uppercased())
                                if !exists {
                                    Text("File missing")
                                        .foregroundStyle(.red)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if project.sourceNarrativeID == file.captionSourceID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!exists)
            }

            if isLoaded, preview.durationMs > 0 {
                HStack(spacing: 8) {
                    Button { preview.seek(toMs: preview.currentMs - 5000) } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .buttonStyle(.borderless)

                    Slider(
                        value: Binding(
                            get: { Double(preview.currentMs) },
                            set: { preview.seek(toMs: Int($0)) }
                        ),
                        in: 0...Double(preview.durationMs)
                    )

                    Button { preview.seek(toMs: preview.currentMs + 5000) } label: {
                        Image(systemName: "goforward.5")
                    }
                    .buttonStyle(.borderless)

                    Text(
                        CaptionExporter.shortTimestamp(preview.currentMs)
                        + " / "
                        + CaptionExporter.shortTimestamp(preview.durationMs)
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 34)
            }
        }
    }

    /// Points the project at the narration's existing file and captures the
    /// reference text.
    ///
    /// The audio is referenced in place, never copied: narration files can be
    /// hundreds of megabytes and already live under `generated/`.
    private func select(narrative: NarrativeProject, file: GeneratedNarrative) {
        preview.stop()

        if project.ownsAudioFile, !project.audioFilePath.isEmpty {
            FileStorage.deleteFile(at: project.audioFilePath)
        }

        project.audioFilePath = file.audioFilePath
        project.ownsAudioFile = false
        project.sourceKindEnum = .generatedNarrative
        project.sourceNarrativeID = file.captionSourceID
        project.sourceNarrativeName = narrative.name
        project.referenceUnits = CaptionReferenceBuilder.units(for: narrative, project: project)
        project.alignmentQualityEnum = .none
        project.alignmentMatchRatio = 0
        project.audioDurationMs = 0

        // Narrative speakers are known, so diarization is pointless here.
        project.diarizationEnabled = false
        project.speakers = CaptionReferenceBuilder.speakers(for: narrative)
        // Re-map the reference units onto the speaker ids we just created.
        project.referenceUnits = CaptionReferenceBuilder.units(for: narrative, project: project)

        if project.name == "Untitled Captions" {
            project.name = "\(narrative.name) captions"
        }
        project.updatedAt = Date()

        Task {
            if let ms = try? await AudioProbe.durationMs(of: file.audioURL) {
                project.audioDurationMs = ms
            }
        }
        dismiss()
    }
}

extension GeneratedNarrative {
    /// A stable id for the weak link from `CaptionProject.sourceNarrativeID`.
    ///
    /// `GeneratedNarrative` has no UUID of its own and adding one would be a
    /// schema change on an existing entity, so the audio path — already unique,
    /// since it's a UUID filename — identifies it.
    var captionSourceID: UUID? {
        let name = (audioFilePath as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        return UUID(uuidString: base)
    }
}

/// Builds the reference side of narrative caption alignment.
nonisolated struct CaptionReferenceBuilder {

    /// One `CaptionSpeaker` per narrative speaker, carrying the link back.
    @MainActor
    static func speakers(for narrative: NarrativeProject) -> [CaptionSpeaker] {
        narrative.speakers.enumerated().map { index, speaker in
            CaptionSpeaker(
                label: speaker.displayName,
                providerSpeakerNumber: 0,
                colorIndex: index,
                narrativeSpeakerId: speaker.id
            )
        }
    }

    /// One reference unit per paragraph, with shortcode markup stripped to the
    /// words that will actually be spoken.
    @MainActor
    static func units(
        for narrative: NarrativeProject,
        project: CaptionProject
    ) -> [CaptionReferenceUnit] {
        var out: [CaptionReferenceUnit] = []
        var order = 0

        for paragraph in narrative.paragraphs {
            let parsed = ShortcodeExpander.plainSpeechWithPauses(paragraph.content)
            let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A paragraph that is nothing but a pause contributes no words, so it
            // can't carry a caption.
            guard !text.isEmpty else { continue }

            let speakerId = project.speakers.first {
                $0.narrativeSpeakerId == paragraph.speakerId
            }?.id ?? project.speakers.first?.id ?? UUID()

            out.append(CaptionReferenceUnit(
                paragraphId: paragraph.id,
                speakerId: speakerId,
                order: order,
                plainText: text,
                fixedPauseMsBefore: parsed.pauses.reduce(0) { $0 + $1.ms }
            ))
            order += 1
        }
        return out
    }
}
