import CryptoKit
import Foundation
import Observation

extension Notification.Name {
    static let remotionPreviewChanged = Notification.Name("RemotionPreviewChanged")
}

/// Compiler processes are shared by document/project directory, never by playback position.
@MainActor
final class RemotionPreviewSessions {
    static let shared = RemotionPreviewSessions()
    private struct Entry {
        let session: RemotionPreviewSession
        var owners: Set<UUID>
    }
    private var entries: [URL: Entry] = [:]

    func acquire(project: RemotionProject) async throws -> RemotionPreviewLease {
        let directory = project.projectDir.standardizedFileURL
        try RemotionRuntime.shared.prepareProjectDirectory(directory)
        let source = directory.appendingPathComponent("src/Composition.tsx")
        if !FileManager.default.fileExists(atPath: source.path), !project.compositionSource.isEmpty {
            try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RemotionRuntimeError.studioFailedToStart("Create a composition to start the preview.")
        }
        let owner = UUID()
        if entries[directory] == nil {
            entries[directory] = Entry(session: RemotionPreviewSession(directory: directory), owners: [])
        }
        entries[directory]!.owners.insert(owner)
        let session = entries[directory]!.session
        do {
            let url = try await session.start()
            try Task.checkCancellation()
            return RemotionPreviewLease(directory: directory, owner: owner, url: url)
        } catch {
            release(directory: directory, owner: owner)
            throw error
        }
    }

    fileprivate func release(directory: URL, owner: UUID) {
        guard var entry = entries[directory] else { return }
        entry.owners.remove(owner)
        if entry.owners.isEmpty {
            entries.removeValue(forKey: directory)
            entry.session.stop()
        } else { entries[directory] = entry }
    }

    func stopAll(in package: URL? = nil) {
        for directory in Array(entries.keys) where package == nil || directory.path.hasPrefix(package!.path + "/") {
            entries.removeValue(forKey: directory)?.session.stop()
        }
    }
}

@MainActor
final class RemotionPreviewLease {
    let directory: URL
    let owner: UUID
    let url: URL
    private var released = false

    fileprivate init(directory: URL, owner: UUID, url: URL) {
        self.directory = directory; self.owner = owner; self.url = url
    }

    func release() {
        guard !released else { return }
        released = true
        RemotionPreviewSessions.shared.release(directory: directory, owner: owner)
    }

    deinit {
        let directory = directory, owner = owner
        Task { @MainActor in RemotionPreviewSessions.shared.release(directory: directory, owner: owner) }
    }
}

@MainActor
private final class RemotionPreviewSession {
    let directory: URL
    private var process: Process?
    private var pipe: Pipe?
    private var url: URL?
    private var detail = ""
    private var starting: Task<URL, Error>?
    private let cache: URL

    init(directory: URL) {
        self.directory = directory
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("rx-remotion-preview-\(UUID().uuidString)", isDirectory: true)
    }

    func start() async throws -> URL {
        if let starting { return try await starting.value }
        let task = Task { @MainActor in
            let proc = Process()
            proc.executableURL = FileStorage.remotionRoot.appendingPathComponent("bun")
            proc.arguments = [FileStorage.remotionRoot.appendingPathComponent("player/server.cjs").path, directory.path, cache.path]
            proc.currentDirectoryURL = FileStorage.remotionRoot
            proc.environment = RemotionRuntime.enrichedEnvironment()
            let output = Pipe()
            proc.standardOutput = output
            proc.standardError = output
            let buffer = LineBuffer()
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let lines = buffer.append(handle.availableData)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for line in lines {
                        if line.hasPrefix("RX_PREVIEW_URL=") { self.url = URL(string: String(line.dropFirst(15))) }
                        else if line == "RX_PREVIEW_CHANGED" {
                            NotificationCenter.default.post(name: .remotionPreviewChanged, object: nil,
                                                            userInfo: ["directory": self.directory])
                        }
                        else { self.detail = String((self.detail + "\n" + line).suffix(8_000)) }
                    }
                }
            }
            process = proc; pipe = output
            try proc.run()
            for _ in 0..<300 {
                try Task.checkCancellation()
                if let url { return url }
                if !proc.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RemotionRuntimeError.studioFailedToStart(detail.isEmpty ? "The player server did not start." : detail)
        }
        starting = task
        return try await task.value
    }

    func stop() {
        starting?.cancel()
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            let pids = ProcessTreeKiller.snapshot(rootPID: process.processIdentifier)
            ProcessTreeKiller.signalAll(pids, SIGTERM)
            let cache = cache
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                ProcessTreeKiller.signalAll(pids.filter { kill($0, 0) == 0 }, SIGKILL)
                try? FileManager.default.removeItem(at: cache)
            }
        } else { try? FileManager.default.removeItem(at: cache) }
        process = nil; pipe = nil; starting = nil; url = nil
    }
}

/// Disposable alpha-preserving media. It never inserts a RemotionRender version.
@MainActor
enum RemotionPreviewRenderCache {
    private static var jobs: [String: Task<URL, Error>] = [:]

    static func render(project: RemotionProject, width: Int, height: Int,
                       progress: @escaping @MainActor (RenderProgress) -> Void) async throws -> URL {
        let projectDir = project.projectDir
        let fps = max(1, project.compositionFps)
        let sourceHash = try RemotionSourceHasher.hash(projectDir: projectDir, width: width, height: height, fps: fps)
        let key = SHA256.hash(data: Data("alpha-v1:\(projectDir.path):\(sourceHash)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let job = jobs[key] { return try await job.value }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rxlab.film-workflow/RemotionPreview/\(key)", isDirectory: true)
        let output = root.appendingPathComponent("source.mov")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let job = Task { @MainActor in
            let fm = FileManager.default
            let snapshot = root.appendingPathComponent("project", isDirectory: true)
            try? fm.removeItem(at: snapshot)
            try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
            for name in ["src", "public", "remotion.config.ts", "tsconfig.json", "package.json"] {
                let source = projectDir.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: snapshot.appendingPathComponent(name)) }
            }
            defer { try? fm.removeItem(at: snapshot) }
            let temporary = root.appendingPathComponent("rendering.mov")
            try await RemotionRenderer.render(projectDir: snapshot, to: temporary, width: width, height: height,
                                              fps: fps, preserveAlpha: true, onProgress: progress)
            try fm.moveItem(at: temporary, to: output)
            return output
        }
        jobs[key] = job
        defer { jobs.removeValue(forKey: key) }
        return try await job.value
    }
}
