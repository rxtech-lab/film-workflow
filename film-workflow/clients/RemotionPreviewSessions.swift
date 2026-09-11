import CryptoKit
import Foundation
import Observation
import RxRemotion

extension Notification.Name {
    static let remotionPreviewChanged = Notification.Name("RemotionPreviewChanged")
}

/// Compiled resources are shared by document/project directory, never by playback position.
@MainActor
final class RemotionPreviewSessions {
    static let shared = RemotionPreviewSessions()
    private struct Entry {
        let session: RemotionPreviewSession
        var owners: Set<UUID>
    }
    private var entries: [URL: Entry] = [:]
    private var toolLeases: [URL: RemotionPreviewLease] = [:]
    func keepRunning(project: RemotionProject) async throws -> URL {
        let directory = project.projectDir.standardizedFileURL
        if let lease = toolLeases[directory] { return lease.url }
        let lease = try await acquire(project: project)
        toolLeases[directory] = lease
        return lease.url
    }
    func configurationChanged() {
        let directories = Array(entries.keys)
        stopAll()
        for directory in directories {
            NotificationCenter.default.post(name: .remotionPreviewChanged, object: nil, userInfo: ["directory": directory])
        }
    }


    func acquire(project: RemotionProject) async throws -> RemotionPreviewLease {
        let directory = project.projectDir.standardizedFileURL
        try RemotionRuntime.shared.prepareProjectDirectory(directory)
        let source = directory.appendingPathComponent("src/Composition.tsx")
        if !FileManager.default.fileExists(atPath: source.path), !project.compositionSource.isEmpty {
            try RemotionCodeBuilder.writeComposition(project: project, source: project.compositionSource)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RemotionError.resource("Create a composition to start the preview.")
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
        for directory in Array(toolLeases.keys) where package == nil || directory.path.hasPrefix(package!.path + "/") {
            toolLeases.removeValue(forKey: directory)?.release()
        }
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
    private let engine = RemotionEngine(configuration: RemotionMapSettings.configuration)
    init(directory: URL) { self.directory = directory }
    func start() async throws -> URL {
        let project = try await engine.prepare(projectURL: directory)
        project.onRevisionChange = { [directory] in
            NotificationCenter.default.post(name: .remotionPreviewChanged, object: nil, userInfo: ["directory": directory])
        }
        return project.previewURL()
    }
    func stop() { engine.closeAll() }
}

/// Disposable alpha-preserving media. It never inserts a RemotionRender version.
@MainActor
enum RemotionPreviewRenderCache {
    private static let jobs = RemotionPreviewRenderJobs()
    static func captureScale(width: Int, height: Int) -> Double {
        min(1, 960 / Double(max(1, width, height)))
    }

    static func render(project: RemotionProject, width: Int, height: Int,
                       progress: @escaping @MainActor (RenderProgress) -> Void) async throws -> URL {
        let projectDir = project.projectDir
        let fps = max(1, project.compositionFps)
        let scale = captureScale(width: width, height: height)
        let sourceHash = try RemotionSourceHasher.hash(projectDir: projectDir, width: width, height: height, fps: fps)
        let key = SHA256.hash(data: Data("native-alpha-preview-v2-960:\(RemotionMapSettings.fingerprint):\(projectDir.path):\(sourceHash)".utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rxlab.film-workflow/RemotionPreview/\(key)", isDirectory: true)
        let output = root.appendingPathComponent("source.mov")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return try await jobs.value(for: key, progress: progress) { update in
            let fm = FileManager.default
            let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            try Task.checkCancellation()
            let temporary = work.appendingPathComponent("rendering.mov")
            try await RemotionRenderer.render(projectDir: projectDir, to: temporary, width: width, height: height,
                                              fps: fps, preserveAlpha: true, captureScale: scale, onProgress: update)
            try Task.checkCancellation()
            if !fm.fileExists(atPath: output.path) { try fm.moveItem(at: temporary, to: output) }
            return output
        }
    }
}
