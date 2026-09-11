import AVFoundation
import AppKit
import CoreImage
import SwiftUI
import VideoEditorCore

public struct TimelineLayeredPreviewView: View {
    let controller: TimelinePreviewController
    let liveSurface: (LivePreviewPlayback) -> AnyView

    public init(controller: TimelinePreviewController, liveSurface: @escaping (LivePreviewPlayback) -> AnyView) {
        self.controller = controller; self.liveSurface = liveSurface
    }

    public var body: some View {
        GeometryReader { geometry in
            let canvas = controller.timeline.size
            let scale = min(geometry.size.width / max(1, canvas.width), geometry.size.height / max(1, canvas.height))
            ZStack {
                Color.black
                ZStack(alignment: .topLeading) {
                    Color(cgColor: PreviewGeometry.color(controller.timeline.backgroundHex))
                    ForEach(controller.layers) { layer in
                        if layer.mounted {
                            PreviewPictureLayer(layer: layer, controller: controller, liveSurface: liveSurface)
                                .opacity(layer.active ? 1 : 0)
                        }
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                .scaleEffect(scale)
                .frame(width: canvas.width * scale, height: canvas.height * scale)
                .allowsHitTesting(false)
                status
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { controller.setVisible(true) }
        .onDisappear { controller.setVisible(false) }
    }

    @ViewBuilder private var status: some View {
        let failure = controller.lastError ?? controller.layers.first(where: { $0.active && ($0.error != nil || $0.live?.error != nil) }).flatMap { $0.error ?? $0.live?.error }
        if let failure {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(failure).font(.callout).multilineTextAlignment(.center).lineLimit(8)
            }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
        } else if controller.isLoading || controller.transport.isBuffering {
            VStack(spacing: 8) {
                ProgressView()
                Text(controller.layers.first(where: { $0.active && $0.preparing != nil })?.preparing ?? "Preparing preview…")
                    .font(.callout)
            }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct PreviewPictureLayer: View {
    let layer: TimelinePreviewLayer
    let controller: TimelinePreviewController
    let liveSurface: (LivePreviewPlayback) -> AnyView

    var body: some View {
        let canvas = controller.timeline.size
        let placed = PreviewGeometry.placement(source: layer.naturalSize, canvas: canvas, transform: layer.clip.transform)
        Group {
            if let live = layer.live {
                liveSurface(live)
                    .id(live.id)
                    .frame(width: max(1, placed.width), height: max(1, placed.height))
                    .position(x: placed.midX, y: canvas.height - placed.midY)
                    .opacity(layer.trackKind == .audio || !live.ready ? 0 : Double(layer.clip.opacity))
            } else if case .media(.captions(let cues)) = layer.source {
                CaptionPreviewLayer(cues: cues, clip: layer.clip, controller: controller)
            } else if case .media(.file(let url, _, _)) = layer.source, layer.trackKind != .audio {
                Group {
                    if let player = layer.player {
                        PreviewVideoSurface(player: player)
                    } else if layer.clip.source.kind == .image, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable()
                            .onAppear {
                                if layer.naturalSize == .zero { layer.naturalSize = image.size }
                            }
                    }
                }
                .frame(width: max(1, placed.width), height: max(1, placed.height))
                .position(x: placed.midX, y: canvas.height - placed.midY)
                .opacity(Double(layer.clip.opacity))
            }
        }.frame(width: canvas.width, height: canvas.height)
    }
}

private struct CaptionPreviewLayer: View {
    let cues: [TextCue]
    let clip: Clip
    let controller: TimelinePreviewController
    private static let context = CIContext()

    var body: some View {
        let sourceTime = clip.sourceTime(at: controller.transport.currentTime)
        let text = cues.filter { $0.start <= sourceTime && sourceTime < $0.end }.map(\.text).joined(separator: "\n")
        let size = controller.timeline.size
        if !text.isEmpty, let raster = TextRenderer.shared.image(for: text, style: clip.text ?? .caption, frameSize: size),
           let image = Self.context.createCGImage(raster, from: CGRect(origin: .zero, size: size)) {
            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
        }
    }
}

/// The enclosing layer applies the same placement as the export compositor.
private struct PreviewVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.videoGravity = .resize
        view.playerLayer.backgroundColor = NSColor.clear.cgColor
        view.playerLayer.isOpaque = false
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: PlayerHostView, context: Context) { view.playerLayer.player = player }
}
