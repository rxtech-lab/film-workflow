import Foundation
import RxRemotion

struct StillCaptureResult { let frame: Int; let url: URL }
@MainActor
enum RemotionStillCapture {
    static func still(projectDir: URL, frame: Int, width: Int = 480, height: Int = 270, runId: String) async throws -> URL {
        try RemotionRuntime.shared.prepareProjectDirectory(projectDir)
        let outDir = projectDir.appendingPathComponent(".agent-stills").appendingPathComponent(runId)
        let output = outDir.appendingPathComponent("frame-\(frame).png")
        let engine = RemotionEngine(configuration: RemotionMapSettings.configuration)
        defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: projectDir)
        try await engine.renderStill(project: project, frame: frame, to: output, settings: .init(width: width, height: height))
        return output
    }

    /// Render N evenly-spaced stills covering [0, durationFrames - 1]. Captured sequentially with independent deterministic frame advancement.
    static func stills(
        projectDir: URL,
        count: Int,
        durationFrames: Int,
        width: Int = 480,
        height: Int = 270,
        runId: String
    ) async throws -> [StillCaptureResult] {
        let n = max(1, count)
        let lastFrame = max(0, durationFrames - 1)
        let frames: [Int]
        if n == 1 {
            frames = [lastFrame / 2]
        } else {
            frames = (0..<n).map { i in
                let t = Double(i) / Double(n - 1)
                return Int((t * Double(lastFrame)).rounded())
            }
        }

        var results: [StillCaptureResult] = []
        for frame in frames {
            let url = try await still(
                projectDir: projectDir,
                frame: frame,
                width: width,
                height: height,
                runId: runId
            )
            results.append(StillCaptureResult(frame: frame, url: url))
        }
        return results
    }

    /// Best-effort cleanup of stills for a finished agent run.
    static func cleanup(projectDir: URL, runId: String) {
        let dir = projectDir
            .appendingPathComponent(".agent-stills", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}
