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

    var onRetryModifierPreview: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if shownItem?.kind == .sequence || shownItem == nil {
                HStack {
                    if let sequence {
                        Text("\(sequence.width)×\(sequence.height) · \(sequence.fps)p")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Label(sequence.name, systemImage: "film").lineLimit(1)
                    } else {
                        Label("Viewer", systemImage: "play.rectangle")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.bar)
            }
            viewerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// The item on screen: the footage being skimmed in the browser while
    /// the pointer is over it, otherwise the selection.
    private var shownItem: LibraryItemID? { state.footageSkim?.item ?? state.viewerSelection }

    private var viewerContent: some View {
        Group {
            switch shownItem?.kind {
            case .image?, .video?, .music?, .narration?, .imported?, .caption?, .remotion?:
                if let item = shownItem {
                    let cells = index.footage(for: item)
                    let wanted = state.footageSkim?.cellID ?? state.currentVersion(for: item)
                    if let cell = cells.first(where: { $0.id == wanted }) ?? cells.first {
                        FootageViewer(
                            cell: cell,
                            name: index.name(of: item) ?? cell.title,
                            versions: cells,
                            onSelectVersion: { state.setCurrentVersion($0, for: item) },
                            skimFraction: state.footageSkim?.fraction,
                            player: state.footagePlayer, document: document
                        )
                    } else {
                        StudioEmptyState(title: "Nothing to preview yet", symbol: item.kind.systemImage,
                                         message: "Generate footage from the inspector, then play it here.")
                    }
                } else { missing }
            case .sequence?, nil:
                if let sequence {
                    SequenceViewerView(controller: state.player, fps: sequence.fps, stage: !sequence.timeline.hasActiveModifiers && sequence.timeline.allClips.contains(where: { $0.source.kind == .remotion }) ? AnyView(
                        TimelineLayeredPreviewView(controller: state.preview) { AnyView(RemotionPlayerWebView(playback: $0)) }
                            .overlay(alignment: .topTrailing) {
                                if state.preview.lastError != nil || state.preview.layers.contains(where: { $0.error != nil || $0.live?.error != nil }) {
                                    Button("Retry Preview") {
                                        state.preview.load(sequence.timeline, resolver: DocumentPreviewMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps))
                                    }.padding()
                                }
                            }
                    ) : nil)
                    .overlay {
                        if let error = state.modifierPreviewError {
                            VStack(spacing: 8) {
                                Text(error).font(.callout).multilineTextAlignment(.center)
                                Button("Retry Preview", action: onRetryModifierPreview)
                            }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                        } else if let progress = state.modifierPreviewProgress {
                            VStack(spacing: 8) { ProgressView(); Text(progress).font(.callout) }
                                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
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
