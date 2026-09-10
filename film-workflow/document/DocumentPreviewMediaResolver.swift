import CoreGraphics
import Foundation
import SwiftData
import VideoEditorCore

@MainActor
final class DocumentPreviewMediaResolver: TimelinePreviewResolver {
    private let document: ProjectDocument
    private let width: Int
    private let height: Int
    private let fps: Int
    private var leases: [String: RemotionPreviewLease] = [:]
    private var released = false

    init(document: ProjectDocument, width: Int, height: Int, fps: Int) {
        self.document = document; self.width = width; self.height = height; self.fps = fps
    }

    private func project(_ source: ClipSource) throws -> RemotionProject {
        guard let (prefix, id) = DocumentMediaResolver.parse(source.id), prefix == .remotion,
              let project = try document.container.mainContext.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == id })).first else {
            throw MediaResolverError.missing(source)
        }
        return project
    }

    func preview(_ source: ClipSource) async throws -> TimelinePreviewSource {
        guard source.kind == .remotion else {
            return .media(try await DocumentMediaResolver(document: document, width: width, height: height, fps: fps).resolve(source))
        }
        let project = try project(source)
        let lease = try await RemotionPreviewSessions.shared.acquire(project: project)
        guard !released, !Task.isCancelled else { lease.release(); throw CancellationError() }
        leases[source.id]?.release()
        leases[source.id] = lease
        var url = URLComponents(url: lease.url, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "height", value: String(height))]
        return .live(LivePreviewDescriptor(url: url.url!, fps: max(1, project.compositionFps),
                                           frames: max(1, Int((project.durationSeconds * Double(max(1, project.compositionFps))).rounded())),
                                           width: width, height: height))
    }

    func renderedPreview(_ source: ClipSource, progress: @escaping @MainActor (String) -> Void) async throws -> ResolvedMedia {
        let project = try project(source)
        let url = try await RemotionPreviewRenderCache.render(project: project, width: width, height: height) {
            progress("Preparing rendered preview" + ($0.detail.map { " · \($0)" } ?? "…"))
        }
        return .file(url, naturalDuration: project.durationSeconds, naturalSize: CGSize(width: width, height: height))
    }

    func release() {
        released = true
        leases.values.forEach { $0.release() }; leases = [:]
    }
}
