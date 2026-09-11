import SwiftUI
import VideoEditorCore

/// Shared picture rail. Each tile samples its own position on the source clock;
/// a reversed range samples in reverse order. Lazy tiles avoid decoding offscreen media.
public struct LibPreviewFrameStrip: View {
    let source: LibPreviewSource
    let startTime: Double
    let endTime: Double
    let width: CGFloat
    let height: CGFloat
    let symbol: String

    public init(source: LibPreviewSource, startTime: Double, endTime: Double,
                width: CGFloat, height: CGFloat, symbol: String) {
        self.source = source; self.startTime = startTime; self.endTime = endTime
        self.width = width; self.height = height; self.symbol = symbol
    }

    public var body: some View {
        let tileWidth = max(1, height * 16 / 9)
        let count = max(1, Int(ceil(max(1, width) / tileWidth)))
        LazyHStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let tileStart = Double(index) * tileWidth
                let visibleWidth = min(tileWidth, max(0, width - tileStart))
                let fraction = (tileStart + visibleWidth / 2) / max(1, width)
                LibPreviewFrame(source: source, time: startTime + (endTime - startTime) * fraction,
                                width: tileWidth, height: height, symbol: symbol)
            }
        }
        .frame(width: max(1, width), height: height, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LibPreviewFrame: View {
    let source: LibPreviewSource
    let time: Double
    let width: CGFloat
    let height: CGFloat
    let symbol: String
    @State private var image: CGImage?
    private struct Request: Hashable {
        let source: LibPreviewSource
        let time: Double
        let width: CGFloat
        let height: CGFloat
    }

    var body: some View {
        Rectangle().fill(.black.opacity(0.25))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .task(id: Request(source: source, time: time, width: width, height: height)) {
                image = nil
                let result = await source.thumbnail(at: time, maximumSize: CGSize(width: width * 2, height: height * 2))
                guard !Task.isCancelled else { return }
                image = result
            }
    }
}
