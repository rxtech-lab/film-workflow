import AVFoundation
import ImageIO
import SwiftUI
import VideoEditorUI

/// A shared 16:9 poster with a readable duration badge. Decode only a small
/// image off the main actor, and recover a poster from video when needed.
struct FootageThumbnail: View {
    let thumbnailURL: URL?
    var videoURL: URL?
    let icon: String
    let duration: TimeInterval?
    var isStill = false
    var isSelected = false
    var cornerRadius: CGFloat = 6

    @State private var image: CGImage?

    private struct Request: Hashable {
        let thumbnail: URL?
        let video: URL?
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(alignment: .bottomTrailing) {
                if let duration, duration.isFinite, duration > 0 {
                    badge(Text(DurationLabel.short(duration)))
                } else if isStill {
                    badge(Text("Still"))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .task(id: Request(thumbnail: thumbnailURL, video: videoURL)) {
                image = nil
                let result = await Self.load(thumbnail: thumbnailURL, video: videoURL)
                guard !Task.isCancelled else { return }
                image = result
            }
    }

    private func badge(_ label: Text) -> some View {
        label
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }

    nonisolated private static func load(thumbnail: URL?, video: URL?) async -> CGImage? {
        if let thumbnail {
            let poster = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(thumbnail as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                ] as CFDictionary)
            }.value
            if let poster { return poster }
        }
        guard !Task.isCancelled, let video else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let frame = try? await generator.image(at: time).image { return frame }
        guard !Task.isCancelled else { return nil }
        return try? await generator.image(at: .zero).image
    }
}
