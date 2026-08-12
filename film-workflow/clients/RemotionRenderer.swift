#if os(macOS)
import Foundation

enum RemotionRenderError: LocalizedError {
    case rendererFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .rendererFailed(let detail):
            return "Render failed: \(detail)"
        }
    }
}

struct RenderProgress: Equatable {
    enum Stage: String { case starting, bundling, gettingCompositions, rendering, encoding }
    var stage: Stage
    var fraction: Double?
    var detail: String?
}

nonisolated enum SystemBrowserLocator {
    /// Returns the chrome-headless-shell that Remotion downloaded into its node_modules,
    /// if present. We do NOT fall back to /Applications/Google Chrome.app: macOS routes
    /// `Chrome.app` launches through a singleton Mach service, so when our app exec's
    /// it with `--user-data-dir`, the launch is hijacked by the user's already-running
    /// Chrome instance and the DevTools handshake never completes.
    @MainActor
    static func firstAvailable() -> URL? {
        let fm = FileManager.default
        let path = chromeHeadlessShellPath()
        return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    @MainActor
    private static func chromeHeadlessShellPath() -> String {
        let root = FileStorage.remotionRoot
            .appendingPathComponent("node_modules/.remotion/chrome-headless-shell")
        let arch: String = {
            #if arch(arm64)
            return "mac-arm64"
            #else
            return "mac-x64"
            #endif
        }()
        return root
            .appendingPathComponent("\(arch)/chrome-headless-shell-\(arch)/chrome-headless-shell")
            .path
    }
}

nonisolated enum ProcessTreeKiller {
    /// Recursively kills `pid` and all of its descendants.
    static func killTree(rootPID: pid_t, signal sig: Int32 = SIGTERM) {
        signalAll(snapshot(rootPID: rootPID), sig)
    }

    /// `rootPID` plus every descendant, deepest-first.
    ///
    /// Capture this BEFORE signalling if you intend to escalate later: once the root
    /// exits, its surviving children reparent to launchd and `pgrep -P <root>` can no
    /// longer see them. Re-deriving the tree at escalation time silently misses exactly
    /// the processes that ignored the first signal.
    static func snapshot(rootPID: pid_t) -> [pid_t] {
        collectDescendants(of: rootPID).reversed() + [rootPID]
    }

    static func signalAll(_ pids: [pid_t], _ sig: Int32) {
        for pid in pids { kill(pid, sig) }
    }

    static func anyAlive(_ pids: [pid_t]) -> Bool {
        pids.contains { kill($0, 0) == 0 }
    }

    private static func collectDescendants(of root: pid_t) -> [pid_t] {
        var collected: [pid_t] = []
        var queue: [pid_t] = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for child in children(of: next) {
                collected.append(child)
                queue.append(child)
            }
        }
        return collected
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", "\(parent)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: { $0.isNewline })
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Kills any `bun`/`node` process whose command line references the given path fragment.
    /// Used to clean up orphans from prior app launches that survived an unclean exit.
    static func killOrphans(matching pathFragment: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", pathFragment]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return }
        let pids = s.split(whereSeparator: { $0.isNewline })
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        let me = getpid()
        for pid in pids where pid != me {
            kill(pid, SIGTERM)
        }
        // Brief grace, then force-kill survivors.
        usleep(200_000)
        for pid in pids where pid != me {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}

/// Owns the launch/cancel ordering for a child process tree.
///
/// `withTaskCancellationHandler` may run `onCancel` before, during, or after the
/// process launches, so the launch and the kill have to be serialised against each
/// other. The SIGKILL escalation also has to live here rather than after the `await`:
/// that await only resumes once the process has already exited, which is precisely
/// what does not happen when SIGTERM is ignored.
private final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var rootPID: pid_t?
    private var cancelled = false

    /// Launches under the lock, so a concurrent `cancel()` either wins the race — and
    /// this returns false having spawned nothing — or blocks briefly and then sees a
    /// live pid to signal. Returns false only when cancellation got there first.
    func launch(_ proc: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        try proc.run()
        rootPID = proc.processIdentifier
        return true
    }

    func cancel(graceSeconds: Double = 3) {
        lock.lock()
        cancelled = true
        let root = rootPID
        lock.unlock()

        // Not launched yet: `launch()` will see `cancelled` and decline to spawn.
        guard let root else { return }

        let tree = ProcessTreeKiller.snapshot(rootPID: root)
        ProcessTreeKiller.signalAll(tree, SIGTERM)

        // Escalate on a timer rather than inline, so a bun/node/ffmpeg that sits on
        // SIGTERM still dies and the awaiting continuation gets its termination.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + graceSeconds) {
            if ProcessTreeKiller.anyAlive(tree) {
                ProcessTreeKiller.signalAll(tree, SIGKILL)
            }
        }
    }
}

enum RemotionRenderer {
    static func render(
        projectId: UUID,
        to outputURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        onProgress: @escaping @MainActor (RenderProgress) -> Void
    ) async throws {
        await RemotionRuntime.shared.stop()

        let projectDir = try await MainActor.run {
            try RemotionRuntime.shared.prepareProjectDirectory(id: projectId)
        }

        // Kill any orphan bun/remotion processes still pointed at this project from
        // prior app sessions — they hold locks that can deadlock our new render.
        ProcessTreeKiller.killOrphans(matching: projectDir.path)

        let bunURL = FileStorage.remotionRoot.appendingPathComponent("bun")

        let outDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let logURL = projectDir.appendingPathComponent("render.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        var args: [String] = [
            "x",
            "remotion",
            "render",
            "src/index.ts",
            "Main",
            outputURL.path,
            "--width", "\(width)",
            "--height", "\(height)",
            "--fps", "\(fps)",
            // Encode via VideoToolbox when the Mac offers it, falling back to libx264
            // silently otherwise. Passed on the CLI rather than set in remotion.config.ts
            // because projects created before this change keep their own copy of that
            // config file (see RemotionRuntime.ensureProjectDirectory) and would never
            // pick it up. Note: setting a CRF/quality option makes Remotion drop back to
            // the software encoder, so don't add one and expect both.
            "--hardware-acceleration", "if-possible"
        ]
        // Prefer the user's installed Chromium-family browser to avoid the 143MB
        // chrome-headless-shell auto-download. Falls through to Remotion's default
        // when no system browser is found.
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

        let logHandle = try? FileHandle(forWritingTo: logURL)

        await MainActor.run { onProgress(RenderProgress(stage: .starting, fraction: nil, detail: nil)) }

        let outBuffer = LineBuffer()
        let errBuffer = LineBuffer()

        let parseAndForward: (String) -> Void = { line in
            guard let p = ProgressParser.parse(line: line) else { return }
            Task { @MainActor in onProgress(p) }
        }

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            try? logHandle?.write(contentsOf: data)
            for line in outBuffer.append(data) { parseAndForward(line) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            try? logHandle?.write(contentsOf: data)
            for line in errBuffer.append(data) { parseAndForward(line) }
        }

        let canceller = CancellableProcess()

        let exitStatus: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                proc.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do {
                    if try !canceller.launch(proc) {
                        // Cancelled before we spawned anything.
                        proc.terminationHandler = nil
                        cont.resume(returning: -1)
                    }
                } catch {
                    proc.terminationHandler = nil
                    let line = "process failed to launch: \(error.localizedDescription)\n"
                    try? logHandle?.write(contentsOf: Data(line.utf8))
                    cont.resume(returning: -1)
                }
            }
        } onCancel: {
            canceller.cancel()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? logHandle?.close()

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }

        if exitStatus != 0 {
            try? FileManager.default.removeItem(at: outputURL)
            let detail = tail(of: logURL, lines: 40)
            throw RemotionRenderError.rendererFailed(detail: detail.isEmpty ? "exit code \(exitStatus)" : detail)
        }
    }

    private static func tail(of url: URL, lines: Int) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let split = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let suffix = split.suffix(lines)
        return suffix.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LineBuffer: @unchecked Sendable {
    nonisolated(unsafe) private var buffer = Data()

    nonisolated func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let chunk = buffer[..<idx]
            if let s = String(data: chunk, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
            buffer.removeSubrange(...idx)
        }
        return lines
    }
}

private enum ProgressParser {
    private static let ansi = try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[A-Za-z]")
    private static let percent = try! NSRegularExpression(pattern: "(\\d{1,3})\\s*%")
    private static let frac = try! NSRegularExpression(pattern: "(\\d{1,7})\\s*/\\s*(\\d{1,7})")

    static func parse(line raw: String) -> RenderProgress? {
        let stripped = strip(raw)
        guard !stripped.isEmpty else { return nil }
        let lower = stripped.lowercased()

        // Encoding/stitching first — Remotion's "Encoded N/M" lines also contain a fraction
        // that would otherwise match the rendering branch below.
        if lower.contains("encoded") || lower.contains("encoding") || lower.contains("stitching") || lower.contains("muxing") || lower.contains("muxed") {
            return progress(stage: .encoding, line: stripped, fractionDetail: "frames")
        }

        if lower.contains("rendered") || lower.contains("rendering frames") {
            return progress(stage: .rendering, line: stripped, fractionDetail: "frames")
        }

        if lower.contains("getting composition") {
            return RenderProgress(stage: .gettingCompositions, fraction: nil, detail: nil)
        }

        if lower.contains("bundling") || lower.contains("bundled") {
            if let p = matchInt(percent, in: stripped) {
                return RenderProgress(
                    stage: .bundling,
                    fraction: min(1, Double(p) / 100.0),
                    detail: nil
                )
            }
            return RenderProgress(stage: .bundling, fraction: nil, detail: nil)
        }

        return nil
    }

    private static func progress(stage: RenderProgress.Stage, line: String, fractionDetail unit: String) -> RenderProgress {
        if let (a, b) = matchPair(frac, in: line), b > 0 {
            return RenderProgress(
                stage: stage,
                fraction: min(1, Double(a) / Double(b)),
                detail: "\(a) / \(b) \(unit)"
            )
        }
        if let p = matchInt(percent, in: line) {
            return RenderProgress(stage: stage, fraction: min(1, Double(p) / 100.0), detail: nil)
        }
        return RenderProgress(stage: stage, fraction: nil, detail: nil)
    }

    private static func strip(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        let cleaned = ansi.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchInt(_ re: NSRegularExpression, in s: String) -> Int? {
        let nsRange = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: nsRange), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    private static func matchPair(_ re: NSRegularExpression, in s: String) -> (Int, Int)? {
        let nsRange = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: nsRange), m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: s),
              let r2 = Range(m.range(at: 2), in: s),
              let a = Int(s[r1]), let b = Int(s[r2]) else { return nil }
        return (a, b)
    }
}
#endif
