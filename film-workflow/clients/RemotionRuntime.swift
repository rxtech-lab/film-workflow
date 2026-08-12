#if os(macOS)
import Foundation
import Network
import Observation

enum RemotionRuntimeError: LocalizedError {
    case bundleResourceMissing
    case copyFailed(String)
    case bunNotFound
    case studioFailedToStart(String)

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing:
            return "RemotionRuntime resources are missing from the app bundle. Run scripts/build-remotion-runtime.sh and rebuild."
        case .copyFailed(let message):
            return "Failed to set up Remotion runtime: \(message)"
        case .bunNotFound:
            return "Embedded Bun binary is missing. Re-run the build script."
        case .studioFailedToStart(let detail):
            return "Remotion Studio failed to start: \(detail)"
        }
    }
}

@MainActor
@Observable
final class RemotionRuntime {
    static let shared = RemotionRuntime()

    private(set) var currentURL: URL?
    private(set) var currentProjectId: UUID?
    private(set) var lastError: String?
    private(set) var isStarting: Bool = false

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private init() {}

    // MARK: - First launch setup

    func ensureRuntimeInstalled() throws {
        let fm = FileManager.default
        let dest = FileStorage.remotionRoot
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        guard let bundleRuntime = Self.bundleRuntimeURL() else {
            throw RemotionRuntimeError.bundleResourceMissing
        }

        // Bun binary
        let destBun = dest.appendingPathComponent("bun")
        if !fm.fileExists(atPath: destBun.path) {
            let srcBun = bundleRuntime.appendingPathComponent("bun")
            guard fm.fileExists(atPath: srcBun.path) else {
                throw RemotionRuntimeError.bunNotFound
            }
            try fm.copyItem(at: srcBun, to: destBun)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBun.path)
        }

        // Shared root: package.json, remotion.config.ts, tsconfig.json, node_modules, src (default)
        let srcTemplate = bundleRuntime.appendingPathComponent("template")
        for item in ["package.json", "remotion.config.ts", "tsconfig.json", "node_modules", "src"] {
            let src = srcTemplate.appendingPathComponent(item)
            let dst = dest.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: src.path) {
                do {
                    try fm.copyItem(at: src, to: dst)
                } catch {
                    throw RemotionRuntimeError.copyFailed(error.localizedDescription)
                }
            }
        }

        try fm.createDirectory(at: FileStorage.remotionProjectsDir, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    func start(projectId: UUID) async throws {
        if currentProjectId == projectId, process?.isRunning == true {
            return
        }
        await stop()

        try ensureRuntimeInstalled()

        let projectDir = FileStorage.remotionProjectDir(id: projectId)
        try ensureProjectDirectory(projectDir)

        let bunURL = FileStorage.remotionRoot.appendingPathComponent("bun")
        let port = Self.findFreePort()

        isStarting = true
        defer { isStarting = false }

        let proc = Process()
        proc.executableURL = bunURL
        proc.currentDirectoryURL = projectDir
        proc.arguments = [
            "x",
            "remotion",
            "studio",
            "--port=\(port)",
            "--no-open"
        ]

        proc.environment = Self.enrichedEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let logURL = projectDir.appendingPathComponent("studio.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty {
                    try? handle.write(contentsOf: data)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty {
                    try? handle.write(contentsOf: data)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            throw RemotionRuntimeError.studioFailedToStart(error.localizedDescription)
        }

        self.process = proc
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.currentProjectId = projectId

        let url = URL(string: "http://localhost:\(port)")!
        let ok = await Self.waitUntilReachable(url: url, timeout: 30)
        if !ok {
            await stop()
            throw RemotionRuntimeError.studioFailedToStart("Studio did not respond on port \(port) within 30s")
        }
        self.currentURL = url
        self.lastError = nil
    }

    func stop() async {
        if let proc = process, proc.isRunning {
            // Kill the entire process tree — Bun spawns node, which spawns Chromium;
            // a plain terminate() leaves grandchildren orphaned and accumulating.
            ProcessTreeKiller.killTree(rootPID: proc.processIdentifier, signal: SIGTERM)
            for _ in 0..<30 {
                if !proc.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                ProcessTreeKiller.killTree(rootPID: proc.processIdentifier, signal: SIGKILL)
            }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        currentURL = nil
        currentProjectId = nil
    }

    // MARK: - Project directory setup

    func prepareProjectDirectory(id: UUID) throws -> URL {
        try ensureRuntimeInstalled()
        let dir = FileStorage.remotionProjectDir(id: id)
        try ensureProjectDirectory(dir)
        return dir
    }

    private func ensureProjectDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Symlink shared node_modules so Bun can resolve modules.
        let sharedNodeModules = FileStorage.remotionRoot.appendingPathComponent("node_modules")
        let projectNodeModules = dir.appendingPathComponent("node_modules")
        if !fm.fileExists(atPath: projectNodeModules.path) {
            try? fm.createSymbolicLink(at: projectNodeModules, withDestinationURL: sharedNodeModules)
        }

        // Copy package.json / remotion.config.ts / tsconfig.json (small, OK to duplicate).
        let sharedRoot = FileStorage.remotionRoot
        for item in ["package.json", "remotion.config.ts", "tsconfig.json"] {
            let src = sharedRoot.appendingPathComponent(item)
            let dst = dir.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Ensure src/ exists.
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let indexPath = srcDir.appendingPathComponent("index.ts")
        if !fm.fileExists(atPath: indexPath.path) {
            let bundledIndex = sharedRoot.appendingPathComponent("src/index.ts")
            if fm.fileExists(atPath: bundledIndex.path) {
                try? fm.copyItem(at: bundledIndex, to: indexPath)
            }
        }
        let rootPath = srcDir.appendingPathComponent("Root.tsx")
        if !fm.fileExists(atPath: rootPath.path) {
            let bundledRoot = sharedRoot.appendingPathComponent("src/Root.tsx")
            if fm.fileExists(atPath: bundledRoot.path) {
                try? fm.copyItem(at: bundledRoot, to: rootPath)
            }
        }

        // public/ for staticFile()-served assets.
        try fm.createDirectory(at: dir.appendingPathComponent("public", isDirectory: true), withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    private static func bundleRuntimeURL() -> URL? {
        Bundle.main.url(forResource: "RemotionRuntime", withExtension: nil)
    }

    /// macOS GUI-launched apps inherit a thin launchd environment with a minimal PATH
    /// and no shell-style vars. node/Bun/Puppeteer call out to standard tools and need
    /// HOME/TMPDIR/USER, so we backfill missing essentials.
    /// `nonisolated` because it is pure — it reads `ProcessInfo` and nothing
    /// else — so off-main code that spawns a tool can build its environment
    /// without hopping to the main actor.
    nonisolated static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = "0"
        env["CI"] = "1"
        env["BROWSER"] = "none"

        let pathParts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set(pathParts)
        var merged = pathParts
        for p in extras where !seen.contains(p) {
            merged.append(p); seen.insert(p)
        }
        env["PATH"] = merged.joined(separator: ":")

        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["TMPDIR"] == nil { env["TMPDIR"] = NSTemporaryDirectory() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    private static func findFreePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        if socketFD == -1 { return 7711 }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socketFD, sockPtr, len)
            }
        }
        guard bindResult == 0 else { return 7711 }

        var assigned = sockaddr_in()
        var assignedLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(socketFD, sockPtr, &assignedLen)
            }
        }
        guard getResult == 0 else { return 7711 }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    private static func waitUntilReachable(url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                    return true
                }
            } catch {
                // not ready yet
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
#endif
