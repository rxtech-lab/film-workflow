import Foundation
import Network
import Testing

@testable import film_workflow

@Suite("MCP server startup", .serialized)
@MainActor
struct MCPServerStartupTests {
    @Test("Concurrent starts wait for readiness and share one listener")
    func concurrentStartsWaitForReady() async throws {
        let listener = TestMCPListener()
        var creations = 0
        let server = MCPServer { _, _ in
            creations += 1
            return listener
        }
        var entered = 0
        var returned = 0
        let first = Task { entered += 1; await server.start(); returned += 1 }
        let second = Task { entered += 1; await server.start(); returned += 1 }
        defer { first.cancel(); second.cancel() }
        try await waitUntil { entered == 2 && listener.starts == 1 }
        #expect(returned == 0)
        #expect(!server.isRunning)
        #expect(MCPSettings.shared.actualPort == nil)
        #expect(creations == 1)

        listener.emit(.ready)
        await first.value
        await second.value
        #expect(returned == 2)
        #expect(server.isRunning)
        #expect(MCPSettings.shared.actualPort != nil)
        #expect(server.lastError == nil)
        let url = server.displayURL
        await server.start()
        #expect(server.displayURL == url)
        #expect(creations == 1)
        #expect(listener.cancellations == 0)
        await server.stop()
    }

    @Test("A listener failure wakes every caller and a later start recovers")
    func failureAndRetry() async throws {
        let failedListener = TestMCPListener()
        let replacement = TestMCPListener()
        var creations = 0
        let server = MCPServer { _, _ in
            creations += 1
            return creations == 1 ? failedListener : replacement
        }
        var entered = 0
        let first = Task { entered += 1; await server.start() }
        let second = Task { entered += 1; await server.start() }
        try await waitUntil { entered == 2 && failedListener.starts == 1 }
        let error = NWError.posix(.EADDRINUSE)
        failedListener.emit(.failed(error))
        await first.value
        await second.value
        #expect(!server.isRunning)
        #expect(server.lastError == error.localizedDescription)
        #expect(MCPSettings.shared.actualPort == nil)
        #expect(failedListener.cancellations == 1)

        let retry = Task { await server.start() }
        try await waitUntil { replacement.starts == 1 }
        #expect(server.lastError == nil)
        replacement.emit(.ready)
        await retry.value
        #expect(server.isRunning)
        #expect(server.lastError == nil)
        await server.stop()
    }

    @Test("Synchronous listener creation failures are reported without hanging")
    func creationFailure() async {
        let error = MCPServerError.bindFailed("test bind failure")
        let server = MCPServer { _, _ in throw error }
        await server.start()
        #expect(!server.isRunning)
        #expect(server.lastError == error.localizedDescription)
        #expect(MCPSettings.shared.actualPort == nil)
    }

    @Test("Stopping during startup wakes callers and ignores late readiness")
    func stopDuringStartup() async throws {
        let listener = TestMCPListener()
        let server = MCPServer { _, _ in listener }
        let start = Task { await server.start() }
        try await waitUntil { listener.starts == 1 }
        let queuedCallback = try #require(listener.stateUpdateHandler)
        await server.stop()
        await start.value
        queuedCallback(.ready)
        // Let the callback's main-actor task run, as it would after a real cancel.
        try await Task.sleep(for: .milliseconds(20))
        #expect(!server.isRunning)
        #expect(server.displayURL == nil)
        #expect(MCPSettings.shared.actualPort == nil)
        #expect(listener.cancellations == 1)
    }

    @Test("Callbacks from a replaced listener cannot stop or fail the new server")
    func replacementIgnoresOldCallbacks() async throws {
        let old = TestMCPListener()
        let replacement = TestMCPListener()
        var creations = 0
        let server = MCPServer { _, _ in
            creations += 1
            return creations == 1 ? old : replacement
        }
        let first = Task { await server.start() }
        try await waitUntil { old.starts == 1 }
        let queuedCallback = try #require(old.stateUpdateHandler)

        let restart = Task { await server.restart() }
        try await waitUntil { replacement.starts == 1 }
        await first.value
        replacement.emit(.ready)
        await restart.value
        let port = MCPSettings.shared.actualPort
        let url = server.displayURL

        queuedCallback(.cancelled)
        queuedCallback(.failed(.posix(.EADDRINUSE)))
        queuedCallback(.ready)
        try await Task.sleep(for: .milliseconds(20))
        #expect(server.isRunning)
        #expect(server.lastError == nil)
        #expect(server.displayURL == url)
        #expect(MCPSettings.shared.actualPort == port)
        #expect(replacement.cancellations == 0)
        await server.stop()
    }

    @Test("A listener that never becomes ready times out and releases callers")
    func startupTimeout() async {
        let listener = TestMCPListener()
        let server = MCPServer(startupTimeout: .milliseconds(30)) { _, _ in listener }
        await server.start()
        #expect(!server.isRunning)
        #expect(server.lastError == MCPServerError.startupTimedOut.localizedDescription)
        #expect(MCPSettings.shared.actualPort == nil)
        #expect(listener.cancellations == 1)
    }

    @Test("A real HTTP listener is usable immediately after awaiting startup")
    func realListenerReadyOnReturn() async throws {
        let server = MCPServer()
        await server.start()
        do {
            try #require(server.isRunning, "\(server.lastError ?? "Listener returned before readiness")")
            let port = try #require(MCPSettings.shared.actualPort)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            request.timeoutInterval = 3
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "Timed out waiting for test listener")
    }
}

@MainActor
private final class TestMCPListener: MCPServerListener {
    var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
    private(set) var starts = 0
    private(set) var cancellations = 0

    func start(queue: DispatchQueue) { starts += 1 }
    func cancel() {
        cancellations += 1
        emit(.cancelled)
    }
    func emit(_ state: NWListener.State) { stateUpdateHandler?(state) }
}
