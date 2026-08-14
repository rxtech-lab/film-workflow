#if os(macOS)
import Foundation

/// Runs a command-line agent and streams its stdout a line at a time.
///
/// Two details are load-bearing, both learned from RxCode's Claude driver:
///
/// 1. Lines are read through a Dispatch `readabilityHandler` rather than
///    `FileHandle.AsyncBytes.lines`. With two pipes being read concurrently the
///    async-bytes path can wedge, and a wedged agent looks like a hang.
/// 2. Cancellation goes through `ProcessTreeKiller`, not `Process.terminate()`.
///    These agents spawn children, and terminating the parent alone leaves them
///    running.
nonisolated enum CaptionCLIProcess {

    struct Result: Sendable {
        var exitCode: Int32
        /// Everything stderr produced, for the error message when it fails.
        var errorOutput: String
    }

    enum Failure: LocalizedError {
        case launchFailed(String, String)
        case exited(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let tool, let message):
                return "Couldn't start \(tool): \(message)"
            case .exited(let tool, let code, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "\(tool) exited with code \(code)."
                }
                return "\(tool) failed: \(String(detail.suffix(400)))"
            }
        }
    }

    /// Runs `executable`, calling `onLine` for each line of stdout.
    ///
    /// Throws `Failure.exited` on a non-zero exit so callers don't have to check
    /// the code, and `CancellationError` when the surrounding task is cancelled.
    @discardableResult
    static func run(
        tool: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let collector = LineCollector(onLine: onLine)
        let errors = ErrorCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errors.append(data)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw Failure.launchFailed(tool, error.localizedDescription)
        }

        if let stdin, let handle = (process.standardInput as? Pipe)?.fileHandleForWriting {
            handle.write(Data(stdin.utf8))
            // The agent waits for EOF before it starts; without this it hangs.
            try? handle.close()
        }

        let pid = process.processIdentifier

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            ProcessTreeKiller.killTree(rootPID: pid, signal: SIGTERM)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // `terminationHandler` fires when the process dies, not when its pipes
        // are drained, so bytes can still be sitting in the pipe buffer here —
        // detaching the handler without reading them throws them away. A
        // line-streaming agent loses a trailing fragment; `codex debug models`,
        // whose whole reply is one ~320 KB line, loses the tail of its JSON and
        // becomes unparseable.
        let remainingOutput = drain(outPipe.fileHandleForReading)
        if !remainingOutput.isEmpty { collector.append(remainingOutput) }
        let remainingErrors = drain(errPipe.fileHandleForReading)
        if !remainingErrors.isEmpty { errors.append(remainingErrors) }
        collector.flush()

        if Task.isCancelled {
            ProcessTreeKiller.killTree(rootPID: pid, signal: SIGKILL)
            throw CancellationError()
        }

        let result = Result(exitCode: process.terminationStatus, errorOutput: errors.text)
        guard result.exitCode == 0 else {
            throw Failure.exited(tool, result.exitCode, result.errorOutput)
        }
        return result
    }

    /// Reads whatever is still sitting in a pipe's buffer, without blocking.
    ///
    /// `readDataToEndOfFile()` would be a one-liner but it waits for the write
    /// end to close, and these agents spawn children that inherit it — the same
    /// reason cancellation needs `ProcessTreeKiller`. One surviving grandchild
    /// would wedge the caller forever. A non-blocking read takes what the exited
    /// process left behind and stops at EOF, or as soon as nothing more is ready.
    private static func drain(_ handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return Data() }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // 0 is EOF; -1 is EAGAIN (nothing buffered right now) or a real
            // error. Either way there is nothing further for us to collect.
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            output.append(contentsOf: chunk[0 ..< count])
        }
        return output
    }
}

/// Splits a byte stream into lines. `@unchecked Sendable` with a lock because
/// Dispatch calls the readability handler on its own queue.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        var complete: [String] = []
        lock.lock()
        buffer.append(data)
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                complete.append(text)
            }
        }
        lock.unlock()

        // Delivered outside the lock: `onLine` can be slow, and holding the lock
        // across it would stall the reader.
        for line in complete { onLine(line) }
    }

    /// Emits a trailing line that never got its newline.
    func flush() {
        lock.lock()
        let remaining = buffer
        buffer = Data()
        lock.unlock()

        guard let text = String(data: remaining, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onLine(text)
    }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        // Bounded: a chatty agent can produce megabytes of progress noise, and
        // all we need is the tail for an error message.
        data.append(chunk)
        if data.count > 64_000 { data.removeFirst(data.count - 64_000) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif
