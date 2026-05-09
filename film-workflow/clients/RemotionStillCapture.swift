#if os(macOS)
import Foundation

enum RemotionStillCaptureError: LocalizedError {
    case stillFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .stillFailed(let detail):
            return "Still capture failed: \(detail)"
        }
    }
}

struct StillCaptureResult {
    let frame: Int
    let url: URL
}

enum RemotionStillCapture {

    /// Render a single still PNG for the given frame. Runs alongside Studio without
    /// disrupting it (Studio's dev-server and `remotion still` use distinct webpack
    /// outputs). Returns the on-disk PNG URL.
    static func still(
        projectId: UUID,
        frame: Int,
        width: Int = 480,
        height: Int = 270,
        runId: String
    ) async throws -> URL {
        let projectDir = await MainActor.run {
            try? RemotionRuntime.shared.prepareProjectDirectory(id: projectId)
        }
        guard let projectDir else {
            throw RemotionStillCaptureError.stillFailed(detail: "project directory not ready")
        }

        let outDir = projectDir
            .appendingPathComponent(".agent-stills", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("frame-\(frame).png")
        // Stale file from a previous run with the same frame — remove so Remotion writes fresh.
        try? FileManager.default.removeItem(at: outURL)

        let bunURL = FileStorage.remotionRoot.appendingPathComponent("bun")

        var args: [String] = [
            "x",
            "remotion",
            "still",
            "src/index.ts",
            "Main",
            outURL.path,
            "--frame", "\(frame)",
            "--image-format", "png",
            "--scale", "1",
            "--width", "\(width)",
            "--height", "\(height)",
            "--log", "error"
        ]
        let browser = await MainActor.run { SystemBrowserLocator.firstAvailable() }
        if let browser {
            args.append(contentsOf: ["--browser-executable", browser.path])
        }

        let proc = Process()
        proc.executableURL = bunURL
        proc.currentDirectoryURL = projectDir
        proc.arguments = args
        proc.environment = await MainActor.run { RemotionRuntime.enrichedEnvironment() }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let errBuffer = StillErrBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errBuffer.append(d) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            _ = h.availableData
        }

        let exitStatus: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                proc.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    cont.resume(returning: -1)
                }
            }
        } onCancel: {
            if proc.isRunning {
                ProcessTreeKiller.killTree(rootPID: proc.processIdentifier, signal: SIGTERM)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if Task.isCancelled {
            throw CancellationError()
        }

        if exitStatus != 0 {
            let detail = String(data: errBuffer.snapshot(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemotionStillCaptureError.stillFailed(
                detail: detail.isEmpty ? "exit code \(exitStatus)" : detail
            )
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw RemotionStillCaptureError.stillFailed(detail: "PNG not produced at \(outURL.lastPathComponent)")
        }
        return outURL
    }

    /// Render N evenly-spaced stills covering [0, durationFrames - 1]. Sequential to reuse
    /// the webpack bundle cache between calls — running them in parallel would force
    /// duplicate bundling.
    static func stills(
        projectId: UUID,
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
                projectId: projectId,
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
    static func cleanup(projectId: UUID, runId: String) {
        let dir = FileStorage.remotionProjectDir(id: projectId)
            .appendingPathComponent(".agent-stills", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

private final class StillErrBuffer: @unchecked Sendable {
    nonisolated(unsafe) private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
#endif
