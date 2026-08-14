import AVFoundation
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Poster frames and dimensions for generated clips.
///
/// Everything here is best-effort and returns `nil` rather than throwing: a
/// missing thumbnail is a cosmetic problem, and a render that already cost
/// minutes and money must never be discarded because `AVAssetImageGenerator`
/// disliked the file.
nonisolated enum VideoThumbnailer {
    /// Extracts a frame shortly after the start and saves it into `images/`.
    /// Returns its relative path, or `nil` if the frame could not be produced.
    static func generate(for url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

        // Half a second in: the true first frame of a generated clip is often a
        // fade from black, which makes for a useless card.
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        guard let data = jpegData(from: cgImage) else { return nil }
        return try? FileStorage.saveImage(data, fileExtension: "jpg")
    }

    /// Natural size and duration, for labelling the history card.
    static func probe(url: URL) async -> (width: Int, height: Int, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let size = try? await track.load(.naturalSize) else { return nil }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = size.applying(transform)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        return (
            width: Int(abs(oriented.width).rounded()),
            height: Int(abs(oriented.height).rounded()),
            duration: duration.isFinite ? duration : 0
        )
    }

    // MARK: - Private

    private static func jpegData(from cgImage: CGImage) -> Data? {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #else
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
        #endif
    }
}
