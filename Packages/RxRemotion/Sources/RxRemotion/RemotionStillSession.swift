import Foundation

/// A bounded owner should serialize requests and close the session when idle.
/// Forward requests only replay new frames; backward requests restart so stateful
/// canvases and seeded randomness remain identical to a fresh still export.
@MainActor
public final class RemotionStillSession {
    private let project: RemotionPreparedProject
    private let settings: RemotionRenderSettings
    private var page: RemotionWebPage?
    private var previous = -1
    private var busy = false
    private var closed = false
    private(set) var advancedFrameCount = 0

    init(project: RemotionPreparedProject, settings: RemotionRenderSettings) {
        self.project = project
        self.settings = settings
    }

    public func render(frame: Int, to output: URL) async throws {
        guard !closed else { throw RemotionError.disposed }
        guard !busy else { throw RemotionError.rendering("Still session requests must be serialized") }
        guard frame >= 0 else { throw RemotionError.rendering("Still frame is outside the composition") }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            if frame < previous {
                page?.dispose(); page = nil; previous = -1
            }
            if page == nil {
                let created = try await RemotionWebPage(project: project, mode: "render", compositionID: "Main", inputProps: [:], settings: settings)
                guard !closed else { created.dispose(); throw RemotionError.disposed }
                page = created
            }
            guard let page, let composition = page.compositions.first,
                  frame < composition.durationInFrames else {
                throw RemotionError.rendering("Still frame is outside the composition")
            }
            if previous < frame {
                for index in (previous + 1)...frame {
                    _ = try await page.advance(to: index)
                    previous = index
                    advancedFrameCount += 1
                }
            }
            let image = try await page.capture()
            try await NativeMedia.writePNG(image, to: output)
        } catch {
            // Cancellation may have disposed the underlying WebView. Never reuse
            // a partially advanced or failed renderer on a subsequent request.
            page?.dispose(); page = nil; previous = -1
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        page?.dispose(); page = nil
        project.close()
        await ProjectFiles.remove(project.directory)
    }
}
