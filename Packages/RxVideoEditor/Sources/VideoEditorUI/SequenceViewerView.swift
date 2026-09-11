import AVFoundation
import AppKit
import SwiftUI
import VideoEditorCore

/// The sequence preview: an `AVPlayerLayer` with transport controls.
public struct SequenceViewerView: View {
    @Bindable var controller: TimelinePlayerController
    let fps: Int
    let stage: AnyView?
    @State private var presentedError: String?

    public init(controller: TimelinePlayerController, fps: Int, stage: AnyView? = nil) {
        self.controller = controller
        self.fps = fps
        self.stage = stage
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let stage { stage }
                else {
                    PlayerLayerView(player: controller.player)
                        .opacity(controller.currentTime < controller.duration ? 1 : 0)
                }
            }
            transport
        }
        .onChange(of: controller.lastError, initial: true) { _, error in
            presentedError = error
        }
        .alert("Couldn’t Preview Sequence", isPresented: Binding(
            get: { presentedError != nil },
            set: { if !$0 { presentedError = nil } }
        )) {
            Button("OK") { presentedError = nil }
        } message: {
            Text(presentedError ?? "")
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Go to Start") { controller.pause(); controller.seek(to: 0) }
                Button("Go to End") { controller.pause(); controller.seek(to: controller.duration) }
                Divider()
                Toggle("Mute", isOn: Binding(get: { controller.player.isMuted }, set: { controller.player.isMuted = $0 }))
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Viewer tools")
            Spacer(minLength: 0)
            Button { controller.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Previous frame")
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(controller.isPlaying ? "Pause" : "Play")
            Text(Timecode.string(seconds: controller.currentTime, fps: fps))
                .font(.system(size: 19, weight: .light, design: .monospaced))
                .fixedSize()

            Button { controller.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Next frame")
            Spacer(minLength: 0)
            AudioLevelMeterView(player: controller.player)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Toggle full screen")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 40)
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
