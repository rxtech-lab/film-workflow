import AppKit
import CoreImage
import CoreGraphics
import Foundation
import VideoEditorCore

/// The picture one component of a take shows on the timeline.
///
/// A clip asks with its own component's id, so each lane draws what it actually
/// contributes — the cursor draws the pointer, the shortcut lane draws its key
/// caps — rather than the whole composited recording. The id matters as much as
/// the drawing: `LibPreviewSource` memoises on it, so components sharing the
/// take's id would share one cached image however they were rendered.
@MainActor extension RecordingComponent {
    func makeLibPreviewSource(take: RecordingTake, storage: ProjectStorage) -> LibPreviewSource {
        let id = "screenRecording:\(id)"
        switch role {
        case .shortcuts:
            let cues = cues, style = take.project?.shortcutStyle ?? .caption
            let revision = "\(cues.hashValue):\(take.project?.shortcutStyleData.hashValue ?? 0)"
            return LibPreviewSource(id: id, revision: revision, duration: duration, isTemporal: true, canScrub: true) { time, size in
                let text = cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
                return RecordingComponentRaster.draw(size: size) { context in
                    guard !text.isEmpty, let raster = TextRenderer.shared.image(for: text, style: style, frameSize: size),
                          let image = RecordingComponentRaster.context.createCGImage(raster, from: CGRect(origin: .zero, size: size)) else { return }
                    context.draw(image, in: CGRect(origin: .zero, size: size))
                }
            }
        case .cursor:
            guard var presentation else { break }
            let offset = presentation.timeOffset
            // On a strip tile `cursorSize` resolves to a handful of pixels, so
            // draw into a canvas big enough to see and let the strip scale it.
            presentation.cursorSize = max(presentation.cursorSize, 0.12)
            let settings = presentation
            let revision = "\(presentation.pointer.count):\(presentation.hashValue)"
            return LibPreviewSource(id: id, revision: revision, duration: duration, isTemporal: true, canScrub: true) { time, size in
                let ratio = size.height > 0 ? size.width / size.height : 16.0 / 9
                let canvas = CGSize(width: 320, height: max(1, 320 / max(0.1, ratio)))
                // `time` arrives on the clip's source clock; the pointer samples
                // are on the take's, which is what `timeOffset` bridges.
                guard let raster = RecordingRenderer.cursor(settings, time: time + offset, size: canvas),
                      let image = RecordingComponentRaster.context.createCGImage(raster, from: CGRect(origin: .zero, size: canvas)) else { return nil }
                return RecordingComponentRaster.draw(size: canvas) { context in
                    context.draw(image, in: CGRect(origin: .zero, size: canvas))
                }
            }
        default: break
        }
        let url = storage.absoluteURL(for: filePath)
        return .file(id: id, kind: sourceKind == .audio ? .audio : .video, mediaURL: url, thumbnailURL: nil, duration: duration)
    }
}

@MainActor private enum RecordingComponentRaster {
    static let context = CIContext()
    /// An opaque tile with `body` drawn onto it — the glyphs and text these
    /// lanes render carry alpha, which would otherwise read as a hole.
    static func draw(size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        body(context)
        return context.makeImage()
    }
}
