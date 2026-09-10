import AVKit
import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Centre column: the editor for the selected footage, or the sequence player.
struct ViewerPanel: View {
    let index: LibraryIndex
    @Bindable var state: EditorWindowState
    let document: ProjectDocument
    let sequence: SequenceProject?

    var body: some View {
        VStack(spacing: 0) {
            StudioPanelHeader(title: "Viewer", symbol: "play.rectangle")
            viewerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var viewerContent: some View {
        Group {
            switch state.viewerSelection?.kind {
            case .image?, .video?, .music?, .narration?, .imported?:
                if let item = state.viewerSelection {
                    let cells = index.footage(for: item)
                    if let cell = cells.first(where: { $0.id == state.currentVersion(for: item) }) ?? cells.first {
                        FootageViewer(
                            cell: cell,
                            name: index.name(of: item) ?? cell.title,
                            versions: cells,
                            onSelectVersion: { state.setCurrentVersion($0, for: item) }
                        )
                    } else {
                        StudioEmptyState(title: "Nothing to preview yet", symbol: item.kind.systemImage,
                                         message: "Generate footage from the inspector, then play it here.")
                    }
                } else { missing }
            case .remotion?:
                if let p = state.viewerSelection.flatMap({ index.remotion($0.id) }) {
                    RemotionViewer(project: p, document: document)
                        .id(p.id)
                } else { missing }
            case .sequence?, .caption?, nil:
                if let sequence {
                    SequenceViewerView(controller: state.player, fps: sequence.fps, stage: sequence.timeline.allClips.contains(where: { $0.source.kind == .remotion }) ? AnyView(
                        TimelineLayeredPreviewView(controller: state.preview) { AnyView(RemotionPlayerWebView(playback: $0)) }
                            .overlay(alignment: .topTrailing) {
                                if state.preview.lastError != nil || state.preview.layers.contains(where: { $0.error != nil || $0.live?.error != nil }) {
                                    Button("Retry Preview") {
                                        state.preview.load(sequence.timeline, resolver: DocumentPreviewMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps))
                                    }.padding()
                                }
                            }
                    ) : nil)
                } else {
                    StudioEmptyState(title: "Ready for your story", symbol: "play.rectangle",
                                     message: "Select footage to preview, or create a sequence to start editing.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missing: some View {
        ContentUnavailableView("Not Found", systemImage: "questionmark.folder")
    }
}

// MARK: - Per-kind viewers

/// Caption project: the segment list, loaded after validation like the old
/// tab did, so a large transcript never blocks the selection change.
struct CaptionProjectViewer: View {
    let project: CaptionProject
    @State private var issues: [UUID: [CaptionValidationIssue]]?
    @State private var validatedAt: Date?

    var body: some View {
        Group {
            if let issues {
                CaptionSegmentListView(project: project, initialValidationIssues: issues, validatedProjectUpdate: validatedAt)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Loading Captions…").font(.headline)
                    Text(project.name).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: project.projectUUID) {
            await Task.yield()
            project.ensureVersioned()
            let snapshot = project.snapshot()
            let found = await Task.detached(priority: .userInitiated) {
                CaptionTranscriptValidator.rowIssuesBySegmentID(in: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            validatedAt = project.updatedAt
            issues = found
        }
    }
}

/// Remotion Studio preview for the selected project. Boots Studio when the
/// project has a composition and stops it when the viewer goes away.
struct RemotionStudioViewer: View {
    let project: RemotionProject
    @State private var runtime = RemotionRuntime()
    @State private var reloadToken = 0
    @State private var statusMessage: String?
    @State private var presentedError: String?

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            if runtime.isStarting {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Starting Remotion Studio…").font(.callout).foregroundStyle(.secondary)
                }
            } else if runtime.currentURL != nil, runtime.currentProjectId == project.id {
                RemotionPreviewWebView(url: runtime.currentURL, reloadToken: reloadToken)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text((runtime.lastError ?? statusMessage) != nil
                         ? "Preview unavailable."
                         : project.compositionSource.isEmpty
                         ? "Create a composition from the inspector to start the preview."
                         : "Loading the Studio preview…")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }

        .onChange(of: runtime.lastError ?? statusMessage, initial: true) { _, error in
            presentedError = error
        }
        .alert("Couldn’t Start Preview", isPresented: Binding(
            get: { presentedError != nil },
            set: { if !$0 { presentedError = nil } }
        )) {
            Button("OK") { presentedError = nil }
        } message: {
            Text(presentedError ?? "")
        }
        .task(id: project.id) { await startStudio() }
        .onReceive(NotificationCenter.default.publisher(for: .agentDidMutateProject)) { note in
            guard let tool = note.userInfo?["tool"] as? String, tool.hasPrefix("remotion_") else { return }
            reloadToken += 1
            let patched = RemotionCodeBuilder.patchProjectConstants(in: project.compositionSource, project: project)
            if patched != project.compositionSource {
                project.compositionSource = patched
                try? RemotionCodeBuilder.writeComposition(project: project, source: patched)
            }
        }
        .onChange(of: project.compositionSource.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty { Task { await startStudio() } }
        }
        .onDisappear {
            Task { await runtime.stop() }
        }
    }

    private func startStudio() async {
        // The DB copy of the source can lag behind disk after agent edits.
        if project.compositionSource.isEmpty {
            let onDisk = project.projectDir.appendingPathComponent("src/Composition.tsx")
            if let recovered = try? String(contentsOf: onDisk, encoding: .utf8),
               !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.compositionSource = recovered
            }
        }
        guard !project.compositionSource.isEmpty else {
            await runtime.stop()
            return
        }
        let patched = RemotionCodeBuilder.patchProjectConstants(in: project.compositionSource, project: project)
        if patched != project.compositionSource { project.compositionSource = patched }
        try? RemotionCodeBuilder.writeComposition(project: project, source: patched)
        do {
            try await runtime.start(projectId: project.id, projectDir: project.projectDir)
            reloadToken += 1
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
