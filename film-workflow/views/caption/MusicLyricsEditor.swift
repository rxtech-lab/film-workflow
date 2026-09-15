import SwiftData
import SwiftUI
import VideoEditorCore

struct MusicLyricsRequest: Identifiable, Equatable {
    enum Action: Equatable { case edit, retime, merge(UUID), chooseCaptions, chooseMusic, remove }
    let id = UUID()
    let sourceID: String
    var action: Action = .edit
}

/// Shared by library rows, individual takes, and the footage viewer.
struct MusicLyricsContextMenu: View {
    let sourceID: String?
    let onRequest: (MusicLyricsRequest) -> Void
    @Query private var captions: [CaptionProject]
    @Query private var music: [GeneratedMusic]
    @Query private var imported: [ImportedAsset]

    private var targets: [MusicLyrics.Target] { MusicLyrics.targets(music: music, imported: imported) }

    var body: some View {
        if let sourceID, targets.contains(where: { $0.id == sourceID }) {
            let lyrics = captions.first { $0.lyricsSourceID == sourceID }
            Button(lyrics == nil ? "Add Lyrics Timing…" : "Edit Lyrics & Timing…") {
                onRequest(.init(sourceID: sourceID))
            }
            .accessibilityIdentifier("music-lyrics-edit")
            if let lyrics, !lyrics.activeSegments.isEmpty {
                Button("Retime Lyrics…") { onRequest(.init(sourceID: sourceID, action: .retime)) }
                    .accessibilityIdentifier("music-lyrics-retime")
            }
            Menu("Merge Captions as Lyrics") {
                ForEach(captions.filter { $0.lyricsSourceID != sourceID && !$0.activeSegments.isEmpty }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.projectUUID) { caption in
                    Button(caption.name) { onRequest(.init(sourceID: sourceID, action: .merge(caption.projectUUID))) }
                }
            }
            .disabled(!captions.contains { $0.lyricsSourceID != sourceID && !$0.activeSegments.isEmpty })
            if lyrics != nil {
                Button("Remove Lyrics…", role: .destructive) { onRequest(.init(sourceID: sourceID, action: .remove)) }
            }
            Divider()
        } else if let sourceID, let (prefix, id) = DocumentMediaResolver.parse(sourceID), prefix == .caption,
                  let caption = captions.first(where: { $0.projectUUID == id }) {
            if let musicID = caption.lyricsSourceID {
                Button("Edit Lyrics & Timing…") { onRequest(.init(sourceID: musicID)) }
                Button("Retime Lyrics…") { onRequest(.init(sourceID: musicID, action: .retime)) }
                    .disabled(caption.activeSegments.isEmpty)
            }
            Menu("Merge as Lyrics into Music") {
                ForEach(targets.filter { $0.id != caption.lyricsSourceID }) { target in
                    Button(target.title) { onRequest(.init(sourceID: target.id, action: .merge(caption.projectUUID))) }
                }
            }
            .disabled(caption.activeSegments.isEmpty || targets.isEmpty)
            Divider()
        }
    }
}

private struct MusicLyricsHost: ViewModifier {
    @Binding var request: MusicLyricsRequest?
    @Environment(\.modelContext) private var context
    @State private var presentation: Presentation?
    @State private var mergePresentation: MergePresentation?
    @State private var removingLyrics: CaptionProject?
    @State private var error: String?
    @State private var preparing = false

    struct Presentation: Identifiable {
        let id = UUID()
        let project: CaptionProject
        let action: MusicLyricsRequest.Action
        let suggestedText: String
    }

    struct MergePresentation: Identifiable {
        let id = UUID()
        let captions: CaptionProject?
        let sourceID: String?
    }

