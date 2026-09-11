import Foundation
import VideoEditorCore

/// Caption audio belongs to the preview only; its timeline drag remains a
/// caption source. Live compositions use the existing document preview session.
@MainActor
final class LibraryFootagePreviewResolver: TimelinePreviewResolver {
    private let fallback: DocumentPreviewMediaResolver
    private let captionAudio: URL?

    init(document: ProjectDocument, width: Int, height: Int, fps: Int, captionAudio: URL?) {
        fallback = DocumentPreviewMediaResolver(document: document, width: width, height: height, fps: fps)
        self.captionAudio = captionAudio
    }
    func preview(_ source: ClipSource) async throws -> TimelinePreviewSource {
        if source.id == "library-caption-audio", let captionAudio {
            return .media(.file(captionAudio, naturalDuration: nil, naturalSize: nil))
        }
        return try await fallback.preview(source)
    }
    func renderedPreview(_ source: ClipSource, progress: @escaping @MainActor (String) -> Void) async throws -> ResolvedMedia {
        try await fallback.renderedPreview(source, progress: progress)
    }
    func release() { fallback.release() }
}
