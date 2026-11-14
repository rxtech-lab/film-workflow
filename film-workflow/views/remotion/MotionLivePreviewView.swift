import MotionCore
import MotionSwiftUI
import SkiaKit
import SwiftUI
import VideoEditorCore

/// Plays a Remotion composition natively with MotionSwift inside the layered
/// timeline/footage preview. The editor owns the clock: this view follows each
/// `LivePreviewCommand` (frame, play state, rate, volume) and reports readiness and
/// failures back through the playback bridge.
struct MotionLivePreviewView: View {
    let playback: LivePreviewPlayback
    @State private var player: MotionPlayer

    init(playback: LivePreviewPlayback) {
        self.playback = playback
        let longest = Double(max(playback.descriptor.width, playback.descriptor.height, 1))
        _player = State(initialValue: MotionPlayer(configuration: .init(scale: min(1, 1920 / longest), backend: .gpu)))
    }

    private var directory: URL { playback.descriptor.url.standardizedFileURL }

    var body: some View {
        // The frame alone, without MotionView's black letterbox: transparent
        // compositions overlay the tracks below them in the layered stage.
        ZStack {
            if let frame = player.displayedFrame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composition preview")
        .accessibilityValue(player.displayedFrame.map { "Rendered frame \($0.frame)" }
                            ?? player.renderError.map { "Render failed: \($0)" } ?? "Loading")
            .task(id: directory) { await load(reloading: false) }
        .onChange(of: player.renderError) { _, error in
            if let error { playback.received(type: "error", message: error) }
        }
            .onChange(of: playback.command) { _, command in apply(command) }
            .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { note in
                guard (note.userInfo?["directory"] as? URL)?.standardizedFileURL == directory else { return }
                Task { await load(reloading: true) }
            }
            .onAppear { RemotionProjectWatcher.start(directory) }
            .onDisappear {
                player.pause()
                RemotionProjectWatcher.stop(directory)
            }
            .accessibilityIdentifier("remotion.livePreview")
    }

    private func load(reloading: Bool) async {
        if !reloading { playback.received(type: "building") }
        do {
            let prepared = try await MotionSwiftEngine.prepare(projectDir: directory)
            try Task.checkCancellation()
            let source = MotionSource.bundle(prepared.bundle, publicDirectory: prepared.publicDirectory)
            if reloading, player.composition != nil {
                await player.reload(source)
            } else {
                await player.load(source, compositionID: MotionSwiftEngine.compositionID)
            }
            if case .failed(let message) = player.status { throw MotionSwiftEngine.Failure(message) }
            guard let composition = player.composition else { throw MotionSwiftEngine.Failure("The project has no composition.") }
            player.loops = false
            playback.descriptor.fps = max(1, Int(composition.fps.rounded()))
            playback.descriptor.frames = composition.durationInFrames
            playback.received(type: "ready")
            apply(playback.command, force: true)
        } catch is CancellationError {
        } catch {
            playback.received(type: "error", message: error.localizedDescription)
        }
    }

    private func apply(_ command: LivePreviewCommand, force: Bool = false) {
        guard let composition = player.composition else { return }
        let frame = min(max(0, command.frame), composition.durationInFrames - 1)
        player.isMuted = command.muted || command.volume <= 0
        // Native playback runs its own clock at 1×; other rates follow the editor's
        // commands frame by frame.
        if command.playing && command.rate == 1 {
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
