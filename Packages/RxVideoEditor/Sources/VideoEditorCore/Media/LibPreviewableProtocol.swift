import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Opts footage into the library and timeline's shared frame-strip previews.
/// The returned value captures a revision of the source, without retaining a model.
@MainActor
public protocol LibPreviewableProtocol: TimelineDraggable {
    func makeLibPreviewSource() -> LibPreviewSource
}

/// A source-owned thumbnail provider, shared by library rows and timeline clips.
public struct LibPreviewSource: Sendable, Hashable {
    public let id: String
    public let revision: String
    public let duration: TimeInterval?
    public let isTemporal: Bool
    public let canScrub: Bool
    private let render: @MainActor @Sendable (TimeInterval, CGSize) async -> CGImage?

    public init(id: String, revision: String, duration: TimeInterval?, isTemporal: Bool, canScrub: Bool,
                thumbnail: @escaping @MainActor @Sendable (TimeInterval, CGSize) async -> CGImage?) {
        self.id = id; self.revision = revision; self.duration = duration
        self.isTemporal = isTemporal; self.canScrub = canScrub; self.render = thumbnail
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.duration == rhs.duration
            && lhs.isTemporal == rhs.isTemporal && lhs.canScrub == rhs.canScrub
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(revision); hasher.combine(duration)
        hasher.combine(isTemporal); hasher.combine(canScrub)
    }

    public func refreshed(_ revision: String) -> Self {
        Self(id: id, revision: self.revision + ":" + revision, duration: duration,
             isTemporal: isTemporal, canScrub: canScrub, thumbnail: render)
    }

    @MainActor
    public func thumbnail(at time: TimeInterval, maximumSize: CGSize) async -> CGImage? {
        guard time.isFinite else { return nil }
        let time = isTemporal ? min(max(0, time), max(0, (duration ?? time + 1) - 0.001)) : 0
        let key = "\(id)|\(revision)|\(Int((time * 1000).rounded()))|\(Int(maximumSize.width))x\(Int(maximumSize.height))" as NSString
        if let image = LibPreviewImageCache.images.object(forKey: key) { return image }
        guard !Task.isCancelled, let image = await render(time, maximumSize), !Task.isCancelled else { return nil }
        LibPreviewImageCache.images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

@MainActor
private enum LibPreviewImageCache {
    static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
}

public extension LibPreviewableProtocol {
    /// File-based footage gets a default provider. Captions and live compositions
    /// supply their own provider while using exactly the same frame-strip views.
    func makeLibPreviewSource() -> LibPreviewSource {
        .file(id: clipSource.id, kind: timelineKind, mediaURL: mediaURL,
              thumbnailURL: thumbnailURL, duration: knownDuration)
    }
}

public extension LibPreviewSource {
    /// A saved output can preview its own file without changing the source
    /// that its library item drags onto the timeline.
    static func file(id: String, kind: SourceKind, mediaURL url: URL?, thumbnailURL poster: URL?,
                     duration: TimeInterval?) -> LibPreviewSource {
        let modified = (url ?? poster).flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let revision = "\(url?.path ?? "")|\(poster?.path ?? "")|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        return LibPreviewSource(id: id, revision: revision, duration: duration,
                                isTemporal: kind != .image, canScrub: kind != .image && url != nil) { time, size in
            if kind == .audio, let url, let waveform = await AudioWaveformCache.shared.waveform(for: url) {
                let context = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.setFillColor(CGColor(red: 0.08, green: 0.18, blue: 0.12, alpha: 1))
                context?.fill(CGRect(origin: .zero, size: size))
                context?.setFillColor(CGColor(red: 0.45, green: 0.85, blue: 0.6, alpha: 1))
                let span = min(waveform.duration, 14)
                let start = min(max(0, time - span / 2), max(0, waveform.duration - span))
                for x in stride(from: 0, to: Int(size.width), by: 2) {
                    let lower = start + Double(x) / max(1, size.width) * span
                    let upper = start + Double(x + 2) / max(1, size.width) * span
                    let amplitude = max(1, CGFloat(waveform.displayPeak(from: lower, to: upper)) * size.height * 0.8)
                    context?.fill(CGRect(x: CGFloat(x), y: (size.height - amplitude) / 2, width: 1, height: amplitude))
                }
                return context?.makeImage()
            }
            if (kind == .video || kind == .remotion), let url {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = size
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
                if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image { return image }
            }
            guard let url = poster ?? (kind == .image ? url : nil) else { return nil }
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
                ] as CFDictionary)
            }.value
        }
    }
}
