import Foundation

struct RenderProgress: Equatable {
    enum Stage: String { case starting, bundling, gettingCompositions, rendering, encoding }
    var stage: Stage
    var fraction: Double?
    var detail: String?
}

/// Renders a Remotion project to a movie natively with MotionSwift (Skia on Metal).
@MainActor
enum RemotionRenderer {
    static func render(projectDir: URL, to outputURL: URL, width: Int, height: Int, fps: Int,
                       preserveAlpha: Bool = false, captureScale: Double? = nil, onProgress: @escaping @MainActor (RenderProgress) -> Void) async throws {
        try RemotionRuntime.shared.prepareProjectDirectory(projectDir)
        let request = MotionSwiftMovieRenderer.Request(projectDir: projectDir, output: outputURL, width: width, height: height,
                                                       fps: fps, preserveAlpha: preserveAlpha, captureScale: captureScale)
        do {
            try await MotionSwiftMovieRenderer.render(request) { update in
                let stage: RenderProgress.Stage = switch update.stage {
                case .compiling: .bundling
                case .rendering: .rendering
                case .encoding: .encoding
                }
                Task { @MainActor in onProgress(.init(stage: stage, fraction: update.fraction, detail: update.detail)) }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
