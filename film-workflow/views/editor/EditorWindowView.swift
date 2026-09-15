import AppKit
import SwiftData
import SwiftUI
import TipKit
import UniformTypeIdentifiers
import VideoEditorCore

/// The Final Cut–style editor: library, viewer, inspector and timeline.
struct EditorWindowView: View {
    let document: ProjectDocument

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @Environment(AgentController.self) private var agentController

    @Query(sort: \MusicProject.updatedAt, order: .reverse) private var music: [MusicProject]
    @Query(sort: \NarrativeProject.updatedAt, order: .reverse) private var narrations: [NarrativeProject]
    @Query(sort: \CaptionProject.updatedAt, order: .reverse) private var captions: [CaptionProject]
    @Query(sort: \ImageGenProject.updatedAt, order: .reverse) private var images: [ImageGenProject]
    @Query(sort: \VideoGenProject.updatedAt, order: .reverse) private var videos: [VideoGenProject]
    @Query(sort: \RemotionProject.updatedAt, order: .reverse) private var remotions: [RemotionProject]
    @Query(sort: \ImportedAsset.updatedAt, order: .reverse) private var imported: [ImportedAsset]
    @Query(sort: \SequenceProject.updatedAt, order: .reverse) private var sequences: [SequenceProject]
    @Query(sort: \ProjectGroup.name) private var groups: [ProjectGroup]
    @Query(sort: \SequenceRender.versionNumber, order: .reverse) private var sequenceRenders: [SequenceRender]
    @Query(sort: \RemotionRender.versionNumber, order: .reverse) private var remotionRenders: [RemotionRender]

    @State private var state = EditorWindowState()
    /// The last focus this window moved to; see ``TimelineFocus``.
    @State private var appliedFocus: UUID?
    @State private var isFirstFocus = true
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var renamingRow: LibraryRow?
    @State private var renameText = ""
    @State private var pendingDeletion: LibraryRow?
    @State private var versionsTarget: LibraryVersionsTarget?
    @State private var exportingRemotion: RemotionProject?
    @State private var captionError: String?

    private var index: LibraryIndex {
        LibraryIndex(music: music, narrations: narrations, captions: captions, images: images, videos: videos,
                     remotions: remotions, imported: imported, sequences: sequences,
                     sequenceRenders: sequenceRenders, remotionRenders: remotionRenders)
    }

    /// Generated audio recorded before lengths were stored. Keyed on ids so
    /// the backfill runs once per set of files, not on every re-render.
    private var unmeasuredAudioIDs: [UUID] {
        music.flatMap(\.generatedFiles).filter { $0.durationSeconds <= 0 }.map(\.id)
            + narrations.flatMap(\.generatedFiles).filter { $0.durationSeconds <= 0 }.map(\.id)
    }

