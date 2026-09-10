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
        Group {
            switch state.selection?.kind {
            case .music?:
                if let p = state.selection.flatMap({ index.music($0.id) }) {
                    MusicProjectEditorView(project: p)
                } else { missing }
            case .narration?:
                if let p = state.selection.flatMap({ index.narration($0.id) }) {
                    TranscriptEditorView(project: p)
                } else { missing }
            case .caption?:
                if let p = state.selection.flatMap({ index.caption($0.id) }) {
                    CaptionProjectViewer(project: p)
                        .id(p.projectUUID)
                } else { missing }
            case .image?:
                if let p = state.selection.flatMap({ index.image($0.id) }) {
                    ImageProjectViewer(project: p)
                } else { missing }
            case .video?:
                if let p = state.selection.flatMap({ index.video($0.id) }) {
                    VideoProjectViewer(project: p)
                } else { missing }
            case .remotion?:
                if let p = state.selection.flatMap({ index.remotion($0.id) }) {
                    RemotionViewer(project: p)
                        .id(p.id)
                } else { missing }
            case .imported?:
                if let a = state.selection.flatMap({ index.imported($0.id) }) {
                    ImportedAssetViewer(asset: a)
                        .id(a.id)
                } else { missing }
            case .sequence?, nil:
                if let sequence {
                    SequenceViewerView(controller: state.player, fps: sequence.fps)
                } else {
                    ContentUnavailableView("Nothing Selected", systemImage: "rectangle.on.rectangle",
                                           description: Text("Select footage in the library, or create a sequence."))
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

/// Image project: the newest image large, the rest as a strip.
struct ImageProjectViewer: View {
    let project: ImageGenProject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.projectStorage) private var storage

    var body: some View {
        GeneratedImageListView(files: project.generatedFiles) { file in
            storage.deleteFile(at: file.imageFilePath)
            modelContext.delete(file)
            project.updatedAt = Date()
        }
    }
}

struct VideoProjectViewer: View {
    let project: VideoGenProject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.projectStorage) private var storage

    var body: some View {
        GeneratedVideoListView(files: project.generatedFiles) { file in
            storage.deleteFile(at: file.videoFilePath)
            if let t = file.thumbnailFilePath { storage.deleteFile(at: t) }
            modelContext.delete(file)
            project.updatedAt = Date()
        }
    }
}

struct ImportedAssetViewer: View {
    let asset: ImportedAsset
    @State private var player = AVPlayer()

    var body: some View {
        Group {
            if let url = asset.resolveURL() {
                switch asset.kindEnum {
                case .image:
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding()
                    } else {
                        ContentUnavailableView("Image Unavailable", systemImage: "photo")
                    }
                case .video, .audio:
                    VideoPlayer(player: player)
                        .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
                        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
                }
            } else {
                ContentUnavailableView("File Missing", systemImage: "questionmark.folder",
                                       description: Text(asset.originalPath))
            }
        }
        .background(Color.black.opacity(asset.kindEnum == .image ? 0 : 1))
    }
}

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
struct RemotionViewer: View {
    let project: RemotionProject
    @State private var runtime = RemotionRuntime.shared
    @State private var reloadToken = 0
    @State private var statusMessage: String?

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
            } else if let err = runtime.lastError ?? statusMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(err).multilineTextAlignment(.center).padding(.horizontal)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text(project.compositionSource.isEmpty
                         ? "Create a composition from the inspector to start the preview."
                         : "Loading the Studio preview…")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
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
