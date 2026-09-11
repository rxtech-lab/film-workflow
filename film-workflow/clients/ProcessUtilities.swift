import Foundation

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

}

/// Owns the launch/cancel ordering for a child process tree.
///
/// `withTaskCancellationHandler` may run `onCancel` before, during, or after the
/// process launches, so the launch and the kill have to be serialised against each
/// other. The SIGKILL escalation also has to live here rather than after the `await`:
/// that await only resumes once the process has already exited, which is precisely
/// what does not happen when SIGTERM is ignored.
final class CancellableProcess: @unchecked Sendable {
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

final class LineBuffer: @unchecked Sendable {
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

