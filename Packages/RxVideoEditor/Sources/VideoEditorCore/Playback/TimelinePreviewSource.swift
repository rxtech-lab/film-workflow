import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Live preview data is deliberately separate from export's file resolver.
public struct LivePreviewDescriptor: Sendable, Hashable {
    public var url: URL
    public var fps: Int
    public var frames: Int
    public var width: Int
    public var height: Int
    public init(url: URL, fps: Int, frames: Int, width: Int, height: Int) {
        self.url = url; self.fps = fps; self.frames = frames; self.width = width; self.height = height
    }
    public var duration: Double { Double(frames) / Double(max(1, fps)) }
}

public enum TimelinePreviewSource: Sendable {
    case media(ResolvedMedia)
    case live(LivePreviewDescriptor)
}

@MainActor public protocol TimelinePreviewResolver: AnyObject {
    func preview(_ source: ClipSource) async throws -> TimelinePreviewSource
    func renderedPreview(_ source: ClipSource, progress: @escaping @MainActor (String) -> Void) async throws -> ResolvedMedia
    func release()
}

public struct LivePreviewCommand: Codable, Equatable, Sendable {
    public var serial: Int = 0
    public var frame: Int = 0
    public var playing: Bool = false
    public var rate: Double = 1
    public var volume: Float = 1
    public var muted: Bool = false
}

/// The app's web surface implements this small bridge; the editor owns the clock.
@MainActor @Observable
public final class LivePreviewPlayback {
    public let id = UUID()
    public var descriptor: LivePreviewDescriptor
    public private(set) var command = LivePreviewCommand()
    public var ready = false
    public var buffering = false
    public var error: String?
    public var limitation: String?
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private var lastSent: ContinuousClock.Instant?

    public init(descriptor: LivePreviewDescriptor) { self.descriptor = descriptor }

    public func update(time: Double, playing: Bool, rate: Double, volume: Float, muted: Bool, force: Bool = false) {
        let frame = max(0, min(descriptor.frames - 1, Int(floor(max(0, time) * Double(max(1, descriptor.fps))))))
        let changed = command.playing != playing || command.rate != rate || command.volume != volume || command.muted != muted
        if !force && !changed {
            if !playing && command.frame == frame { return }
            if playing, let lastSent, lastSent.duration(to: .now) < .milliseconds(100) { return }
        }
        command = LivePreviewCommand(serial: command.serial + 1, frame: frame, playing: playing, rate: rate, volume: volume, muted: muted)
        lastSent = .now
    }

    public func received(type: String, message: String? = nil, buffering: Bool = false) {
        switch type {
        case "ready": ready = true; self.buffering = false; error = nil
        case "building": ready = false; error = nil; limitation = nil
        case "buffering": self.buffering = buffering
        case "error": error = message ?? "Preview failed."; ready = false
        case "limitation": limitation = message ?? "Preparing a rendered preview…"; ready = false
        default: break
        }
        onChange?()
    }
}

/// Shared layout math uses compositor coordinates (positive Y points upward).
public enum PreviewGeometry {
    public static func color(_ hex: String) -> CGColor { CGColor.fromHex(hex) }
    public static func placement(source: CGSize, canvas: CGSize, transform: ClipTransform) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let x = canvas.width / source.width, y = canvas.height / source.height
        let scale = CGFloat(transform.scale)
        let size: CGSize
        switch transform.fit {
        case .fit: size = CGSize(width: source.width * min(x, y) * scale, height: source.height * min(x, y) * scale)
        case .fill: size = CGSize(width: source.width * max(x, y) * scale, height: source.height * max(x, y) * scale)
        case .stretch: size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        }
        return CGRect(x: (canvas.width - size.width) / 2 + transform.offsetX * canvas.width,
                      y: (canvas.height - size.height) / 2 + transform.offsetY * canvas.height,
                      width: size.width, height: size.height)
    }
}
