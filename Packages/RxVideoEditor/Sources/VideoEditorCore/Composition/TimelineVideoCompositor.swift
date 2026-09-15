import AVFoundation
import CoreImage
import Foundation
import VideoEffectsCore

/// Draws every frame of a sequence: composition-track video, still images,
/// caption text and placeholders, scaled into the render size. Used by both
/// the preview player and the exporter, so what you see is what you get.
public final class TimelineVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    nonisolated(unsafe) private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let queue = DispatchQueue(label: "rx.video-editor.compositor", qos: .userInitiated)
    private let stillCache = StillImageCache()
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        queue.sync { cancelled = true }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            cancelled = false
            guard let instruction = request.videoCompositionInstruction as? TimelineCompositionInstruction else {
                request.finish(with: CompositorError.unexpectedInstruction)
                return
            }
            guard let buffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.noPixelBuffer)
                return
            }
            let size = request.renderContext.size
            let image = compose(instruction: instruction, request: request, size: size)
            let pixels = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            // The canvas stays in sequence coordinates. Playback can request a
            // smaller buffer via renderScale; drawing the unscaled canvas into it
            // crops the picture. AVFoundation's transform also includes pixel aspect
            // ratio and edge padding and uses a top-left origin, unlike Core Image.
            let toPixels = CGAffineTransform(translationX: 0, y: size.height).scaledBy(x: 1, y: -1)
                .concatenating(request.renderContext.renderTransform)
                .concatenating(CGAffineTransform(translationX: 0, y: pixels.height).scaledBy(x: 1, y: -1))
            Self.ciContext.render(image.transformed(by: toPixels), to: buffer,
                                  bounds: CGRect(origin: .zero, size: pixels), colorSpace: Self.colorSpace)
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    // MARK: - Drawing

    private func compose(instruction: TimelineCompositionInstruction, request: AVAsynchronousVideoCompositionRequest, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        var output = CIImage(color: CIColor(cgColor: instruction.backgroundColor)).cropped(to: frame)
        let time = CMTimeGetSeconds(request.compositionTime)

        for layer in instruction.layers {
            if let image = image(for: layer, at: time, frame: frame, request: request) {
                output = image.composited(over: output)
            }
        }
        return output.cropped(to: frame)
    }

    private func image(for layer: LayerSpec, at time: Double, frame: CGRect, request: AVAsynchronousVideoCompositionRequest,
                       effects: [EffectInstance] = []) -> CIImage? {
        let catalog = ModifierCatalog.current
        switch layer {
        case .sourceTrack(let trackID, let transform, let opacity, let preferredTransform, _):
            guard let pixelBuffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            var source = CIImage(cvPixelBuffer: pixelBuffer)
            if !preferredTransform.isIdentity {
                source = source.transformed(by: preferredTransform)
                source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            }
            return Self.place(catalog.apply(effects, to: source), in: frame, transform: transform, opacity: opacity)
        case .still(let url, let transform, let opacity):
            guard let still = stillCache.image(for: url) else { return nil }
            return Self.place(catalog.apply(effects, to: still), in: frame, transform: transform, opacity: opacity)
        case .text(let cues, let style):
            let active = cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
            guard !active.isEmpty else { return nil }
            return TextRenderer.shared.image(for: active, style: style, frameSize: frame.size)
        case .placeholder(let name): return Self.placeholder(named: name, in: frame)
        case .recording(let base, let clip):
            return RecordingRenderer.render(image(for: base, at: time, frame: frame, request: request, effects: effects), clip: clip, time: time, size: frame.size)
        case .processed(let base, let instances):
            return image(for: base, at: time, frame: frame, request: request, effects: instances)
        case .heldEdges(let base, let range, let first, let last, let transform, let opacity):
            if let held = time < range.lowerBound ? first : (time >= range.upperBound ? last : nil) {
                return Self.place(catalog.apply(effects, to: CIImage(cgImage: held)), in: frame, transform: transform, opacity: opacity)
            }
            return image(for: base, at: time, frame: frame, request: request, effects: effects)
        case .transition(let from, let to, let instance, let range):
            let a = from.flatMap { image(for: $0, at: time, frame: frame, request: request) }
            let b = to.flatMap { image(for: $0, at: time, frame: frame, request: request) }
            guard let definition = catalog.transition(instance.definitionID) else { return b ?? a }
            let progress = (time - range.lowerBound) / max(0.000001, range.upperBound - range.lowerBound)
            if from == nil, let b { return definition.renderEdge(b, progress: progress, atStart: true, parameters: instance.parameters) }
            if to == nil, let a { return definition.renderEdge(a, progress: progress, atStart: false, parameters: instance.parameters) }
            let clear = CIImage(color: .clear).cropped(to: frame)
            return definition.render(from: a ?? clear, to: b ?? clear, progress: progress, parameters: instance.parameters)
        }
    }

    /// Scales and positions an image per the clip transform, then applies opacity.
    static func place(_ image: CIImage, in frame: CGRect, transform: ClipTransform, opacity: Float) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let placed = PreviewGeometry.placement(source: extent.size, canvas: frame.size, transform: transform)
        var result = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        result = result.transformed(by: CGAffineTransform(scaleX: placed.width / extent.width, y: placed.height / extent.height))
        result = result.transformed(by: CGAffineTransform(translationX: placed.minX, y: placed.minY))
        if opacity < 1 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))
            ])
        }
        return result.cropped(to: frame)
    }

    static func placeholder(named name: String, in frame: CGRect) -> CIImage {
        let slate = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.2)).cropped(to: frame)
        let style = TextStyle(fontSize: 0.045, colorHex: "#DDDDDD", backgroundOpacity: 0, verticalPosition: 0.5, bold: false)
        guard let label = TextRenderer.shared.image(for: "\(name)\nNot rendered yet", style: style, frameSize: frame.size) else {
            return slate
        }
        return label.composited(over: slate)
    }

    enum CompositorError: Error {
        case unexpectedInstruction
        case noPixelBuffer
    }
}

/// Decoded still images, keyed by URL. A still is drawn on every frame of its
/// clip; decoding it each time would dominate render time.
final class StillImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [URL: CIImage] = [:]

    func image(for url: URL) -> CIImage? {
        lock.lock()
        if let cached = images[url] { lock.unlock(); return cached }
        lock.unlock()
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        lock.lock()
        if images.count > 64 { images.removeAll() }
        images[url] = image
        lock.unlock()
        return image
    }
}
