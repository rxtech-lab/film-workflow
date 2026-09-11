import SwiftUI
import VideoEditorCore

struct TimelineClipFilmstrip: View {
    let clip: Clip
    let resolver: any MediaResolver
    let revision: String
    let width: CGFloat
    let height: CGFloat
    @State private var source: LibPreviewSource?

    var body: some View {
        ZStack {
            Color.clear
            if let source {
                LibPreviewFrameStrip(source: source,
                                     startTime: clip.sourceTime(at: clip.start),
                                     endTime: clip.sourceTime(at: clip.end),
                                     width: width, height: height, symbol: clip.source.kind.symbolName)
            }
        }
        .frame(width: max(1, width), height: height)
        .task(id: clip.source.id + ":" + revision) {
            let result = await resolver.libraryPreview(for: clip.source)
            guard !Task.isCancelled else { return }
            source = result?.refreshed(revision)
        }
        .allowsHitTesting(false)
    }
}
