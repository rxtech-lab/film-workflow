import Foundation
import Observation
import VideoEditorCore

/// The wizard uses the same live and rendered preview paths as the editor.
@MainActor @Observable
final class SimpleModePlayback {
    let player = TimelinePlayerController()
    @ObservationIgnored lazy var preview = TimelinePreviewController(transport: player)
    private(set) var usesLivePreview = false
    private(set) var preparation: String?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func load(_ sequence: SequenceProject?, document: ProjectDocument) {
        task?.cancel()
        generation = UUID()
        preparation = nil
        error = nil
        guard let sequence, !sequence.timeline.allClips.isEmpty else {
            unload()
            return
        }
        let timeline = sequence.timeline
        let hasRemotion = timeline.allClips.contains { $0.source.kind == .remotion }
        usesLivePreview = hasRemotion && !timeline.hasActiveModifiers
        if usesLivePreview {
            preview.load(timeline, resolver: DocumentPreviewMediaResolver(
                document: document, width: sequence.width, height: sequence.height, fps: sequence.fps
            ))
        } else {
            preview.unload()
            let fallback = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
            guard hasRemotion else {
                player.load(timeline, resolver: fallback)
                return
            }
            // Effects need the compositor, so render just the Remotion sources
            // first, then play the full timeline with its transforms and audio.
            player.setBuffering(true)
            preparation = "Preparing effects preview…"
            let resolver = DocumentPreviewMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
            let requested = generation
            task = Task { @MainActor in
                defer { resolver.release() }
                do {
                    var files: [String: ResolvedMedia] = [:]
                    for clip in timeline.allClips where clip.source.kind == .remotion && files[clip.source.id] == nil {
                        files[clip.source.id] = try await resolver.renderedPreview(clip.source) { [weak self] message in
                            if self?.generation == requested { self?.preparation = message }
                        }
                        try Task.checkCancellation()
                    }
                    guard generation == requested else { return }
                    player.setBuffering(false)
                    player.load(timeline, resolver: RenderedModifierMediaResolver(files: files, fallback: fallback))
                    preparation = nil
                } catch {
                    guard !Task.isCancelled, generation == requested else { return }
                    preparation = nil
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func unload() {
        generation = UUID()
        task?.cancel()
        task = nil
        preview.unload()
        player.unload()
        usesLivePreview = false
        preparation = nil
        error = nil
    }
}
