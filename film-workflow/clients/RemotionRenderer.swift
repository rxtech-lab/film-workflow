import Foundation
import RxRemotion

struct RenderProgress: Equatable {
    enum Stage: String { case starting, bundling, gettingCompositions, rendering, encoding }
    var stage: Stage
    var fraction: Double?
    var detail: String?
}

@MainActor
enum RemotionRenderer {
    static func render(projectDir: URL, to outputURL: URL, width: Int, height: Int, fps: Int,
                       preserveAlpha: Bool = false, captureScale: Double? = nil, onProgress: @escaping @MainActor (RenderProgress) -> Void) async throws {
        try RemotionRuntime.shared.prepareProjectDirectory(projectDir)
        let engine = RemotionEngine(configuration: RemotionMapSettings.configuration)
        defer { engine.closeAll() }
        onProgress(.init(stage: .bundling, fraction: nil, detail: nil))
        let project = try await engine.prepare(projectURL: projectDir)
        try await engine.renderMovie(project: project, to: outputURL,
            settings: .init(width: width, height: height, fps: Double(fps), codec: preserveAlpha ? .proRes4444 : .h264,
                            concurrency: RemotionRenderPreferences.concurrency, captureScale: captureScale)) { update in
                let stage: RenderProgress.Stage = switch update.stage {
                case .preparing: .starting
                case .compiling: .bundling
                case .rendering: .rendering
                case .encoding: .encoding
                }
                onProgress(.init(stage: stage, fraction: update.fraction, detail: update.detail))
            }
    }
}
