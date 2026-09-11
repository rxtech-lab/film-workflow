import CoreGraphics
import Foundation
import VideoEditorCore

/// Cached Remotion frames participate in the same compositor as native media.
nonisolated struct RenderedModifierMediaResolver: MediaResolver {
    let files: [String: ResolvedMedia]
    let fallback: DocumentMediaResolver
    func resolve(_ source: ClipSource) async throws -> ResolvedMedia {
        if let file = files[source.id] { return file }
        return try await fallback.resolve(source)
    }
    func thumbnail(for source: ClipSource, at time: TimeInterval) async -> CGImage? {
        await fallback.thumbnail(for: source, at: time)
    }
}
