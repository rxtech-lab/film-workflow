import AVFoundation
import AppKit
import SwiftUI
import VideoEditorCore

/// The sequence preview: an `AVPlayerLayer` with transport controls.
public struct SequenceViewerView: View {
    @Bindable var controller: TimelinePlayerController
    let fps: Int

    public init(controller: TimelinePlayerController, fps: Int) {
        self.controller = controller
        self.fps = fps
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerLayerView(player: controller.player)
                if let error = controller.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            transport
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { controller.pause(); controller.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start")
            Button { controller.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Previous frame")
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(controller.isPlaying ? "Pause" : "Play")
            Button { controller.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Next frame")
            Button { controller.pause(); controller.seek(to: controller.duration) } label: { Image(systemName: "forward.end.fill") }
                .help("Go to end")

            Text(Timecode.string(seconds: controller.currentTime, fps: fps))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 104, alignment: .leading)

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.pause(); controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 0.001)
            )
            .controlSize(.small)

            Text(Timecode.string(seconds: controller.duration, fps: fps))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Hosts an `AVPlayerLayer`; `VideoPlayer` adds its own controls, which the
/// timeline transport replaces.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
    }

    required init?(coder: NSCoder) { nil }
}
