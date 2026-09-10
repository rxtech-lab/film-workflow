import Foundation

/// Studio has the same per-document ownership as Player, with its own UI/process.
@MainActor
enum RemotionStudioSessions {
    private final class Entry {
        let runtime = RemotionRuntime()
        var owners: Set<UUID> = []
        var retainedByTool = false
        var start: Task<Void, Error>?
    }
    private static var entries: [URL: Entry] = [:]

    static func runtime(for directory: URL) -> RemotionRuntime? { entries[directory.standardizedFileURL]?.runtime }

    static func acquire(projectID: UUID, directory: URL) async throws -> RemotionStudioLease {
        let directory = directory.standardizedFileURL
        let owner = UUID()
        let entry = entry(projectID: projectID, directory: directory)
        entry.owners.insert(owner)
        do {
            try await entry.start?.value
            try Task.checkCancellation()
            return RemotionStudioLease(directory: directory, owner: owner, runtime: entry.runtime)
        } catch {
            release(directory: directory, owner: owner)
            throw error
        }
    }

    /// MCP intentionally returns a Studio URL that remains usable until the film closes.
    static func keepRunning(projectID: UUID, directory: URL) async throws -> RemotionRuntime {
        let directory = directory.standardizedFileURL
        let entry = entry(projectID: projectID, directory: directory)
        entry.retainedByTool = true
        do { try await entry.start?.value; return entry.runtime }
        catch {
            entry.retainedByTool = false
            release(directory: directory, owner: UUID())
            throw error
        }
    }

    private static func entry(projectID: UUID, directory: URL) -> Entry {
        if let entry = entries[directory] { return entry }
        let entry = Entry()
        entries[directory] = entry
        entry.start = Task { @MainActor in
            try await entry.runtime.start(projectId: projectID, projectDir: directory)
        }
        return entry
    }

    fileprivate static func release(directory: URL, owner: UUID) {
        guard let entry = entries[directory] else { return }
        entry.owners.remove(owner)
        guard entry.owners.isEmpty, !entry.retainedByTool else { return }
        entries.removeValue(forKey: directory)
        entry.start?.cancel()
        Task { await entry.runtime.stop() }
    }

    static func stopAll(in package: URL? = nil) async {
        for directory in Array(entries.keys) where package == nil || directory.path.hasPrefix(package!.standardizedFileURL.path + "/") {
            guard let entry = entries.removeValue(forKey: directory) else { continue }
            entry.start?.cancel()
            await entry.runtime.stop()
        }
    }
}

@MainActor
final class RemotionStudioLease {
    let runtime: RemotionRuntime
    private let directory: URL
    private let owner: UUID
    private var released = false
    fileprivate init(directory: URL, owner: UUID, runtime: RemotionRuntime) {
        self.directory = directory; self.owner = owner; self.runtime = runtime
    }
    func release() {
        guard !released else { return }
        released = true
        RemotionStudioSessions.release(directory: directory, owner: owner)
    }
    deinit {
        let directory = directory, owner = owner
        Task { @MainActor in RemotionStudioSessions.release(directory: directory, owner: owner) }
    }
}
