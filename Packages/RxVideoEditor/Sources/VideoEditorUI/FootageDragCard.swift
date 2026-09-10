import AppKit
import SwiftUI
import VideoEditorCore

public extension View {
    /// Makes the view drag `footage` onto the timeline: the clip card travels
    /// under the pointer, and lanes draw the clip at its real length as it
    /// hovers. `alsoRegistering` can add other payloads to the same drag.
    func timelineDraggable(_ footage: some TimelineDraggable, alsoRegistering extra: ((NSItemProvider) -> Void)? = nil) -> some View {
        timelineDraggable(footage.dragItem, thumbnailURL: footage.thumbnailURL, alsoRegistering: extra)
    }

    /// The same, for a payload the caller has already assembled.
    func timelineDraggable(_ item: FootageDragItem, thumbnailURL: URL? = nil, alsoRegistering extra: ((NSItemProvider) -> Void)? = nil) -> some View {
        onDrag {
            let provider = NSItemProvider()
            provider.register(item)
            extra?(provider)
            MainActor.assumeIsolated { FootageDragSession.shared.begin(item) }
            return provider
        } preview: {
            FootageDragCard(item: item, thumbnailURL: thumbnailURL)
        }
    }
}

/// What travels under the pointer: a clip-shaped card with the thumbnail,
/// the name and the length, the way the clip will look on the timeline.
public struct FootageDragCard: View {
    let item: FootageDragItem
    let thumbnailURL: URL?

    public init(item: FootageDragItem, thumbnailURL: URL?) {
        self.item = item
        self.thumbnailURL = thumbnailURL
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.3))
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.source.kind.symbolName).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 56, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                if let duration = item.duration, duration > 0 {
                    Text(DurationLabel.short(duration)).font(.system(size: 10, design: .monospaced))
                } else if item.source.kind == .image {
                    Text("Still").font(.system(size: 10))
                }
            }
            .foregroundStyle(.white)
        }
        .padding(5)
        .frame(width: 180, alignment: .leading)
        .background(item.source.kind.clipColor, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.5)))
    }
}

public extension SourceKind {
    var symbolName: String {
        switch self {
        case .audio: return "waveform"
        case .video: return "film"
        case .image: return "photo"
        case .captions: return "captions.bubble"
        case .remotion: return "atom"
        }
    }

    /// The colour clips of this kind take on the timeline and on drag cards.
    var clipColor: Color {
        switch self {
        case .video: return Color(red: 0.30, green: 0.45, blue: 0.72)
        case .remotion: return Color(red: 0.52, green: 0.36, blue: 0.75)
        case .image: return Color(red: 0.35, green: 0.62, blue: 0.55)
        case .audio: return Color(red: 0.25, green: 0.60, blue: 0.35)
        case .captions: return Color(red: 0.80, green: 0.55, blue: 0.20)
        }
    }
}

/// Clock-style lengths for footage: `0:07`, `1:24`, `1:02:03`.
public enum DurationLabel {
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The same clock with tenths, for a running transport.
    public static func precise(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let tenths = Int(((clamped - Double(whole)) * 10).rounded(.down))
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        return h > 0
            ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
            : String(format: "%d:%02d.%d", m, s, tenths)
    }
}
