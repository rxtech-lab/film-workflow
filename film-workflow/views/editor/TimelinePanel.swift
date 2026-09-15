import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI
import VideoEffectsUI

/// Bottom panel: the current sequence's timeline.
struct TimelinePanel: View {
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let sequence: SequenceProject?
    let onCreateSequence: () -> Void
    let previewRevision: String
    @State private var remotionRevision = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @State private var dropError: String?
    @State private var captionError: String?
    @State private var browserVisible: Bool
    /// Gates the marketplace action on a clip; refreshed by `LibraryPanel`.
    @State private var authoring = MarketplaceAuthoringService.shared
    @State private var seedRequest: MarketplaceSeedRequest?
    @State private var lyricsRequest: MusicLyricsRequest?

    init(state: EditorWindowState, document: ProjectDocument, sequence: SequenceProject?, previewRevision: String = "", onCreateSequence: @escaping () -> Void) {
        self.state = state
        self.document = document
        self.sequence = sequence
        self.onCreateSequence = onCreateSequence
        self.previewRevision = previewRevision
        _browserVisible = State(initialValue: document.panelLayout.effectsBrowserVisible ?? true)
    }

    var body: some View {
        TimelineBrowserSplit(document: document, browserVisible: browserVisible) {
            timelineColumn
        } browser: {
            VStack(spacing: 0) {
                StudioPanelHeader(title: "Effects & Transitions", symbol: "slider.horizontal.below.rectangle")
                ModifierBrowser { state.modifierSelection = .catalog($0) }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { _ in remotionRevision += 1 }
        .onChange(of: lyricsRequest) { _, request in
            if request != nil { state.player.pause(); state.footagePlayer.pause() }
        }
    }

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StudioPanelHeader(title: "Timeline", symbol: "timeline.selection")
                Button {
                    FilmFeatureTip.effectsBrowser.didPerform()
                    browserVisible.toggle()
                    document.setEffectsBrowserVisible(browserVisible)
                } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).padding(.horizontal, 10)
                    .accessibilityLabel("Effects & Transitions")
                    .help(browserVisible ? "Hide effects and transitions" : "Show effects and transitions")
                    .accessibilityIdentifier("toggle-modifier-browser")
                    .filmTip(.effectsBrowser, when: !browserVisible)
            }
            .background(.bar)
            timelineContent
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if let sequence {
            SequenceTimelineView(
                timeline: Binding(get: { sequence.timeline }, set: { sequence.editTimeline($0, undoManager: undoManager) }),
                playhead: Binding(get: { state.playhead }, set: { state.playhead = $0 }),
                selectedClipIDs: $state.selectedClipIDs,
                primaryClipID: $state.primaryClipID,
                pixelsPerSecond: Binding(get: { sequence.timelinePixelsPerSecond }, set: { sequence.timelinePixelsPerSecond = $0 }),
                skimming: $state.skimsTimeline,
                onSkim: { time in
                    if let time { state.skim(to: time) } else { state.endSkim() }
                },
                resolver: DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps),
                previewRevision: previewRevision + ":\(remotionRevision)",
                onDrop: { item, trackID, time in
                    Task { await insert(item, on: trackID, at: time, into: sequence) }
                },
                onDeleteClips: { ids in
                    var timeline = sequence.timeline
                    TimelineEditor.remove(&timeline, clipIDs: ids)
                    sequence.editTimeline(timeline, undoManager: undoManager,
                                          actionName: ids.count > 1 ? String(localized: "Delete Clips") : String(localized: "Delete Clip"))
                },
                onDeselect: { state.select(nil) },
                alignment: { clip, timeline in
                    CaptionAudioAlignment.alignment(for: clip, in: timeline, context: modelContext)
                },
                clipMenuItems: { clip, _ in
                    narrativeCaptionItems(for: clip, in: sequence) + musicLyricsItems(for: clip) + marketplaceItems(for: clip, in: sequence)
                },
                selectedTransitionID: state.selectedTransitionID,
                onInspectEffects: { state.inspectEffects($0) },
                onInspectTransition: { state.inspectTransition($0) }
            )
            .alert("Couldn’t add footage", isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
                Button("OK") { dropError = nil }
            } message: {
                Text(dropError ?? "")
            }
            .alert("Couldn’t create captions", isPresented: Binding(get: { captionError != nil }, set: { if !$0 { captionError = nil } })) {
                Button("OK") { captionError = nil }
            } message: {
                Text(captionError ?? "")
            }
            .marketplaceSeedHost($seedRequest)
            .musicLyricsHost($lyricsRequest)
        } else {
            VStack(spacing: 0) {
                StudioEmptyState(title: "Build your first sequence", symbol: "film.stack",
                                 message: "Arrange footage, sound and captions on your timeline.")
                    .frame(maxHeight: 130)
                Button("New Sequence", action: onCreateSequence)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { state.select(nil) }

        }
    }

    private func musicLyricsItems(for clip: Clip) -> [ClipMenuItem] {
        if let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .caption,
           let captions = try? modelContext.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first {
            var items: [ClipMenuItem] = []
            if let musicID = captions.lyricsSourceID {
                items.append(ClipMenuItem(id: "music-lyrics-edit", title: String(localized: "Edit Lyrics & Timing…"), systemImage: "music.note.list") {
                    lyricsRequest = .init(sourceID: musicID)
                })
            }
            items.append(ClipMenuItem(id: "music-lyrics-target", title: String(localized: "Merge as Lyrics into Music…"),
                                     systemImage: "music.note.list", isEnabled: !captions.activeSegments.isEmpty) {
                lyricsRequest = .init(sourceID: clip.source.id, action: .chooseMusic)
            })
            return items
        }
        guard clip.source.kind == .audio,
              let (prefix, _) = DocumentMediaResolver.parse(clip.source.id), prefix == .music || prefix == .imported
        else { return [] }
        let project = try? MusicLyrics.project(for: clip.source.id, context: modelContext)
        var items = [ClipMenuItem(id: "music-lyrics-edit", title: project == nil
                                 ? String(localized: "Add Lyrics Timing…") : String(localized: "Edit Lyrics & Timing…"),
                                 systemImage: "music.note.list") {
            lyricsRequest = .init(sourceID: clip.source.id)
        }]
        if let project, !project.activeSegments.isEmpty {
            items.append(ClipMenuItem(id: "music-lyrics-retime", title: String(localized: "Retime Lyrics…"), systemImage: "timeline.selection") {
                lyricsRequest = .init(sourceID: clip.source.id, action: .retime)
            })
        }
        items.append(ClipMenuItem(id: "music-lyrics-merge", title: String(localized: "Merge Captions as Lyrics…"), systemImage: "captions.bubble") {
            lyricsRequest = .init(sourceID: clip.source.id, action: .chooseCaptions)
        })
        if project != nil {
            items.append(ClipMenuItem(id: "music-lyrics-remove", title: String(localized: "Remove Lyrics…"), systemImage: "text.badge.minus") {
                lyricsRequest = .init(sourceID: clip.source.id, action: .remove)
            })
        }
        return items
    }

    /// "Create Marketplace Item…" on a clip, which starts a draft from the
    /// file behind it.
    ///
    /// The clip's kind is all that is checked here: resolving it to a file is
    /// asynchronous, and a menu cannot wait. The file is resolved when the item
    /// is chosen, and a source the marketplace turns out to have no slot for
    /// says so in an alert rather than going missing from the menu.
    private func marketplaceItems(for clip: Clip, in sequence: SequenceProject) -> [ClipMenuItem] {
        guard authoring.canAuthor, MarketplaceKind.canBeFootage(clip.source.kind),
              !isFromMarketplace(clip.source) else { return [] }
        return [
            ClipMenuItem(id: "marketplace-item", title: String(localized: "Create Marketplace Item…"), systemImage: "storefront") {
                seedMarketplaceItem(from: clip, in: sequence)
            }
        ]
    }

    /// Whether the clip stands on something added from the marketplace, which
    /// is never offered back to it. Only the two kinds `MarketplaceInstaller`
    /// creates can be, and both name their model in the source id, so this
    /// stays a lookup a menu can afford.
    private func isFromMarketplace(_ source: ClipSource) -> Bool {
        guard let (prefix, id) = DocumentMediaResolver.parse(source.id) else { return false }
        switch prefix {
        case .imported:
            return (try? modelContext.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == id })))?.first?.marketplaceItemId != nil
        case .remotion:
            return (try? modelContext.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == id })))?.first?.marketplaceItemId != nil
        case .music, .narration, .image, .video, .caption, .screenRecording, .recordingZoom:
            return false
        }
    }

    private func seedMarketplaceItem(from clip: Clip, in sequence: SequenceProject) {
        // A composition publishes its project, which the clip's id names
        // directly — no need to resolve it to a rendered file first.
        if clip.source.kind == .remotion, let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .remotion {
            seedRequest = .remotion(title: clip.source.displayName, projectID: id, renderID: nil)
            return
        }
        Task {
            let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
            let file = try? await resolver.resolve(clip.source).fileURL
            seedRequest = .file(title: clip.source.displayName, sourceKind: clip.source.kind, file: file)
        }
    }

    /// "Create Captions" on a narration clip: builds the narration's caption
    /// project and lays it over this clip, ready to transcribe.
    private func narrativeCaptionItems(for clip: Clip, in sequence: SequenceProject) -> [ClipMenuItem] {
        guard let (prefix, id) = DocumentMediaResolver.parse(clip.source.id), prefix == .narration,
              let generated = try? modelContext.fetch(FetchDescriptor<GeneratedNarrative>(predicate: #Predicate { $0.id == id })).first,
              let narrative = generated.project
        else { return [] }
        let exists = generated.captionProjectID.flatMap { captionID in
            try? modelContext.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == captionID })).first
        } != nil
        return [
            ClipMenuItem(id: "narrative-captions",
                         title: exists ? String(localized: "Add Captions to Timeline")
                                       : String(localized: "Create Captions"),
                         systemImage: "captions.bubble") {
                createCaptions(for: generated, narrative: narrative, sequence: sequence)
            }
        ]
    }

    private func createCaptions(for generated: GeneratedNarrative, narrative: NarrativeProject, sequence: SequenceProject) {
        Task {
            do {
                let result = try await NarrativeCaptionClip.create(
                    for: generated, narrative: narrative, sequence: sequence,
                    playhead: state.playhead, context: modelContext, undoManager: undoManager
                )
                // Selecting the clip puts the caption project in the inspector,
                // where Transcribe is one click away.
                if let clipID = result.clipID {
                    state.selectedClipID = clipID
                } else {
                    state.select(LibraryItemID(kind: .caption, id: result.project.projectUUID))
                }
            } catch {
                captionError = error.localizedDescription
            }
        }
    }

    /// The caption project's default style, so a dropped clip looks the way its Style tab says.
    private func captionStyle(for source: ClipSource) -> TextStyle {
        guard let (prefix, id) = DocumentMediaResolver.parse(source.id), prefix == .caption,
              let project = try? modelContext.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == id })).first
        else { return .caption }
        return project.captionStyle
    }

    /// Resolves the dropped footage to learn its natural length before placing it.
    private func insert(_ item: FootageDragItem, on trackID: UUID, at time: TimeInterval, into sequence: SequenceProject) async {
        if let (prefix, id) = DocumentMediaResolver.parse(item.source.id), prefix == .screenRecording {
            do {
                let take = try RecordingTimelineService.take(id: id, context: modelContext)
                let ids = try RecordingTimelineService.insert(take: take, into: sequence, at: time, undoManager: undoManager)
                state.selectedClipID = ids.first
            } catch { dropError = error.localizedDescription }
            return
        }
        var duration = item.duration ?? 0
        if duration <= 0, item.source.kind != .image {
            let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
            if let media = try? await resolver.resolve(item.source) {
                switch media {
                case .file(_, let natural, _): duration = natural ?? 0
                case .captions(let cues): duration = cues.map(\.end).max() ?? 0
                }
            }
        }
        if duration <= 0 { duration = FootageDragItem.defaultStillDuration }

        var timeline = sequence.timeline
        let clip = Clip(source: item.source, start: time, duration: duration, sourceDuration: item.source.kind == .image ? nil : duration,
                        text: item.source.kind == .captions ? captionStyle(for: item.source) : nil)
        do {
            try TimelineEditor.insert(&timeline, clip: clip, on: trackID)
            sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Add Clip"))
            state.selectedClipID = clip.id
        } catch TimelineEditError.overlap {
            if let free = TimelineEditor.nextFreeStart(timeline, on: trackID, at: time, duration: duration) {
                var moved = clip
                moved.start = free
                if (try? TimelineEditor.insert(&timeline, clip: moved, on: trackID)) != nil {
                    sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Add Clip"))
                    state.selectedClipID = moved.id
                    return
                }
            }
            dropError = "There is no room on that track at the drop point."
        } catch {
            dropError = error.localizedDescription
        }
    }
}