    /// Reads and records the length of older audio so the library can show it.
    private func backfillAudioDurations() async {
        let files: [(url: URL, set: (Double) -> Void)] =
            music.flatMap(\.generatedFiles).filter { $0.durationSeconds <= 0 }.map { f in (f.audioURL, { f.durationSeconds = $0 }) }
            + narrations.flatMap(\.generatedFiles).filter { $0.durationSeconds <= 0 }.map { f in (f.audioURL, { f.durationSeconds = $0 }) }
        guard !files.isEmpty else { return }
        var changed = false
        for file in files {
            if Task.isCancelled { break }
            let seconds = await AudioProbe.durationSeconds(of: file.url)
            guard seconds > 0 else { continue }
            file.set(seconds)
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    private var currentSequence: SequenceProject? {
        if let id = state.currentSequenceID, let s = index.sequence(id) { return s }
        return sequences.first
    }

    var body: some View {
        GeometryReader { geometry in
            VSplitView {
                HSplitView {
                    LibraryPanel(index: index, groups: groups, state: state, document: document,
                                 onCreate: create, onMove: move, onImport: chooseFilesToImport, onCreateGroup: beginCreatingGroup,
                                 onRenameGroup: beginRenamingGroup, onDeleteGroup: { pendingGroupDeletion = $0 },
                                 onRename: beginRenaming, onDelete: { pendingDeletion = $0 },
                                 onExport: { exportingRemotion = index.remotion($0.id.id) },
                                 onShowVersions: { versionsTarget = LibraryVersionsTarget(item: $0.id, versionID: $1) },
                                 onCreateCaptions: createCaptions,
                                 onGenerateCaptions: generateCaptions)
                        .frame(minWidth: 240, idealWidth: geometry.size.width / 3, maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                    ViewerPanel(index: index, state: state, document: document, sequence: currentSequence, onRetryModifierPreview: reloadPlayer)
                        .frame(minWidth: 320, idealWidth: max(320, geometry.size.width * 2 / 3 - 320), maxWidth: .infinity, maxHeight: .infinity)
                        .background(PersistedPanelSplit(document: document, panel: .editorColumns))
                    InspectorPanel(index: index, state: state, document: document, sequence: currentSequence, onRender: beginRender)
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 460, maxHeight: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(minHeight: 300, idealHeight: geometry.size.height * 0.68, maxHeight: .infinity)
                TimelinePanel(state: state, document: document, sequence: currentSequence,
                              previewRevision: index.rows().map { "\($0.id.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: ":"),
                              onCreateSequence: { create(.sequence, nil) })
                    .frame(minHeight: 190, idealHeight: geometry.size.height * 0.32, maxHeight: .infinity)
                    .background(PersistedPanelSplit(document: document, panel: .editorRows))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 920, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbar }
        .focusedSceneValue(\.importMedia, chooseFilesToImport)
        .publishesAgentTarget(agentTarget)
        .onChange(of: currentSequence?.id, initial: true) { _, _ in
            state.currentSequenceID = currentSequence?.id
            reloadPlayer()
        }
        .onChange(of: currentSequence?.timelineData) { _, _ in
            let stale = state.selectedClipIDs.filter { currentSequence?.timeline.clip(id: $0) == nil }
            if !stale.isEmpty { state.selectedClipIDs.subtract(stale) }
            if let id = state.selectedTransitionID, currentSequence?.timeline.transitions.contains(where: { $0.id == id }) != true {
                state.modifierSelection = nil
            }
            reloadPlayer()
        }
        .onChange(of: remotions.map { "\($0.id):\($0.durationSeconds):\($0.compositionFps):\($0.compositionWidth):\($0.compositionHeight):\($0.compositionSource.isEmpty)" }) { _, _ in
            if currentSequence?.timeline.renderedClips.contains(where: { $0.source.kind == .remotion }) == true { reloadPlayer() }
        }
        .task(id: document.pendingTimelineFocus) {
            defer { isFirstFocus = false }
            await followTimelineFocus()
        }
        .onDisappear { state.modifierPreviewGeneration = UUID(); state.modifierPreviewTask?.cancel(); state.preview.unload(); state.player.unload() }
        .task(id: unmeasuredAudioIDs) { await backfillAudioDurations() }
        // A pointer that leaves with the app never reports the hover ending, so
        // the skim it started would outlive the visit and pin the viewer to
        // that take once the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            state.endFootageSkim()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { notification in
            guard let directory = notification.userInfo?["directory"] as? URL,
                  directory.path.hasPrefix(document.packageURL.path + "/"),
                  currentSequence?.timeline.renderedClips.contains(where: { $0.source.kind == .remotion }) == true else { return }
            reloadPlayer()
        }
        .sheet(isPresented: $state.showImportSheet) {
            MediaImportSheet(urls: state.pendingImportURLs, groupID: nil) {
                state.showImportSheet = false
                state.pendingImportURLs = []
            }
        }
        .sheet(isPresented: $state.showRenderSheet) {
            if let sequence = currentSequence {
                SequenceRenderSheet(sequence: sequence) { options, captions, destination in
                    state.showRenderSheet = false
                    startRender(sequence: sequence, options: options, captions: captions, destination: destination)
                } onCancel: {
                    state.showRenderSheet = false
                }
            }
        }
        .sheet(isPresented: Binding(get: { state.renderProgress != nil }, set: { if !$0 { state.renderProgress = nil } })) {
            SequenceRenderProgressSheet(
                sequenceName: currentSequence?.name ?? "",
                progress: state.renderProgress ?? .finalizing
            ) {
                state.renderTask?.cancel()
            }
        }
        .alert("Render failed", isPresented: $state.showRenderError) {
            Button("OK") {}
        } message: {
            Text(state.renderError ?? "An unknown error occurred.")
        }
        .sheet(item: $versionsTarget) { target in
            LibraryVersionsSheet(index: index, target: target) { versionsTarget = nil }
        }
        .alert("Couldn’t create captions", isPresented: Binding(get: { captionError != nil }, set: { if !$0 { captionError = nil } })) {
            Button("OK") { captionError = nil }
        } message: {
            Text(captionError ?? "")
        }
        .remotionExportToDisk(project: $exportingRemotion)
        .sheet(item: $renamingRow) { row in
            RenameSheet(name: $renameText) {
                rename(row, to: renameText)
                renamingRow = nil
            } onCancel: {
                renamingRow = nil
            }
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { row in
            Button("Delete", role: .destructive) {
                delete(row)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { row in
            Text(ProjectLifecycleService.deletionMessage(for: row.id.kind, name: row.name))
        }
        .projectGroupDialogs(editor: $groupEditor, name: $groupName, pendingDeletion: $pendingGroupDeletion, errorMessage: $groupErrorMessage)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            importDropped(providers)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(FootageKind.creatable) { kind in
                    Button { FilmFeatureTip.newFootage.didPerform(); create(kind, nil) } label: { Label(kind.displayName, systemImage: kind.systemImage) }
                }
                Divider()
                Button { beginCreatingGroup() } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
            } label: {
                Label("New", systemImage: "plus")
            }
            .filmTip(.newFootage)
            Button {
                FilmFeatureTip.importMedia.didPerform()
                chooseFilesToImport()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .filmTip(.importMedia)
            .help("Import video, audio or images from disk")
            AccountControl(placement: .toolbar)
        }
        ToolbarSpacer(.flexible, placement: .automatic)
        ToolbarItemGroup(placement: .automatic) {
            Button {
                FilmFeatureTip.sequenceRender.didPerform()
                beginRender()
            } label: {
                if state.renderProgress != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Render", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(currentSequence == nil || currentSequence?.timeline.isEmpty == true || state.renderProgress != nil)
            .help("Render the current sequence as a new version")
            .filmTip(.sequenceRender, when: currentSequence != nil && currentSequence?.timeline.isEmpty == false && state.renderProgress == nil)
            Button {
                openWindow(id: MarketplaceWindowID.value)
            } label: {
                Label("Marketplace", systemImage: "storefront")
            }
            .help("Browse footage, sounds, fonts and effects to install")
            .popoverTip(FilmWorkflowTips.MarketplaceTip(), arrowEdge: .top)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: AgentWindowID.value)
            } label: {
                Label("Agent", systemImage: "sparkles")
                    .overlay(alignment: .topTrailing) {
                        if agentController.runningCount > 0 {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
            .help(agentController.runningCount > 0 ? "Open the agent (running)" : "Open the agent")
            .popoverTip(FilmWorkflowTips.AgentButtonTip(), arrowEdge: .top)
        }
    }

    private var agentTarget: AgentTarget {
        guard let selection = state.selection, let kind = selection.kind.agentKind else { return .none }
        return AgentTarget(kind: kind, projectUUID: selection.id)
    }

    // MARK: - Library actions

    private func create(_ kind: FootageKind, _ groupID: UUID?) {
        if let item = ProjectLifecycleService.create(kind: kind, groupID: groupID, context: modelContext) {
            try? modelContext.save()
            state.select(item, updateViewer: kind == .sequence)
        }
    }

    private func move(_ item: LibraryItemID, to groupID: UUID?) {
        do {
            switch item.kind {
            case .music: if let p = index.music(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .narration: if let p = index.narration(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .caption: if let p = index.caption(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .image: if let p = index.image(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .video: if let p = index.video(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .remotion: if let p = index.remotion(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .sequence: if let p = index.sequence(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            case .imported: if let p = index.imported(item.id) { try ProjectGroupService.move(p, to: groupID, context: modelContext) }
            }
        } catch {
            groupErrorMessage = error.localizedDescription
        }
    }

    private func beginCreatingGroup() {
        groupName = ""
        groupEditor = .create
    }

    private func beginRenamingGroup(_ group: ProjectGroup) {
        groupName = group.name
        groupEditor = .rename(group)
    }

    private func beginRenaming(_ row: LibraryRow) {
        renameText = row.name
        renamingRow = row
    }

    private func rename(_ row: LibraryRow, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = row.id.id
        switch row.id.kind {
        case .music: index.music(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .narration: index.narration(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .caption: index.caption(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .image: index.image(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .video: index.video(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .remotion: index.remotion(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .sequence: index.sequence(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        case .imported: index.imported(id).map { $0.name = trimmed; $0.updatedAt = Date() }
        }
    }

    /// Captions for the narration take the library is showing: the caption
    /// project is created and laid over the narration on the timeline, but
    /// nothing is transcribed — the user starts that from the inspector, which
    /// the new clip's selection opens onto.
    private func createCaptions(_ row: LibraryRow) {
        guard let narrative = index.narration(row.id.id) else { return }
        let current = state.currentVersion(for: row.id)
        let file = current.flatMap { id in narrative.generatedFiles.first { $0.id == id } }
            ?? narrative.generatedFiles.max { $0.createdAt < $1.createdAt }
        guard let file else {
            captionError = NarrativeCaptionClip.Failure.noAudio.errorDescription
            return
        }
        Task {
            do {
                let result = try await NarrativeCaptionClip.create(
                    for: file, narrative: narrative, sequence: currentSequence,
                    playhead: state.playhead, context: modelContext, undoManager: undoManager
                )
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

    /// Captions for one of the film's own recordings — a music take or an
    /// imported audio file. Like the narration action, the project is created
    /// and laid over the audio on the timeline but nothing is transcribed:
    /// starting that stays the user's call in the inspector, which the new
    /// clip's selection opens onto.
    private func generateCaptions(forAudio sourceID: String) {
        Task {
            do {
                let project = try await CaptionAudioSource.prepareProject(for: sourceID, context: modelContext)
                let seconds = Double(project.audioDurationMs) / 1000
                guard let sequence = currentSequence else {
                    state.select(LibraryItemID(kind: .caption, id: project.projectUUID))
                    return
                }
                var timeline = sequence.timeline
                // Captions already on the timeline are shown rather than laid
                // down again, so repeating the action leaves no empty undo step.
                if let existing = NarrativeCaptionClip.clip(playing: project.dragItem.source.id, in: timeline) {
                    state.selectedClipID = existing.id
                    return
                }
                guard let placement = NarrativeCaptionClip.placement(
                    playing: sourceID, in: timeline, audioDuration: seconds, fallbackStart: state.playhead
                ) else {
                    state.select(LibraryItemID(kind: .caption, id: project.projectUUID))
                    return
                }
                let clipID = try NarrativeCaptionClip.insert(
                    source: project.dragItem.source,
                    style: project.captionStyle,
                    placement: placement,
                    sourceDuration: seconds > 0 ? seconds : nil,
                    into: &timeline
                )
                sequence.editTimeline(timeline, undoManager: undoManager, actionName: String(localized: "Add Captions"))
                state.selectedClipID = clipID
            } catch {
                captionError = error.localizedDescription
            }
        }
    }

    private func delete(_ row: LibraryRow) {
        if row.id.kind == .sequence, let sequence = index.sequence(row.id.id) {
            undoManager?.removeAllActions(withTarget: sequence)
        }
        if state.selection == row.id { state.select(nil, updateViewer: false) }
        if state.viewerSelection == row.id { state.viewerSelection = nil }
        if row.id.kind == .sequence, state.currentSequenceID == row.id.id {
            state.currentSequenceID = nil
            state.player.unload()
        }
        ProjectLifecycleService.delete(row.id, context: modelContext)
    }

    // MARK: - Import

    private func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Import Media"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        state.pendingImportURLs = panel.urls
        state.showImportSheet = true
    }

    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = try? await provider.loadFileURL() { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            state.pendingImportURLs = urls
            state.showImportSheet = true
        }
        return true
    }

    // MARK: - Player and render

    /// Follows the agent: when a tool changes a clip, show that clip.
    ///
    /// Without this the timeline rearranges itself while the playhead sits
    /// wherever the user left it, and a long build looks like nothing is
    /// happening. Playback the user started is left alone.
    private func followTimelineFocus() async {
        guard let focus = document.pendingTimelineFocus else { return }
        // Whatever was pending when this window opened belongs to work that
        // finished elsewhere; following it would yank the playhead the moment
        // the editor appears.
        guard appliedFocus != nil || !isFirstFocus else {
            appliedFocus = focus.token
            return
        }
        guard appliedFocus != focus.token else { return }
        // Watching takes precedence over following: seeking pauses the player
        // and moves the viewer, so a user who pressed play would have the film
        // stop under them every time the agent touched a clip.
        guard !state.player.isPlaying else {
            appliedFocus = focus.token
            return
        }
        if state.currentSequenceID != focus.sequenceID {
            guard index.sequence(focus.sequenceID) != nil else { return }
            state.currentSequenceID = focus.sequenceID
        }
        guard await TimelineFocusFollower.waitUntilLoaded(state.player) else { return }
        guard document.pendingTimelineFocus == focus else { return }
        appliedFocus = focus.token
        state.selectedClipIDs = focus.clipID.map { [$0] } ?? []
        state.playhead = focus.time
    }

    private func reloadPlayer() {
        state.modifierPreviewTask?.cancel()
        state.modifierPreviewGeneration = UUID()
        state.modifierPreviewProgress = nil
        state.modifierPreviewError = nil
        guard let sequence = currentSequence else {
            state.preview.unload()
            state.player.unload()
            return
        }
        if sequence.timeline.hasActiveModifiers && sequence.timeline.renderedClips.contains(where: { $0.source.kind == .remotion }) {
            loadRenderedModifierPreview(sequence)
        } else if sequence.timeline.renderedClips.contains(where: { $0.source.kind == .remotion }) {
            state.preview.load(sequence.timeline, resolver: DocumentPreviewMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps))
        } else {
            state.preview.unload()
            let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
            state.player.load(sequence.timeline, resolver: resolver)
        }
    }

    private func loadRenderedModifierPreview(_ sequence: SequenceProject) {
        state.preview.unload()
        state.player.setBuffering(true)
        state.modifierPreviewProgress = "Preparing rendered preview…"
        let timeline = sequence.timeline
        let resolver = DocumentPreviewMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        let fallback = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        let generation = state.modifierPreviewGeneration
        state.modifierPreviewTask = Task { @MainActor in
            defer { resolver.release() }
            do {
                var files: [String: ResolvedMedia] = [:]
                for clip in timeline.renderedClips where clip.source.kind == .remotion && files[clip.source.id] == nil {
                    files[clip.source.id] = try await resolver.renderedPreview(clip.source) { label in
                        if state.modifierPreviewGeneration == generation { state.modifierPreviewProgress = label }
                    }
                    try Task.checkCancellation()
                }
                guard state.modifierPreviewGeneration == generation else { return }
                state.player.setBuffering(false)
                state.player.load(timeline, resolver: RenderedModifierMediaResolver(files: files, fallback: fallback))
                state.modifierPreviewProgress = nil
            } catch {
                guard !Task.isCancelled, state.modifierPreviewGeneration == generation else { return }
                state.modifierPreviewProgress = nil
                state.modifierPreviewError = error.localizedDescription
                state.player.setBuffering(true)
            }
        }
    }

    private func beginRender() {
        guard currentSequence != nil else { return }
        state.showRenderSheet = true
    }

    private func startRender(sequence: SequenceProject, options: TimelineExporter.Options, captions: CaptionRenderRequest, destination: SequenceRenderDestination) {
        state.renderError = nil
        state.renderProgress = .exporting(0)
        state.renderTask = Task { @MainActor in
            defer {
                state.renderProgress = nil
                state.renderTask = nil
            }
            do {
                let output = try await SequenceRenderService.render(sequence: sequence, document: document, options: options, captions: captions, destination: destination) { p in
                    state.renderProgress = p
                }
                switch output {
                case .version:
                    reloadPlayer()
                case .file(let url, let captionFiles):
                    NSWorkspace.shared.activateFileViewerSelecting([url] + captionFiles)
                }
            } catch is CancellationError {
                // User cancelled.
            } catch TimelineExportError.cancelled {
                // Same, surfaced by the exporter.
            } catch {
                state.renderError = error.localizedDescription
                state.showRenderError = true
            }
        }
    }
}

extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Quiet content surfaces keep glass reserved for navigation and actions.
/// A panel's title bar. Controls that switch what the panel shows, such as
/// the inspector's tab row, go in `accessory` so they sit beside the title
/// instead of taking a row of their own.
struct StudioPanelHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let accessory: Accessory

    init(title: LocalizedStringKey, symbol: String) where Accessory == EmptyView {
        self.title = title
        self.symbol = symbol
        self.accessory = EmptyView()
    }

    init(title: LocalizedStringKey, symbol: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).fontWeight(.semibold)
            Spacer()
            accessory.controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct StudioEmptyState: View {
    let title: LocalizedStringKey
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportMediaFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var importMedia: (() -> Void)? {
        get { self[ImportMediaFocusKey.self] }
        set { self[ImportMediaFocusKey.self] = newValue }
    }
}

struct MediaImportCommands: Commands {
    @FocusedValue(\.importMedia) private var importMedia

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Media…") { importMedia?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importMedia == nil)
        }
    }
}
