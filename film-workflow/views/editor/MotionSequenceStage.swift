import MotionCore
import AVFoundation
import MotionSwiftUI
import SkiaKit
import SwiftUI
import VideoEditorCore

/// The sequence (and footage) viewer's picture, drawn by MotionSwift from the generated film. The timeline's
/// `TimelinePlayerController` stays the clock and plays file audio through AVFoundation; this
/// view follows its time and play state, and MotionSwift adds only sound from nested Remotion
/// compositions. Edits recompile the film after a short pause and hot-reload it in place.
struct MotionSequenceStage: View {
    let timeline: Timeline
    let document: ProjectDocument
    @Bindable var controller: TimelinePlayerController
    /// Resolves the film's media; the document's resolver when nil.
    var resolver: (any MediaResolver)? = nil
    @State private var player: MotionPlayer
    @State private var processor: MotionSequenceProcessor?
    @State private var error: String?
    @State private var compiling = false
    @State private var reloadToken = 0

    init(timeline: Timeline, document: ProjectDocument, controller: TimelinePlayerController, resolver: (any MediaResolver)? = nil) {
        self.timeline = timeline
        self.document = document
        self.controller = controller
        self.resolver = resolver
        let longest = Double(max(timeline.width, timeline.height, 1))
        _player = State(initialValue: MotionPlayer(configuration: .init(scale: min(1, controller.previewMaxWidth / longest), backend: .gpu)))
    }

    private struct LoadKey: Hashable {
        let timeline: Timeline
        let token: Int
    }

    var body: some View {
        ZStack {
            if let frame = player.displayedFrame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if compiling {
                ProgressView().controlSize(.small).padding(10)
                    .accessibilityLabel("Updating preview")
            }
        }
        .overlay(alignment: .bottomLeading) {
            let notes = MotionSequenceComposer.approximations(timeline)
            if !notes.isEmpty, error == nil {
                Label(notes.joined(separator: " "), systemImage: "info.circle")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .accessibilityIdentifier("sequence.motionStage.approximations")
            }
        }
        .overlay {
            if let error {
                VStack(spacing: 8) {
                    Label("Couldn’t Preview Sequence", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).font(.callout).multilineTextAlignment(.center).lineLimit(6)
                    Button("Retry Preview") { reloadToken += 1 }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        // A leaf element: a container holding only a decorative image is pruned from the tree.
        .accessibilityElement(children: .ignore)
        // macOS UI automation reads a group's label, not its value.
        .accessibilityLabel(player.displayedFrame.map { "Rendered frame \($0.frame)" } ?? (error ?? "Loading preview"))
        .accessibilityIdentifier("sequence.motionStage")
        .task(id: LoadKey(timeline: timeline, token: reloadToken)) { await load() }
        .onChange(of: controller.currentTime) { follow() }
        .onChange(of: controller.isPlaying) { follow(force: true) }
        .onChange(of: player.renderError) { _, message in if let message { error = message } }
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { _ in
            // A nested composition changed on disk; its sources are read when the film is composed.
            if timeline.renderedClips.contains(where: { $0.source.kind == .remotion }) { reloadToken += 1 }
        }
        .onDisappear {
            player.pause()
            processor?.unregister()
            processor = nil
        }
    }

    private func load() async {
        // Coalesce bursts of edits (dragging a clip, typing a value) into one compile.
        if player.composition != nil { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        compiling = true
        defer { compiling = false }
        do {
            let resolver = resolver ?? DocumentMediaResolver(document: document, width: timeline.width, height: timeline.height, fps: timeline.fps)
            let compiled = try await MotionSequenceEngine.compile(timeline, document: document, resolver: resolver, options: .preview)
            try Task.checkCancellation()
            let previous = processor
            compiled.film.processor.register()
            processor = compiled.film.processor
            let source = MotionSource.bundle(compiled.bundle)
            if player.composition != nil {
                await player.reload(source)
            } else {
                await player.load(source, compositionID: MotionSequenceComposition.compositionID)
            }
            previous?.unregister()
            if case .failed(let message) = player.status { throw MotionSwiftEngine.Failure(message) }
            player.loops = false
            error = nil
            follow(force: true)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func follow(force: Bool = false) {
        guard let composition = player.composition else { return }
        let fps = composition.fps
        let frame = min(max(0, Int((controller.currentTime * fps).rounded(.down))), composition.durationInFrames - 1)
        player.isMuted = controller.player.isMuted
        if controller.isPlaying && !controller.isBuffering {
            if !player.isPlaying || force {
                player.seek(to: frame)
                player.play()
            } else if abs(player.currentFrame - frame) > 3 {
                player.seek(to: frame)
            }
        } else {
            if player.isPlaying { player.pause() }
            if player.currentFrame != frame || force { player.seek(to: frame) }
        }
    }
}
