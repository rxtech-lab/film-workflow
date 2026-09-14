import SwiftData
import SwiftUI
import VideoEditorCore

struct MusicLyricsRequest: Identifiable, Equatable {
    enum Action: Equatable { case edit, retime, merge(UUID), chooseCaptions, chooseMusic }
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
    @State private var error: String?
    @State private var preparing = false

    struct Presentation: Identifiable {
        let id = UUID()
        let project: CaptionProject
        let action: MusicLyricsRequest.Action
        let suggestedText: String
    }

    func body(content: Content) -> some View {
        content
            .task(id: request) { await open() }
            .overlay { if preparing { ProgressView("Opening lyrics…").padding().background(.regularMaterial) } }
            .sheet(item: $presentation, onDismiss: {
                do { try context.save() } catch { self.error = error.localizedDescription }
            }) { value in
                if value.action == .chooseMusic {
                    MusicLyricsTargetPicker(captions: value.project)
                } else if value.action == .chooseCaptions {
                    MusicLyricsCaptionPicker(project: value.project)
                } else if value.action == .retime, !value.project.activeSegments.isEmpty {
                    CaptionRetimeSheet(project: value.project)
                } else {
                    MusicLyricsEditor(project: value.project, suggestedText: value.suggestedText)
                }
            }
            .alert("Couldn’t Open Lyrics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func open() async {
        guard let request else { return }
        preparing = true
        defer { preparing = false; self.request = nil }
        do {
            if request.action == .chooseMusic {
                guard let (prefix, id) = DocumentMediaResolver.parse(request.sourceID), prefix == .caption,
                      let captions = try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first
                else { throw MusicLyrics.LyricsError.emptyCaptions }
                presentation = .init(project: captions, action: .chooseMusic, suggestedText: "")
                return
            }
            let caption: CaptionProject?
            if case .merge(let id) = request.action {
                guard let value = try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first,
                      !value.activeSegments.isEmpty else { throw MusicLyrics.LyricsError.emptyCaptions }
                caption = value
            } else { caption = nil }
            let project = try await MusicLyrics.prepare(for: request.sourceID, context: context)
            try Task.checkCancellation()
            if let caption { try MusicLyrics.merge(caption, into: project, context: context) }
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

private struct MusicLyricsTargetPicker: View {
    let captions: CaptionProject
    @Query private var music: [GeneratedMusic]
    @Query private var imported: [ImportedAsset]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: CaptionProject?
    @State private var error: String?
    @State private var preparing = false

    var body: some View {
        if let lyrics {
            MusicLyricsEditor(project: lyrics)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Merge as Lyrics into Music").font(.headline)
                Text("Choose the music take for these captions.").foregroundStyle(.secondary)
                List(MusicLyrics.targets(music: music, imported: imported).filter { $0.id != captions.lyricsSourceID }) { target in
                    Button(target.title) {
                        preparing = true
                        Task { @MainActor in
                            defer { preparing = false }
                            do {
                                let lyrics = try await MusicLyrics.prepare(for: target.id, context: context)
                                try MusicLyrics.merge(captions, into: lyrics, context: context)
                                self.lyrics = lyrics
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(preparing)
                }
                if preparing { ProgressView("Opening lyrics…") }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Cancel") { dismiss() }.disabled(preparing)
            }.padding().frame(width: 600, height: 420)
        }
    }
}

/// Timeline menus contain flat actions, so their merge action chooses the
/// caption project here before opening the same caption editor.
private struct MusicLyricsCaptionPicker: View {
    let project: CaptionProject
    @Query private var captions: [CaptionProject]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var merged = false
    @State private var error: String?

    var body: some View {
        if merged {
            MusicLyricsEditor(project: project)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Merge Captions as Lyrics").font(.headline)
                Text("Choose captions to copy into this music. Timings and translations are included.")
                    .foregroundStyle(.secondary)
                List(captions.filter { $0 !== project && !$0.activeSegments.isEmpty }, id: \.projectUUID) { caption in
                    Button(caption.name) {
                        do { try MusicLyrics.merge(caption, into: project, context: context); merged = true }
                        catch { self.error = error.localizedDescription }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Cancel") { dismiss() }
            }.padding().frame(width: 600, height: 420)
        }
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
