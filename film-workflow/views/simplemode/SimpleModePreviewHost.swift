import FilmTemplateUI
import SwiftData
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// The first cut, playing inside the wizard.
///
/// Its own player rather than the editor's: the editor window may not be open
/// yet, and its state is window-local. Watching the same document means the
/// preview reloads as the agent edits, and follows the playhead to whatever it
/// just changed.
struct SimpleModePreviewHost: View {
    let session: SimpleModeSession
    let document: ProjectDocument
    let onOpenEditor: () -> Void
    let onCancel: () -> Void
    @State var playback = SimpleModePlayback()

    var body: some View {
        SimpleModePreviewContent(
            session: session,
            document: document,
            playback: playback,
            onOpenEditor: onOpenEditor,
            onCancel: onCancel
        )
        .modelContainer(document.container)
    }
}

/// Split out so `@Query` runs against the film's container, which the parent
/// installs.
private struct SimpleModePreviewContent: View {
    let session: SimpleModeSession
    let document: ProjectDocument
    let playback: SimpleModePlayback
    let onOpenEditor: () -> Void
    let onCancel: () -> Void

    @Query(sort: \SequenceProject.updatedAt, order: .reverse) private var sequences: [SequenceProject]
    @Query private var remotions: [RemotionProject]
    private var player: TimelinePlayerController { playback.player }
    @State private var focusedClipID: UUID?
    @State private var appliedFocus: UUID?

    /// The sequence the agent is working on: whichever it last touched, else
    /// the newest one with anything in it.
    private var sequence: SequenceProject? {
        if let id = document.pendingTimelineFocus?.sequenceID,
           let match = sequences.first(where: { $0.id == id }) {
            return match
        }
        return sequences.first { !$0.timeline.allClips.isEmpty } ?? sequences.first
    }

    private var hasRemotion: Bool {
        sequence?.timeline.allClips.contains { $0.source.kind == .remotion } ?? false
    }

    var body: some View {
        PreviewPageView(
            title: document.displayName,
            status: statusText,
            isBusy: session.isAgentRunning,
            summary: session.lastSummary,
            onRefine: { SimpleModeCoordinator.shared.refine($0, for: session) },
            onOpenEditor: onOpenEditor,
            onCancel: onCancel
        ) {
            if sequence != nil {
                SequenceViewerView(controller: player, fps: sequence?.fps ?? 30, stage: stage, showsScrubber: true)
                    .overlay {
                        if let error = playback.error {
                            VStack(spacing: 12) {
                                Text(error).font(.callout).multilineTextAlignment(.center)
                                Button("Retry Preview", action: reload).buttonStyle(.glass)
                            }
                            .padding(20)
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                            .padding()
                        } else if let preparation = playback.preparation {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text(preparation).font(.callout)
                            }
                            .padding(20)
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        }
                    }
            } else {
                emptyStage
            }
        } clipStrip: {
            if let sequence {
                SimpleModeClipStrip(
                    timeline: sequence.timeline,
                    focusedClipID: focusedClipID,
                    currentTime: player.currentTime
                ) { time in
                    player.pause()
                    player.seek(to: time)
                }
            }
        }
        .onChange(of: sequence?.timelineData, initial: true) { _, _ in reload() }
        .onChange(of: sequence?.id) { _, _ in reload() }
        .onChange(of: remotions.map { "\($0.id):\($0.durationSeconds):\($0.compositionFps):\($0.compositionWidth):\($0.compositionHeight):\($0.compositionSource)" }) { _, _ in
            if hasRemotion { reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { notification in
            guard hasRemotion, let directory = notification.userInfo?["directory"] as? URL,
                  directory.path.hasPrefix(document.packageURL.path + "/") else { return }
            reload()
        }
        .task(id: document.pendingTimelineFocus) { await follow() }
        .onDisappear { playback.unload() }
    }

    private var statusText: String? {
        if let error = session.error { return error }
        return session.statusText
    }

    private var stage: AnyView? {
        guard playback.usesLivePreview else { return nil }
        return AnyView(TimelineLayeredPreviewView(controller: playback.preview) {
            AnyView(RemotionPlayerWebView(playback: $0))
        }.overlay(alignment: .topTrailing) {
            if playback.preview.lastError != nil || playback.preview.layers.contains(where: { $0.error != nil || $0.live?.error != nil }) {
                Button("Retry Preview", action: reload).buttonStyle(.glass).padding()
            }
        })
    }

    private var emptyStage: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing on the timeline yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        playback.load(sequence, document: document)
    }

    /// Moves the playhead to whatever the agent just changed, so a build looks
    /// like progress rather than a still frame.
    private func follow() async {
        guard let focus = document.pendingTimelineFocus, appliedFocus != focus.token else { return }
        // The user watching their cut outranks following the agent, the same
        // way it does in the editor.
        guard !player.isPlaying else {
            appliedFocus = focus.token
            return
        }
        guard await TimelineFocusFollower.waitUntilLoaded(player) else { return }
        guard document.pendingTimelineFocus == focus else { return }
        appliedFocus = focus.token
        focusedClipID = focus.clipID
        player.pause()
        player.seek(to: focus.time)
    }
}

/// A compact timeline: click a clip to seek, with the agent's latest edit lit.
struct SimpleModeClipStrip: View {
    let timeline: Timeline
    let focusedClipID: UUID?
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private var clips: [Clip] {
        timeline.tracks
            .filter { $0.kind == .video }
            .flatMap(\.clips)
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        if !clips.isEmpty, timeline.duration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(clips) { clip in
                            block(clip, width: width(for: clip, in: geometry.size.width))
                        }
                    }
                    playhead(in: geometry.size.width)
                }
            }
            .frame(height: 42)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .accessibilityIdentifier("wizard.preview.strip")
        }
    }

    private func width(for clip: Clip, in total: CGFloat) -> CGFloat {
        let share = clip.duration / max(timeline.duration, 0.001)
        // A very short clip still needs to be clickable.
        return max(14, total * share - 2)
    }

    private func block(_ clip: Clip, width: CGFloat) -> some View {
        let isFocused = clip.id == focusedClipID
        return Button {
            onSeek(clip.start)
        } label: {
            Text(clip.source.displayName)
                .font(.system(size: 10, weight: isFocused ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .frame(width: width, height: 26, alignment: .leading)
                .background(
                    isFocused ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(isFocused ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(clip.source.displayName)
    }

    private func playhead(in total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 1.5, height: 32)
            .offset(x: total * (currentTime / max(timeline.duration, 0.001)))
            .allowsHitTesting(false)
    }
}
