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

    @State private var state = EditorWindowState()
    @State private var groupEditor: ProjectGroupEditorTarget?
    @State private var groupName = ""
    @State private var pendingGroupDeletion: ProjectGroup?
    @State private var groupErrorMessage: String?
    @State private var renamingRow: LibraryRow?
    @State private var renameText = ""
    @State private var pendingDeletion: LibraryRow?

    private var index: LibraryIndex {
        LibraryIndex(music: music, narrations: narrations, captions: captions, images: images, videos: videos,
                     remotions: remotions, imported: imported, sequences: sequences)
    }

    private var currentSequence: SequenceProject? {
        if let id = state.currentSequenceID, let s = index.sequence(id) { return s }
        return sequences.first
    }

    var body: some View {
        VSplitView {
            HSplitView {
                LibraryPanel(index: index, groups: groups, state: state,
                             onCreate: create, onMove: move, onCreateGroup: beginCreatingGroup,
                             onRenameGroup: beginRenamingGroup, onDeleteGroup: { pendingGroupDeletion = $0 },
                             onRename: beginRenaming, onDelete: { pendingDeletion = $0 })
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
                ViewerPanel(index: index, state: state, document: document, sequence: currentSequence)
                    .frame(minWidth: 480, idealWidth: 800)
                InspectorPanel(index: index, state: state, document: document, sequence: currentSequence, onRender: beginRender)
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            }
            .frame(minHeight: 320)
            TimelinePanel(state: state, document: document, sequence: currentSequence, onCreateSequence: { create(.sequence, nil) })
                .frame(minHeight: 180, idealHeight: 260)
        }
        .toolbar { toolbar }
        .publishesAgentTarget(agentTarget)
        .onChange(of: currentSequence?.id, initial: true) { _, _ in
            state.currentSequenceID = currentSequence?.id
            reloadPlayer()
        }
        .onChange(of: currentSequence?.timelineData) { _, _ in reloadPlayer() }
        .onChange(of: state.player.currentTime) { _, time in
            if state.player.isPlaying { state.playhead = time }
        }
        .sheet(isPresented: $state.showImportSheet) {
            MediaImportSheet(urls: state.pendingImportURLs, groupID: nil) {
                state.pendingImportURLs = []
            }
        }
        .sheet(isPresented: $state.showRenderSheet) {
            if let sequence = currentSequence {
                SequenceRenderSheet(sequence: sequence) { preset in
                    state.showRenderSheet = false
                    startRender(sequence: sequence, preset: preset)
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
                    Button { create(kind, nil) } label: { Label(kind.displayName, systemImage: kind.systemImage) }
                }
                Divider()
                Button { beginCreatingGroup() } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
            } label: {
                Label("New", systemImage: "plus")
            }
            Button {
                chooseFilesToImport()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("i", modifiers: .command)
            .help("Import video, audio or images from disk")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                beginRender()
            } label: {
                if state.renderProgress != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Render", systemImage: "film.stack")
                }
            }
            .disabled(currentSequence == nil || currentSequence?.timeline.isEmpty == true || state.renderProgress != nil)
            .help("Render the current sequence as a new version")
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
            state.select(item)
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

    private func delete(_ row: LibraryRow) {
        if state.selection == row.id { state.select(nil) }
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

    private func reloadPlayer() {
        guard let sequence = currentSequence else {
            state.player.unload()
            return
        }
        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        state.player.load(sequence.timeline, resolver: resolver)
    }

    private func beginRender() {
        guard currentSequence != nil else { return }
        state.showRenderSheet = true
    }

    private func startRender(sequence: SequenceProject, preset: TimelineExporter.Preset) {
        state.renderError = nil
        state.renderProgress = .exporting(0)
        state.renderTask = Task { @MainActor in
            defer {
                state.renderProgress = nil
                state.renderTask = nil
            }
            do {
                _ = try await SequenceRenderService.render(sequence: sequence, document: document, preset: preset) { p in
                    state.renderProgress = p
                }
                state.inspectorTab = .sequence
                reloadPlayer()
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