    func body(content: Content) -> some View {
        content
            .task(id: request) { await open() }
            .overlay { if preparing { ProgressView("Opening lyrics…").padding().background(.regularMaterial) } }
            .sheet(item: $presentation, onDismiss: {
                do { try context.save() } catch { self.error = error.localizedDescription }
            }) { value in
                if value.action == .retime, !value.project.activeSegments.isEmpty {
                    CaptionRetimeSheet(project: value.project)
                } else {
                    MusicLyricsEditor(project: value.project, suggestedText: value.suggestedText)
                }
            }
            .sheet(item: $mergePresentation) { value in
                MusicLyricsMergePicker(captions: value.captions, sourceID: value.sourceID)
            }
            .modifier(MusicLyricsRemovalConfirmation(project: $removingLyrics))
            .alert("Couldn’t Open Lyrics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func open() async {
        guard let request else { return }
        preparing = true
        defer { preparing = false; self.request = nil }
        do {
            if request.action == .remove {
                removingLyrics = try MusicLyrics.project(for: request.sourceID, context: context)
                return
            }
            if request.action == .chooseCaptions {
                mergePresentation = .init(captions: nil, sourceID: request.sourceID)
                return
            }
            if request.action == .chooseMusic {
                guard let (prefix, id) = DocumentMediaResolver.parse(request.sourceID), prefix == .caption,
                      let captions = try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first
                else { throw MusicLyrics.LyricsError.emptyCaptions }
                mergePresentation = .init(captions: captions, sourceID: nil)
                return
            }
            if case .merge(let id) = request.action {
                guard let value = try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first,
                      !value.activeSegments.isEmpty else { throw MusicLyrics.LyricsError.emptyCaptions }
                mergePresentation = .init(captions: value, sourceID: request.sourceID)
                return
            }
            let project = try await MusicLyrics.prepare(for: request.sourceID, context: context)
            try Task.checkCancellation()
            presentation = .init(project: project, action: request.action,
                                 suggestedText: MusicLyrics.suggestedText(for: request.sourceID, context: context))
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}

extension View {
    func musicLyricsHost(_ request: Binding<MusicLyricsRequest?>) -> some View {
        modifier(MusicLyricsHost(request: request))
    }
}

/// The existing caption view supplies text edits, translations, versions and
/// retiming. Only the initial untimed text entry is specific to music.
struct MusicLyricsEditor: View {
    @Bindable var project: CaptionProject
    var suggestedText = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var language = ""
    @State private var error: String?
    @State private var showRetimer = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(project.name, systemImage: "music.note.list").font(.headline)
                Spacer()
                MusicLyricsRemoveButton(project: project, onRemoved: { dismiss() })
                Button("Done") {
                    do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
                }
                .accessibilityIdentifier("music-lyrics-done")
            }.padding()
            Divider()
            if project.activeSegments.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add lyrics, one line per caption. Then listen to the music and set each line’s timing.")
                        .foregroundStyle(.secondary)
                    TextField("Language code (optional, e.g. en)", text: $language)
                        .accessibilityIdentifier("music-lyrics-language")
                    TextEditor(text: $text).border(.quaternary)
                        .accessibilityIdentifier("music-lyrics-text")
                    Button("Create Timing…") {
                        do {
                            try MusicLyrics.addLines(text, language: language, to: project, context: context)
                            showRetimer = true
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("music-lyrics-create-timing")
                }.padding()
            } else {
                CaptionSegmentListView(project: project)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("music-lyrics-editor")
        .onAppear { text = suggestedText; language = project.sourceLanguageCode }
        .sheet(isPresented: $showRetimer) { CaptionRetimeSheet(project: project) }
        .alert("Couldn’t Save Lyrics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

/// Both merge directions share selection, confirmation, and preparation.
private struct MusicLyricsMergePicker: View {
    let captions: CaptionProject?
    let sourceID: String?
    @Query private var music: [GeneratedMusic]
    @Query private var imported: [ImportedAsset]
    @Query private var captionProjects: [CaptionProject]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTargetID: String?
    @State private var selectedCaptionID: UUID?
    @State private var pendingMerge: MergeSelection?
    @State private var lyrics: CaptionProject?
    @State private var error: String?
    @State private var preparing = false

    private struct MergeSelection {
        let captions: CaptionProject
        let target: MusicLyrics.Target
    }

    private var targets: [MusicLyrics.Target] {
        MusicLyrics.targets(music: music, imported: imported).filter { $0.id != captions?.lyricsSourceID }
    }

    private var selectedTarget: MusicLyrics.Target? {
        let wanted = selectedTargetID ?? sourceID
        if captions == nil { return targets.first { $0.id == sourceID } }
        return targets.first { $0.id == wanted } ?? targets.first
    }

    private var availableCaptions: [CaptionProject] {
        captionProjects.filter { $0.activeSegmentCount > 0 && $0.lyricsSourceID != selectedTarget?.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selectedCaptions: CaptionProject? {
        captions ?? availableCaptions.first { $0.projectUUID == selectedCaptionID } ?? availableCaptions.first
    }

    var body: some View {
        Group {
            if let lyrics {
                MusicLyricsEditor(project: lyrics)
            } else if preparing {
                ProgressView("Opening lyrics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: 600, height: 260)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(captions == nil ? "Merge Captions as Lyrics" : "Merge as Lyrics into Music").font(.headline)
                    if let captions {
                        Text("Choose the music take for these captions.").foregroundStyle(.secondary)
                        LabeledContent("Captions", value: captions.name)
                        Picker("Music", selection: Binding(get: { selectedTarget?.id }, set: { selectedTargetID = $0 })) {
                            if targets.isEmpty { Text("No music available").tag(String?.none) }
                            ForEach(targets) { target in Text(target.title).tag(Optional(target.id)) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("music-lyrics-target-picker")
                    } else {
                        Text("Choose captions to copy into this music. Timings and translations are included.")
                            .foregroundStyle(.secondary)
                        LabeledContent("Music", value: selectedTarget?.title ?? String(localized: "Unavailable"))
                        Picker("Captions", selection: Binding(get: { selectedCaptions?.projectUUID }, set: { selectedCaptionID = $0 })) {
                            if availableCaptions.isEmpty { Text("No captions available").tag(UUID?.none) }
                            ForEach(availableCaptions, id: \.projectUUID) { caption in Text(caption.name).tag(Optional(caption.projectUUID)) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("music-lyrics-caption-picker")
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Spacer(minLength: 0)
                    HStack {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Merge") {
                            if let captions = selectedCaptions, let target = selectedTarget {
                                pendingMerge = .init(captions: captions, target: target)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedTarget == nil || (selectedCaptions?.activeSegmentCount ?? 0) == 0)
                        .accessibilityIdentifier("music-lyrics-merge")
                    }
                }
                .padding(20)
                .frame(width: 600, height: 260)
            }
        }
        .alert("Merge Captions as Lyrics?", isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }), presenting: pendingMerge) { selection in
            Button("Cancel", role: .cancel) { }
            Button("Merge") { merge(selection) }
        } message: { selection in
            Text("Merge captions from “\(selection.captions.name)” into “\(selection.target.title)”? This adds a new lyrics version with the captions’ timings and translations.")
        }
    }

    private func merge(_ selection: MergeSelection) {
        preparing = true
        error = nil
        Task { @MainActor in
            defer { preparing = false }
            do {
                guard captionProjects.contains(where: { $0.projectUUID == selection.captions.projectUUID }),
                      selection.captions.activeSegmentCount > 0 else { throw MusicLyrics.LyricsError.emptyCaptions }
                guard targets.contains(where: { $0.id == selection.target.id }) else { throw MusicLyrics.LyricsError.missingAudio }
                let lyrics = try await MusicLyrics.prepare(for: selection.target.id, context: context)
                try MusicLyrics.merge(selection.captions, into: lyrics, context: context)
                self.lyrics = lyrics
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MusicLyricsInspector: View {
    let project: CaptionProject

    var body: some View {
        VStack(spacing: 0) {
            CaptionProjectViewer(project: project)
            Divider()
            HStack {
                MusicLyricsRemoveButton(project: project)
                Spacer()
            }.padding(10)
        }
    }
}

private struct MusicLyricsRemoveButton: View {
    let project: CaptionProject
    var onRemoved: () -> Void = { }
    @State private var removingLyrics: CaptionProject?

    var body: some View {
        if project.lyricsSourceID != nil {
            Button("Remove Lyrics…", role: .destructive) { removingLyrics = project }
                .accessibilityIdentifier("music-lyrics-remove")
                .modifier(MusicLyricsRemovalConfirmation(project: $removingLyrics, onRemoved: onRemoved))
        }
    }
}

private struct MusicLyricsRemovalConfirmation: ViewModifier {
    @Binding var project: CaptionProject?
    var onRemoved: () -> Void = { }
    @Environment(\.modelContext) private var context
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Remove Lyrics from Music?", isPresented: Binding(get: { project != nil }, set: { if !$0 { project = nil } }), presenting: project) { lyrics in
                Button("Cancel", role: .cancel) { }
                Button("Remove Lyrics", role: .destructive) {
                    guard let sourceID = lyrics.lyricsSourceID else { return }
                    do {
                        try MusicLyrics.remove(from: sourceID, context: context)
                        onRemoved()
                    } catch { self.error = error.localizedDescription }
                }
            } message: { lyrics in
                Text("Remove “\(lyrics.name)” from this music? The captions will stay in the library, and the music’s audio will be kept.")
            }
            .alert("Couldn’t Remove Lyrics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

struct MusicLyricsPlayback: View {
    @Query private var projects: [CaptionProject]
    let player: FootagePlayer
    @State private var language: String?

    init(sourceID: String, player: FootagePlayer) {
        _projects = Query(filter: #Predicate<CaptionProject> { $0.lyricsSourceID == sourceID })
        self.player = player
    }

    var body: some View {
        if let project = projects.first {
            let tracks = MusicLyrics.tracks(for: project)
            if !tracks.isEmpty {
                let selected = language == "" ? "" : tracks.first { $0.language == language }?.language ?? tracks.first?.language ?? ""
                VStack(spacing: 8) {
                    MusicLyricsCaptionText(track: tracks.first { $0.language == selected }, player: player)
                    Picker("Lyrics", selection: Binding(get: { selected }, set: { language = $0 })) {
                        Text("Off").tag("")
                        ForEach(tracks) { track in
                            Text(track.language == "und" ? String(localized: "Original") : track.displayName).tag(track.language)
                        }
                    }
                    .fixedSize().accessibilityIdentifier("music-lyrics-preview-language")
                }.padding(.horizontal, 24)
            }
        }
    }
}

/// Isolate the playback clock so cue/translation snapshots are rebuilt only
/// when the caption project changes, rather than on every video frame.
private struct MusicLyricsCaptionText: View {
    let track: MarketplaceLyricTrack?
    let player: FootagePlayer

    var body: some View {
        Text(track?.text(at: player.currentTime) ?? "")
            .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white)
            .frame(minHeight: 52)
            .accessibilityIdentifier("music-lyrics-caption")
    }
}
