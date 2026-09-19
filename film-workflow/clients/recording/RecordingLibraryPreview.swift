import AVFoundation
import CoreGraphics
import VideoEditorCore

@MainActor extension RecordingTake {
    func makeLibPreviewSource() -> LibPreviewSource {
        let revision = "\(componentsData.hashValue):\(project?.presentationData.hashValue ?? 0):\(project?.shortcutStyleData.hashValue ?? 0)"
        guard let timeline = try? RecordingTimelineService.previewTimeline(self) else { return .file(id: clipSource.id, kind: .video, mediaURL: mediaURL, thumbnailURL: nil, duration: duration) }
        var files = components.reduce(into: [String: ResolvedMedia]()) { result, component in
            result["screenRecording:\(component.id)"] = component.role == .shortcuts ? .captions(component.cues) : .file(ProjectStorage.for(model: self).absoluteURL(for: component.filePath), naturalDuration: component.duration, naturalSize: CGSize(width: component.width, height: component.height))
        }
        // Zoom clips carry no media, but the builder resolves every clip it sees.
        for clip in timeline.allClips where clip.recordingZoom != nil { files[clip.source.id] = .captions([]) }
        let renderer = RecordingThumbnailRenderer(timeline: timeline, resolver: RecordingSnapshotResolver(files: files))
        return LibPreviewSource(id: clipSource.id, revision: revision, duration: duration, isTemporal: true, canScrub: duration > 0) { time, size in await renderer.image(at: time, size: size) }
    }
}
private struct RecordingSnapshotResolver: MediaResolver {
    let files: [String: ResolvedMedia]
    func resolve(_ source: ClipSource) async throws -> ResolvedMedia { guard let media = files[source.id] else { throw MediaResolverError.missing(source) }; return media }
    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? { nil }
}
@MainActor private final class RecordingThumbnailRenderer {
    let timeline: Timeline
    let resolver: RecordingSnapshotResolver
    var built: BuiltComposition?
    init(timeline: Timeline, resolver: RecordingSnapshotResolver) { self.timeline = timeline; self.resolver = resolver }
    func image(at time: Double, size: CGSize) async -> CGImage? {
        do {
            if built == nil { built = try await TimelineCompositionBuilder(resolver: resolver).build(timeline, allowPlaceholders: false) }
            guard let built else { return nil }
            let generator = AVAssetImageGenerator(asset: built.asset); generator.videoComposition = built.videoComposition; generator.maximumSize = size
            generator.requestedTimeToleranceAfter = .zero; generator.requestedTimeToleranceBefore = .zero
            return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        } catch { return nil }
    }
}
